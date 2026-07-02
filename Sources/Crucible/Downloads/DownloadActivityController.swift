#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import CrucibleActivity
import Foundation
import os
import UIKit

/// Drives the download Live Activity (Lock Screen + Dynamic Island) from the engine's item state.
/// Starting a Live Activity requires the foreground (ActivityKit rule); updating and ending an
/// existing one work from the background, so teardown/updates are never gated by the enabled flag.
@MainActor
final class DownloadActivityController {
    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "downloads")

    private var activity: Activity<DownloadActivityAttributes>?
    private var sessionKeys: [String] = []
    private var lastUpdate = Date.distantPast
    private var needsForeground = false

    private struct RateSample { var ratingKey: String; var bytes: Int64; var fraction: Double; var at: Date }
    private var lastSample: RateSample?
    private var smoothedBytesPerSec: Double = 0

    /// Adopts the activity that survived an app relaunch instead of ending it: after a background
    /// relaunch for URLSession events a new activity cannot be started (foreground-only rule), so
    /// ending the survivor would blank the Lock Screen for the rest of the batch. Updating an adopted
    /// activity is background-legal — the first sync refreshes it, or ends it if nothing is active.
    /// Duplicate leftovers beyond the first are genuinely stale and are dismissed.
    func endStale() {
        sessionKeys = []
        let surviving = Activity<DownloadActivityAttributes>.activities
        activity = surviving.first
        guard surviving.count > 1 else { return }
        Task {
            for extra in surviving.dropFirst() {
                await extra.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func sync(items: [DownloadItem], force: Bool, needsForeground: Bool = false) {
        self.needsForeground = needsForeground
        let active = items.filter { $0.state.isActive }
        for item in active where !sessionKeys.contains(item.ratingKey) {
            sessionKeys.append(item.ratingKey)
        }
        let sessionItems = sessionKeys.compactMap { key in items.first { $0.ratingKey == key } }
        let hasPaused = sessionItems.contains { $0.state == .paused }
        guard !active.isEmpty || hasPaused else {
            end()
            return
        }

        let now = Date()
        if !force, now.timeIntervalSince(lastUpdate) < 0.5 { return }
        lastUpdate = now

        guard let content = state(items: items, active: active) else { return }
        present(content)
    }

    private func state(items: [DownloadItem], active: [DownloadItem]) -> DownloadActivityAttributes.ContentState? {
        let sessionItems = sessionKeys.compactMap { key in items.first { $0.ratingKey == key } }
        let total = max(sessionItems.count, 1)
        let settled = sessionItems.filter { $0.state == .completed || $0.state == .failed }.count
        let downloading = items.first { $0.state == .downloading }
        let pausedItem = sessionItems.first { $0.state == .paused }
        guard let current = downloading ?? active.first ?? pausedItem ?? sessionItems.first else { return nil }
        let currentProgress = current.progress
        let batch = min(1, (Double(settled) + (downloading?.progress ?? 0)) / Double(total))
        let waitingForWiFi = downloading == nil && !active.isEmpty && active.allSatisfy { $0.state == .waitingForWiFi }

        let status: DownloadActivityAttributes.ContentState.Status
        if downloading != nil { status = .downloading }
        else if current.state == .paused { status = .paused }
        else if waitingForWiFi { status = .waitingForWiFi }
        else if needsForeground { status = .needsApp }
        else { status = .queued }

        let eta: Double?
        if status == .downloading {
            eta = estimateETA(for: current)
        } else {
            resetRate()
            eta = nil
        }

        let isEpisode = current.mediaType == "episode"
        return DownloadActivityAttributes.ContentState(
            showTitle: current.displayTitle,
            episodeCode: isEpisode ? Formatters.episodeCode(current.seasonNumber, current.episodeNumber) : nil,
            episodeTitle: isEpisode ? current.title : nil,
            qualityLabel: current.quality.shortLabel,
            itemFraction: currentProgress,
            downloadedBytes: current.downloadedBytes,
            totalBytes: current.knownBytes,
            completedCount: settled,
            totalCount: total,
            batchFraction: batch,
            status: status,
            etaSeconds: eta
        )
    }

    /// Smoothed (EMA) byte-rate → ETA. HLS segments commit in bursts, so a raw instantaneous rate
    /// jitters wildly; the EMA over the ~1.5s sync cadence keeps the estimate stable. Returns nil
    /// until a positive rate and a known remaining size both exist, so the UI omits ETA gracefully.
    private func estimateETA(for item: DownloadItem) -> Double? {
        let now = Date()
        defer { lastSample = RateSample(ratingKey: item.ratingKey, bytes: item.downloadedBytes, fraction: item.progress, at: now) }
        guard let prev = lastSample, prev.ratingKey == item.ratingKey else { resetRate(); return nil }
        let dt = now.timeIntervalSince(prev.at)
        guard dt >= 0.5 else { return etaFromSmoothed(item) }

        let dBytes = Double(item.downloadedBytes - prev.bytes)
        if dBytes > 0 {
            let inst = dBytes / dt
            smoothedBytesPerSec = smoothedBytesPerSec == 0 ? inst : 0.3 * inst + 0.7 * smoothedBytesPerSec
        } else {
            let dFrac = item.progress - prev.fraction
            if dFrac > 0, item.knownBytes > 0 {
                let inst = (dFrac * Double(item.knownBytes)) / dt
                smoothedBytesPerSec = smoothedBytesPerSec == 0 ? inst : 0.3 * inst + 0.7 * smoothedBytesPerSec
            }
        }
        return etaFromSmoothed(item)
    }

    private func etaFromSmoothed(_ item: DownloadItem) -> Double? {
        guard smoothedBytesPerSec > 0, item.knownBytes > 0 else { return nil }
        let remaining = max(0, Double(item.knownBytes) - Double(item.downloadedBytes))
        guard remaining > 0 else { return nil }
        return remaining / smoothedBytesPerSec
    }

    private func resetRate() {
        lastSample = nil
        smoothedBytesPerSec = 0
    }

    private func present(_ state: DownloadActivityAttributes.ContentState) {
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity, activity.activityState == .active {
            Task { await activity.update(content) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              UIApplication.shared.applicationState != .background else { return }
        do {
            activity = try Activity.request(attributes: DownloadActivityAttributes(), content: content, pushType: nil)
        } catch {
            Self.log.error("Live Activity start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func end() {
        sessionKeys = []
        lastUpdate = .distantPast
        resetRate()
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif

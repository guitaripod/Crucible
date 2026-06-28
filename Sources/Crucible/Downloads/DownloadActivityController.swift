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

    /// Ends any activities left over from a previous launch.
    func endStale() {
        sessionKeys = []
        activity = nil
        Task {
            for activity in Activity<DownloadActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func sync(items: [DownloadItem], force: Bool) {
        let active = items.filter { $0.state.isActive }
        guard !active.isEmpty else {
            end()
            return
        }

        for item in active where !sessionKeys.contains(item.ratingKey) {
            sessionKeys.append(item.ratingKey)
        }

        let now = Date()
        if !force, now.timeIntervalSince(lastUpdate) < 1.5 { return }
        lastUpdate = now

        present(state(items: items, active: active, pausedOverride: false))
    }

    private func state(items: [DownloadItem], active: [DownloadItem], pausedOverride: Bool) -> DownloadActivityAttributes.ContentState {
        let sessionItems = sessionKeys.compactMap { key in items.first { $0.ratingKey == key } }
        let total = max(sessionItems.count, 1)
        let completed = sessionItems.filter { $0.state == .completed }.count
        let downloading = items.first { $0.state == .downloading }
        let current = downloading ?? active.first!
        let currentProgress = downloading?.progress ?? 0
        let overall = min(1, (Double(completed) + currentProgress) / Double(total))
        let waitingForWiFi = downloading == nil && active.allSatisfy { $0.state == .waitingForWiFi }
        let paused = pausedOverride || downloading == nil

        let detail: String
        if pausedOverride {
            detail = "Paused · will resume"
        } else if waitingForWiFi {
            detail = "Waiting for Wi-Fi"
        } else if paused {
            detail = "Paused"
        } else {
            detail = current.episodeSubtitle ?? current.quality.shortLabel
        }

        return DownloadActivityAttributes.ContentState(
            title: current.displayTitle,
            detail: detail,
            fractionCompleted: overall,
            completedCount: completed,
            totalCount: total,
            isPaused: paused
        )
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
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif

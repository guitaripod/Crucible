import CrucibleCore
import Foundation
import UIKit

extension DownloadManager {
    // MARK: - Queue

    /// With the daemon broken, downloads run in-process and need runtime: while backgrounded, only
    /// start new work when a meaningful slice of background time remains. This lets a batch chain
    /// episode-to-episode under the ~30s grace, but never restarts into a doomed frozen fetch the
    /// way an expired-assertion restart would (the cause of a stuck Live Activity).
    func pumpQueue() {
        guard config != nil else { return }
        if backgroundSessionBroken, UIApplication.shared.applicationState == .background,
           !continuedProcessingActive,
           UIApplication.shared.backgroundTimeRemaining < 10 { return }
        let net = canStartOnCurrentNetwork()
        if !net {
            var changed = false
            for i in items.indices where items[i].state == .queued {
                items[i].state = .waitingForWiFi
                changed = true
            }
            if changed { persist(); emit(.changed) }
            return
        }
        for i in items.indices where items[i].state == .waitingForWiFi {
            items[i].state = .queued
        }
        // Segments stream over one background session capped to a single connection per host (Plex's
        // transcode session is single-threaded), so downloads run one item at a time — concurrent
        // items would starve each other's transcode sessions into refresh churn.
        guard !items.contains(where: { $0.state == .downloading }) else { return }
        for item in items where item.state == .queued {
            guard jobs[item.ratingKey] == nil, !resolving.contains(item.ratingKey) else { continue }
            startDownload(item.ratingKey)
            return
        }
    }

    func canStartOnCurrentNetwork() -> Bool {
        Preferences.downloadOverCellular ? isOnline : isOnWiFi
    }

    private func startDownload(_ ratingKey: String) {
        guard config != nil, let idx = index(ratingKey), items[idx].state == .queued else { return }
        items[idx].state = .downloading
        items[idx].errorMessage = nil
        persist()
        emit(.changed)
        beginResolve(ratingKey, countAsFailure: false)
    }

    /// (Re)resolves a fresh Plex session and starts/continues the segment chain.
    func beginResolve(_ ratingKey: String, countAsFailure: Bool) {
        guard let idx = index(ratingKey), items[idx].state == .downloading else { return }
        guard !resolving.contains(ratingKey) else { return }
        var refreshes = jobs[ratingKey]?.refreshes ?? 0
        if countAsFailure {
            refreshes += 1
            if refreshes > Self.maxSessionRefreshes {
                failItem(ratingKey, message: "Download failed")
                return
            }
        }
        let oldToken = jobs[ratingKey]?.token
        jobs[ratingKey] = nil
        if let oldToken { cancelInflight(ratingKey, scope: .matching(oldToken)) }
        stopTranscodeSession(ratingKey)
        resolving.insert(ratingKey)
        let quality = items[idx].quality
        let carriedRefreshes = refreshes
        Task { [weak self] in
            await self?.performResolve(ratingKey, quality: quality, refreshes: carriedRefreshes)
        }
    }
}

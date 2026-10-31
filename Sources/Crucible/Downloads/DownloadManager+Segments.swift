import CrucibleCore
import Foundation
import MidgarCore

extension DownloadManager {
    /// Enqueues every not-yet-downloaded segment at once. With the session capped to one connection per
    /// host, iOS runs them back-to-back in the daemon in playlist order — sequential (so Plex's
    /// single-threaded transcode session never contends) yet with no per-segment app-wake latency.
    func enqueueAllSegments(_ ratingKey: String) {
        guard let job = jobs[ratingKey], let idx = index(ratingKey), items[idx].state == .downloading else { return }
        updateProgress(ratingKey)
        let pending: [(url: URL, descriptor: String)] = job.names.compactMap { name in
            let local = HLSDownloader.localName(for: name)
            guard !job.onDisk.contains(local),
                  let url = HLSDownloader.segmentURL(name: name, base: job.base) else { return nil }
            return (url, "\(ratingKey)|\(local)|\(job.token)")
        }
        guard !pending.isEmpty else { finalizeComplete(ratingKey); return }
        recordContinuedProgress(addedUnits: Int64(pending.count))
        if backgroundSessionBroken {
            MidgarLog.notice("Background session known broken; fetching in-process key=\(ratingKey)", category: .persistence)
            startFallbackFetch(ratingKey, token: job.token)
            return
        }
        resumeSegmentTasks(pending, allowsCellular: Preferences.downloadOverCellular)
        scheduleStallWatchdog(ratingKey, token: job.token)
    }

    /// Detects a wedged background session: if not a single segment lands within the window (seen on
    /// iOS 27 beta, where the daemon silently runs none of a sideloaded app's transfers), the item
    /// falls back to an in-process fetch over `URLSession.shared` — the same session the resolve just
    /// succeeded on — so downloads still complete while the app is running.
    func scheduleStallWatchdog(_ ratingKey: String, token: String) {
        stallWatchdogs[ratingKey]?.cancel()
        let baseline = jobs[ratingKey]?.onDisk.count ?? 0
        stallWatchdogs[ratingKey] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled else { return }
            guard let job = self.jobs[ratingKey], job.token == token, job.onDisk.count == baseline,
                  let idx = self.index(ratingKey), self.items[idx].state == .downloading,
                  self.fallbackFetchers[ratingKey] == nil else { return }
            MidgarLog.error("Background session stalled (no segment progress in 20s) key=\(ratingKey); falling back to in-process fetch", category: .persistence)
            self.backgroundSessionBroken = true
            self.cancelInflight(ratingKey, scope: .matching(token))
            self.startFallbackFetch(ratingKey, token: token)
        }
    }

    /// Creates and resumes the background segment tasks off the main thread: spawning a few hundred
    /// background tasks at once is XPC-heavy and would hitch the UI at every item boundary (painfully
    /// visible when downloading a whole season). The serial queue preserves playlist order, which the
    /// single-connection session then streams sequentially for Plex's on-demand transcoder.
    private func resumeSegmentTasks(_ pending: [(url: URL, descriptor: String)], allowsCellular: Bool) {
        let session = self.session
        enqueueQueue.async {
            for segment in pending {
                var request = URLRequest(url: segment.url)
                request.timeoutInterval = 90
                request.allowsCellularAccess = allowsCellular
                request.setValue("*/*", forHTTPHeaderField: "Accept")
                let task = session.downloadTask(with: request)
                task.taskDescription = segment.descriptor
                task.resume()
            }
            MidgarLog.notice("Enqueued \(pending.count) background segment tasks", category: .persistence)
        }
    }

    private func updateProgress(_ ratingKey: String) {
        guard let job = jobs[ratingKey], let idx = index(ratingKey) else { return }
        items[idx].progress = job.total > 0 ? Double(job.onDisk.count) / Double(job.total) : 0
        items[idx].downloadedBytes = Int64(items[idx].progress * Double(items[idx].knownBytes))
        let now = Date()
        if let last = lastProgressEmit[ratingKey], now.timeIntervalSince(last) < 0.4 { return }
        lastProgressEmit[ratingKey] = now
        emit(.progress(ratingKey: ratingKey, fractionCompleted: items[idx].progress, downloadedBytes: items[idx].downloadedBytes, totalBytes: items[idx].knownBytes))
    }

    // MARK: - Delegate-driven handlers (MainActor)

    func handleSegmentFinished(ratingKey: String, name: String, token: String) {
        guard let idx = index(ratingKey), items[idx].state == .downloading else { return }
        if jobs[ratingKey] == nil {
            beginResolve(ratingKey, countAsFailure: false)
            return
        }
        guard jobs[ratingKey]?.token == token else { return }
        jobs[ratingKey]?.onDisk.insert(name)
        jobs[ratingKey]?.refreshes = 0
        recordContinuedProgress(completedOne: true)
        updateProgress(ratingKey)
        if let job = jobs[ratingKey], job.onDisk.count >= job.total {
            finalizeComplete(ratingKey)
        }
    }

    func handleSegmentError(ratingKey: String, token: String) {
        guard let idx = index(ratingKey), items[idx].state == .downloading else { return }
        guard jobs[ratingKey] == nil || jobs[ratingKey]?.token == token else { return }
        beginResolve(ratingKey, countAsFailure: true)
    }

    func runBackgroundCompletionHandler() {
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        handler?()
    }
}

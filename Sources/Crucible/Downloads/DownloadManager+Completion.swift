import CrucibleCore
import Foundation
import MidgarCore

extension DownloadManager {
    func finalizeComplete(_ ratingKey: String) {
        guard let idx = index(ratingKey) else { return }
        let size = HLSDownloader.directorySize(DownloadPaths.assetDir(ratingKey: ratingKey))
        items[idx].state = .completed
        items[idx].progress = 1
        items[idx].totalBytes = size
        items[idx].downloadedBytes = size
        items[idx].completedAt = Date()
        items[idx].errorMessage = nil
        jobs[ratingKey] = nil
        cancelInflight(ratingKey)
        stopTranscodeSession(ratingKey)
        lastProgressEmit[ratingKey] = nil
        resolveRetries[ratingKey] = nil
        persist()
        emit(.finished(ratingKey: ratingKey))
        emit(.changed)
        notifyDownloadComplete(items[idx])
        MidgarLog.notice("Download finished key=\(ratingKey) bytes=\(size)", category: .persistence)
        pumpQueue()
        if !hasActiveDownloads { completeContinuedTaskIfNeeded(success: true) }
    }

    func failItem(_ ratingKey: String, message: String) {
        guard let idx = index(ratingKey) else { return }
        jobs[ratingKey] = nil
        cancelInflight(ratingKey)
        stopTranscodeSession(ratingKey)
        items[idx].state = .failed
        items[idx].errorMessage = message
        persist()
        emit(.failed(ratingKey: ratingKey, message: message))
        emit(.changed)
        MidgarLog.error("Download failed key=\(ratingKey): \(message)", category: .persistence)
        notifyDownloadFailed(items[idx], message: message)
        pumpQueue()
        if !hasActiveDownloads { completeContinuedTaskIfNeeded(success: false) }
    }

    func cancelItemTasks(_ ratingKey: String) {
        jobs[ratingKey] = nil
        stallWatchdogs.removeValue(forKey: ratingKey)?.cancel()
        fallbackFetchers.removeValue(forKey: ratingKey)?.cancel()
        cancelInflight(ratingKey)
        stopTranscodeSession(ratingKey)
    }

    /// Scopes a cancel sweep by segment-task generation. `getAllTasks` snapshots asynchronously, so an
    /// unscoped sweep issued before a re-resolve could land after the NEW job's tasks exist and cancel
    /// them — cancellations are ignored by the delegate, leaving the item stuck at `.downloading`
    /// forever. Re-resolve paths therefore cancel `.matching` the old token (and `.excluding` the new
    /// one as a straggler catch-up); terminal paths (pause/delete/fail/complete) sweep `.all`.
    enum CancelScope {
        case all
        case matching(String)
        case excluding(String)

        func admits(_ token: String) -> Bool {
            switch self {
            case .all: return true
            case .matching(let t): return token == t
            case .excluding(let t): return token != t
            }
        }
    }

    func cancelInflight(_ ratingKey: String, scope: CancelScope = .all) {
        cancelInflight(keys: [ratingKey], scope: scope)
    }

    /// Rides the enqueue queue so the cancel sweep is ordered after any in-flight off-main task
    /// creation — a pause/delete issued while segments are still being spawned can never leak
    /// orphan transfers that would keep downloading in the daemon.
    func cancelInflight(keys: Set<String>, scope: CancelScope = .all) {
        let session = self.session
        enqueueQueue.async {
            session.getAllTasks { tasks in
                for task in tasks {
                    guard let desc = task.taskDescription else { continue }
                    let parts = desc.split(separator: "|", maxSplits: 2).map(String.init)
                    guard parts.count == 3, keys.contains(parts[0]), scope.admits(parts[2]) else { continue }
                    task.cancel()
                }
            }
        }
    }
}

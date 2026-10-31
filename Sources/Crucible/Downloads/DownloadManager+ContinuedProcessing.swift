import BackgroundTasks
import CrucibleCore
import Foundation
import MidgarCore

extension DownloadManager {
    /// iOS 26's continued-processing task keeps the in-process fetcher alive long after the ~30s
    /// assertion grace, with system-managed progress UI — the only sanctioned way to keep
    /// user-initiated downloads running in background now that the transfer daemon ignores us.
    func registerContinuedProcessing() {
        guard #available(iOS 26.0, *) else { return }
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.continuedTaskIdentifier, using: nil) { task in
            MidgarLog.notice("Continued processing launch handler invoked", category: .persistence)
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in DownloadManager.shared.adoptContinuedTask(task) }
        }
        MidgarLog.notice("Continued processing registration \(registered ? "succeeded" : "FAILED")", category: .persistence)
    }

    /// `.fail` forces the system to either start the task immediately or throw a diagnosable error;
    /// only when it reports transient load does the `.queue` retry make sense. A `.queue` submit that
    /// silently never launches (observed on this iOS 26/27 line, see FB-referenced forum thread
    /// 807370) would otherwise look identical to success.
    func submitContinuedTaskIfNeeded(title: String) {
        guard #available(iOS 26.0, *), continuedTask == nil else { return }
        func request(_ strategy: BGContinuedProcessingTaskRequest.SubmissionStrategy) -> BGContinuedProcessingTaskRequest {
            let request = BGContinuedProcessingTaskRequest(
                identifier: Self.continuedTaskIdentifier,
                title: title,
                subtitle: "Downloading for offline playback"
            )
            request.strategy = strategy
            return request
        }
        do {
            try BGTaskScheduler.shared.submit(request(.fail))
            MidgarLog.notice("Continued processing task submitted (fail strategy)", category: .persistence)
        } catch {
            MidgarLog.error("Continued processing .fail submit rejected: \(error as NSError); retrying with .queue", category: .persistence)
            do {
                try BGTaskScheduler.shared.submit(request(.queue))
                MidgarLog.notice("Continued processing task submitted (queue strategy)", category: .persistence)
            } catch {
                MidgarLog.error("Continued processing .queue submit rejected: \(error as NSError)", category: .persistence)
                return
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.continuedTask == nil else { return }
            MidgarLog.error("Continued processing task not launched 8s after submit", category: .persistence)
        }
    }

    @available(iOS 26.0, *)
    private func adoptContinuedTask(_ task: BGContinuedProcessingTask) {
        continuedTask = task
        continuedProcessingActive = true
        continuedUnitsDone = 0
        continuedUnitsTotal = Int64(jobs.values.reduce(0) { $0 + max(0, $1.total - $1.onDisk.count) })
        task.progress.totalUnitCount = max(continuedUnitsTotal, 1)
        task.progress.completedUnitCount = 0
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.continuedTaskExpired() }
        }
        MidgarLog.notice("Continued processing task adopted; remaining units=\(continuedUnitsTotal)", category: .persistence)
        if !hasActiveDownloads { completeContinuedTaskIfNeeded(success: true) }
    }

    private func continuedTaskExpired() {
        MidgarLog.notice("Continued processing expired; suspending in-process fetches", category: .persistence)
        continuedProcessingActive = false
        for key in Array(fallbackFetchers.keys) { suspendFallbackFetch(key) }
        completeContinuedTaskIfNeeded(success: false)
    }

    func completeContinuedTaskIfNeeded(success: Bool) {
        guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask else { return }
        continuedTask = nil
        continuedProcessingActive = false
        task.setTaskCompleted(success: success)
        MidgarLog.notice("Continued processing task completed success=\(success)", category: .persistence)
    }

    func recordContinuedProgress(addedUnits: Int64 = 0, completedOne: Bool = false) {
        guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask else { return }
        if addedUnits > 0 {
            continuedUnitsTotal += addedUnits
            task.progress.totalUnitCount = max(continuedUnitsTotal, 1)
        }
        if completedOne {
            continuedUnitsDone += 1
            task.progress.completedUnitCount = continuedUnitsDone
        }
    }
}

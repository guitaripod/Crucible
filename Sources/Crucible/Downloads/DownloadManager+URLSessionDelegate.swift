import CrucibleCore
import Foundation

extension DownloadManager {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let parts = Self.descriptor(downloadTask) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let size = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard (200...299).contains(status), size > 0,
              DownloadPaths.commitSegment(tempURL: location, ratingKey: parts.key, name: parts.name) else {
            AppLogger.error("Segment rejected status=\(status) size=\(size) key=\(parts.key) name=\(parts.name)", .persistence)
            Task { @MainActor in DownloadManager.shared.handleSegmentError(ratingKey: parts.key, token: parts.token) }
            return
        }
        Task { @MainActor in DownloadManager.shared.handleSegmentFinished(ratingKey: parts.key, name: parts.name, token: parts.token) }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error, let parts = Self.descriptor(task) else { return }
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        AppLogger.error("Segment task error key=\(parts.key) name=\(parts.name) \(nsError.domain)#\(nsError.code): \(nsError.localizedDescription)", .persistence)
        Task { @MainActor in DownloadManager.shared.handleSegmentError(ratingKey: parts.key, token: parts.token) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in DownloadManager.shared.runBackgroundCompletionHandler() }
    }

    nonisolated private static func descriptor(_ task: URLSessionTask) -> (key: String, name: String, token: String)? {
        guard let desc = task.taskDescription else { return nil }
        let parts = desc.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }
}

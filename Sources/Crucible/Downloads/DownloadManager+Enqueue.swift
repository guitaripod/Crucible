import CrucibleCore
import Foundation

extension DownloadManager {
    // MARK: - Enqueue

    func enqueue(metadata: PlexMetadata, quality: DownloadQuality? = nil) {
        let ratingKey = metadata.id
        guard !ratingKey.isEmpty else { return }
        if let existing = item(for: ratingKey) {
            if existing.state == .failed || existing.state == .paused { resume(ratingKey) }
            return
        }
        items.insert(makeItem(metadata: metadata, quality: quality ?? Preferences.downloadQuality), at: 0)
        persist()
        emit(.changed)
        pumpQueue()
        DemoTour.shared.record(.download)
    }

    /// Enqueues a batch preserving its order (episode 1 downloads first) and, like single `enqueue`,
    /// re-queues any existing failed/paused member so "Download Remaining" actually retries them.
    @discardableResult
    func enqueueAll(_ metadatas: [PlexMetadata], quality: DownloadQuality? = nil) -> Int {
        let q = quality ?? Preferences.downloadQuality
        var newItems: [DownloadItem] = []
        var touched = 0
        for metadata in metadatas {
            let key = metadata.id
            guard !key.isEmpty else { continue }
            if let idx = index(key) {
                if items[idx].state == .failed || items[idx].state == .paused {
                    items[idx].state = .queued
                    items[idx].errorMessage = nil
                    resolveRetries[key] = nil
                    touched += 1
                }
                continue
            }
            newItems.append(makeItem(metadata: metadata, quality: q))
            touched += 1
        }
        items.insert(contentsOf: newItems, at: 0)
        if touched > 0 {
            persist()
            emit(.changed)
            pumpQueue()
            DemoTour.shared.record(.download)
        }
        return touched
    }

    private func makeItem(metadata: PlexMetadata, quality: DownloadQuality) -> DownloadItem {
        let mediaType = metadata.mediaType
        let posterPath = mediaType == "episode" ? (metadata.grandparentThumb ?? metadata.thumb) : metadata.thumb
        let durationMs = metadata.duration ?? 0
        return DownloadItem(
            ratingKey: metadata.id, mediaType: mediaType, title: metadata.title,
            showTitle: metadata.grandparentTitle, grandparentRatingKey: metadata.grandparentRatingKey,
            parentRatingKey: metadata.parentRatingKey, seasonNumber: metadata.parentIndex,
            episodeNumber: metadata.index, year: metadata.year, durationMs: durationMs,
            summary: metadata.summary, plexThumbPath: posterPath, quality: quality,
            isTranscoded: true, fileExtension: "movpkg", hlsRelativePath: nil, state: .queued,
            progress: 0, totalBytes: 0, downloadedBytes: 0,
            estimatedBytes: quality.estimatedBytes(durationMs: durationMs), errorMessage: nil,
            createdAt: Date(), completedAt: nil, viewOffsetMs: metadata.viewOffset ?? 0, markers: []
        )
    }
}

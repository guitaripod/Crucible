import CrucibleCore
import Foundation

extension DownloadManager {
    /// Queues one title. A free install that already has a download going is offered Crucible Pro first, and the title is
    /// queued as soon as Pro is on.
    func requestDownload(metadata: PlexMetadata, quality: DownloadQuality? = nil) {
        requestDownloads([metadata], quality: quality)
    }

    /// Queues a batch in order. `completion` receives how many titles were queued, or `nil` when the free limit stopped the batch
    /// and the paywall was closed without Pro.
    func requestDownloads(_ metadatas: [PlexMetadata], quality: DownloadQuality? = nil, completion: @escaping @MainActor (Int?) -> Void = { _ in }) {
        let adding = titlesAdded(by: metadatas)
        gate(adding: adding, completion: completion) { [self] in
            if metadatas.count == 1, let only = metadatas.first {
                enqueue(metadata: only, quality: quality)
                return adding
            }
            return enqueueAll(metadatas, quality: quality)
        }
    }

    /// Resumes or retries a paused or failed download, which puts it back in the queue and so counts against the free limit.
    func requestResume(_ ratingKey: String) {
        gate(adding: 1, completion: { _ in }) { [self] in
            resume(ratingKey)
            return 1
        }
    }

    /// How many of `metadatas` would join the queue: new titles, plus paused or failed ones that a batch re-queues.
    private func titlesAdded(by metadatas: [PlexMetadata]) -> Int {
        metadatas.filter { metadata in
            guard !metadata.id.isEmpty else { return false }
            guard let existing = item(for: metadata.id) else { return true }
            return existing.state == .failed || existing.state == .paused
        }.count
    }

    private func gate(adding: Int, completion: @escaping @MainActor (Int?) -> Void, run: @escaping @MainActor () -> Int) {
        let decision = ProPolicy.downloadDecision(isPro: ProAccess.shared.isPro, activeDownloads: activeDownloadCount, adding: adding)
        guard adding > 0, decision == .requiresPro else {
            completion(run())
            return
        }
        AppLogger.notice("Download limit reached with \(activeDownloadCount) active; asking for Pro to add \(adding)", .store)
        ProAccess.shared.requestUnlock(.unlimitedDownloads) { unlocked in
            completion(unlocked ? run() : nil)
        }
    }
}

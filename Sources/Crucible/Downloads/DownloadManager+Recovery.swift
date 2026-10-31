import CrucibleCore
import Foundation
import MidgarCore

extension DownloadManager {
    // MARK: - Recovery

    func recoverLiveTasks() {
        // Clean slate: cancel any tasks left in the background session from a previous launch, then
        // re-resolve each active download fresh (it resumes from the segments already on disk). This
        // avoids trusting a recovered task that may be stuck, which would freeze the item.
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
            Task { @MainActor in DownloadManager.shared.finishBootstrap() }
        }
    }

    private func finishBootstrap() {
        for i in items.indices {
            switch items[i].state {
            case .downloading:
                if completedAssetExists(items[i]) {
                    items[i].state = .completed
                    items[i].progress = 1
                    items[i].completedAt = items[i].completedAt ?? Date()
                }
            case .completed:
                if !completedAssetExists(items[i]) {
                    items[i].state = .queued
                    items[i].progress = 0
                    items[i].completedAt = nil
                    MidgarLog.notice("Download re-queued (asset incomplete on disk) key=\(items[i].ratingKey)", category: .persistence)
                }
            case .waitingForWiFi:
                items[i].state = .queued
            default:
                break
            }
        }
        Task { [store, items] in
            await store.reconcile(keepRatingKeys: Set(items.map(\.ratingKey)))
        }
        persist()
        emit(.changed)
        for item in items where item.state == .downloading {
            beginResolve(item.ratingKey, countAsFailure: false)
        }
        pumpQueue()
    }

    /// True only when the persisted playlist exists AND every segment it references is on disk. The
    /// playlist is written at resolve time — before any segment downloads — so its mere presence says
    /// nothing about completeness; trusting it marked interrupted downloads as finished.
    private func completedAssetExists(_ item: DownloadItem) -> Bool {
        let playlistURL = DownloadPaths.playlistURL(ratingKey: item.ratingKey)
        guard let names = HLSDownloader.referencedLocalNames(inPlaylistAt: playlistURL), !names.isEmpty else { return false }
        let dir = DownloadPaths.assetDir(ratingKey: item.ratingKey)
        let fm = FileManager.default
        return names.allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }
}

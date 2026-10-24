import CrucibleCore
import Foundation

extension DownloadManager {
    // MARK: - Queries

    func item(for ratingKey: String) -> DownloadItem? {
        items.first { $0.ratingKey == ratingKey }
    }

    func state(for ratingKey: String) -> DownloadState? {
        item(for: ratingKey)?.state
    }

    func isDownloaded(_ ratingKey: String) -> Bool {
        item(for: ratingKey)?.state == .completed
    }

    var hasActiveDownloads: Bool { items.contains { $0.state.isActive } }
    var activeDownloadCount: Int { items.filter { $0.state.isActive }.count }

    func index(_ ratingKey: String) -> Int? {
        items.firstIndex { $0.ratingKey == ratingKey }
    }

    func offlineAsset(for ratingKey: String) -> OfflineAsset? {
        guard let item = item(for: ratingKey), item.state == .completed else { return nil }
        guard FileManager.default.fileExists(atPath: DownloadPaths.playlistURL(ratingKey: ratingKey).path) else { return nil }
        LocalMediaServer.shared.awaitReady(timeout: 2)
        guard let url = LocalMediaServer.shared.playlistURL(ratingKey: ratingKey) else { return nil }
        return OfflineAsset(
            fileURL: url,
            markers: item.markers.map(\.asPlexMarker),
            durationSecs: item.durationSecs,
            resumeSecs: item.resumeSecs
        )
    }

    func totalBytesOnDisk() async -> Int64 {
        items.filter { $0.state == .completed }.reduce(0) { $0 + $1.totalBytes }
    }

    func availableCapacity() async -> Int64 { await store.availableCapacityBytes() }
}

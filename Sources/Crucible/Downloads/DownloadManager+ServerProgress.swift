import CrucibleCore
import Foundation

/// A completed download keeps up with the server's record of its title: watched to the end, or further along, on another
/// device, it reads the same here, so its progress bar, the place it resumes from and Free Up Space agree with the server. A
/// download played further offline keeps its own place, which the device reports to the server itself.
extension DownloadManager {
    /// The least time between two looks at the server that its changes ask for.
    private static let serverProgressInterval: Duration = .seconds(20)
    /// How many titles one look asks the server about, so the request stays a short URL however many downloads there are.
    private static let serverProgressBatch = 100

    func followServerProgress() {
        guard serverProgress == nil else { return }
        serverProgress = ServerStateFollower(every: Self.serverProgressInterval, matching: { $0.everything || $0.movesWatchState }, isOnScreen: {
            true
        }, refresh: { [weak self] in
            self?.catchUpWithServer()
        })
        catchUpWithServer()
    }

    private func catchUpWithServer() {
        guard let config, isOnline else { return }
        let keys = items.filter { $0.state == .completed }.map(\.ratingKey)
        guard !keys.isEmpty else { return }
        let api = APIClient(baseURL: config.baseURL, token: config.token)
        let batches = stride(from: 0, to: keys.count, by: Self.serverProgressBatch).map { Array(keys[$0..<min($0 + Self.serverProgressBatch, keys.count)]) }
        Task { [weak self] in
            var current: [String: PlexMetadata] = [:]
            for batch in batches {
                current.merge(await CurrentMetadata.fetch(batch) { try await api.requestContainer($0) }) { first, _ in first }
            }
            self?.adoptServerProgress(current)
        }
    }

    private func adoptServerProgress(_ current: [String: PlexMetadata]) {
        var changed = false
        for index in items.indices where items[index].state == .completed {
            guard let item = current[items[index].ratingKey],
                  let offset = Self.serverOffsetMs(of: item, download: items[index]),
                  offset > items[index].viewOffsetMs + Int(ResumePoint.reportTolerance * 1000) else { continue }
            items[index].viewOffsetMs = offset
            changed = true
        }
        guard changed else { return }
        persist()
        emit(.changed)
    }

    /// Where the server has the title on the download's own clock. A place it holds is taken as it is, a rewatch in progress
    /// included; a title it counts as watched without a place reads as finished only when it was watched after the download
    /// was made, since a title watched before keeps its play count when it is downloaded to watch again.
    private static func serverOffsetMs(of item: PlexMetadata, download: DownloadItem) -> Int? {
        if let offset = item.viewOffset, offset > 0 { return offset }
        guard item.isWatched, download.durationMs > 0, let viewedAt = item.lastViewedAt,
              Date(timeIntervalSince1970: TimeInterval(viewedAt)) > download.createdAt else { return nil }
        return download.durationMs
    }
}

import Foundation
import MidgarCore

/// History keeps the title and poster an item had when it was played. Lists built from history look the items up again
/// in one request, so a title or poster changed since (by Library Research, a fix match or an edit) shows.
package enum CurrentMetadata {
    package typealias Request = @Sendable (PlexEndpoint) async throws -> PlexMediaContainer

    /// The items with `ratingKeys` as Plex shows them now, by rating key; empty when the lookup fails, so callers keep
    /// what history said.
    package static func fetch(_ ratingKeys: [String], request: Request) async -> [String: PlexMetadata] {
        var seen = Set<String>()
        let keys = ratingKeys.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !keys.isEmpty else { return [:] }
        do {
            let container = try await request(.items(ratingKeys: keys))
            return byKey(container.Metadata ?? [])
        } catch {
            MidgarLog.error("Current metadata of \(keys.count) played items failed: \(error.localizedDescription)", category: .networking)
            return [:]
        }
    }

    /// Items by rating key, the first of any repeat.
    package static func byKey(_ items: [PlexMetadata]) -> [String: PlexMetadata] {
        Dictionary(items.compactMap { item in item.ratingKey.map { ($0, item) } }, uniquingKeysWith: { first, _ in first })
    }

    /// A rail item from history as Plex shows it now, keeping when and by whom it was played.
    package static func played(_ item: PlexMetadata, now current: [String: PlexMetadata]) -> PlexMetadata {
        guard let key = item.ratingKey, var fresh = current[key] else { return item }
        fresh.viewedAt = item.viewedAt
        fresh.accountID = item.accountID
        fresh.deviceID = item.deviceID
        return fresh
    }

    /// A Watch History row as Plex shows its item now: the current title and artwork, the same play.
    package static func played(_ item: HistoryItem, now current: [String: PlexMetadata]) -> HistoryItem {
        guard let fresh = current[item.ratingKey] else { return item }
        return HistoryItem(
            ratingKey: item.ratingKey,
            title: fresh.title.isEmpty ? item.title : fresh.title,
            type: item.type,
            viewedAt: item.viewedAt,
            thumb: fresh.thumb ?? item.thumb,
            grandparentThumb: fresh.grandparentThumb ?? item.grandparentThumb,
            grandparentTitle: fresh.grandparentTitle ?? item.grandparentTitle,
            grandparentRatingKey: item.grandparentRatingKey,
            parentRatingKey: item.parentRatingKey,
            parentIndex: item.parentIndex,
            index: item.index,
            duration: item.duration,
            uniqueId: item.uniqueId,
            historyKey: item.historyKey
        )
    }
}

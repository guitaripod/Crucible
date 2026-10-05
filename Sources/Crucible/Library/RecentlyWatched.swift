import Foundation

/// Builds the per-library "Recently Watched" rail from the server's play history, scoped to the
/// library section the grid is showing.
enum RecentlyWatched {
    static let limit = 20
    private static let fetchSize = 120

    static func load(api: APIClient, sectionId: String, groupingByShow: Bool) async -> [PlexMetadata] {
        let response: PlexHistoryResponse?
        do {
            response = try await api.request(.sectionHistory(sectionId: sectionId, size: fetchSize))
        } catch {
            AppLogger.error("Recently watched fetch failed section=\(sectionId): \(error.localizedDescription)", .networking)
            return []
        }
        let rows = ownerScoped(response?.MediaContainer.Metadata ?? [])
            .sorted { ($0.viewedAt ?? 0) > ($1.viewedAt ?? 0) }

        var seen = Set<String>()
        var items = [PlexMetadata]()
        for row in rows {
            guard let key = groupKey(row, groupingByShow: groupingByShow), seen.insert(key).inserted else { continue }
            items.append(PlexMetadata(historyEntry: row))
            if items.count == limit { break }
        }
        AppLogger.info("Recently watched section=\(sectionId): \(items.count) items from \(rows.count) rows", .networking)
        return items
    }

    /// A TV rail collapses to one card per show; a movie rail keys on the item itself.
    private static func groupKey(_ row: PlexHistoryEntry, groupingByShow: Bool) -> String? {
        if groupingByShow, let show = row.grandparentRatingKey { return show }
        return row.ratingKey
    }

    /// History returned to an owner token spans every account on the server. When more than one
    /// account appears, the rows are narrowed to the owner (account id 1); single-account mirrors
    /// and auto-scoped shared-user tokens are left untouched.
    private static func ownerScoped(_ rows: [PlexHistoryEntry]) -> [PlexHistoryEntry] {
        let accounts = Set(rows.compactMap(\.accountID))
        guard accounts.count > 1 else { return rows }
        return rows.filter { $0.accountID == 1 }
    }
}

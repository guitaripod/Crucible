import Foundation

/// Builds the per-library "Recently Watched" rail from the server's play history, scoped to the
/// library section the grid is showing.
package enum RecentlyWatched {
    package static let railLimit = 20
    package static let gridLimit = 120
    private static let rowsPerTitle = 6
    private static let ownerAccountID = 1

    package static func load(api: APIClient, sectionId: String, groupingByShow: Bool, limit: Int = railLimit) async -> [PlexMetadata] {
        let response: PlexHistoryResponse?
        do {
            response = try await api.request(.sectionHistory(sectionId: sectionId, size: limit * rowsPerTitle))
        } catch {
            AppLogger.error("Recently watched fetch failed section=\(sectionId): \(error.localizedDescription)", .networking)
            return []
        }
        let rows = ownerScoped(response?.MediaContainer.Metadata ?? [])
        let items = railItems(from: rows, groupingByShow: groupingByShow, limit: limit)
        AppLogger.info("Recently watched section=\(sectionId): \(items.count) items from \(rows.count) rows", .networking)
        return items
    }

    /// One card per show (or per item), the most recently watched first, up to `limit` cards.
    package static func railItems(from rows: [PlexHistoryEntry], groupingByShow: Bool, limit: Int) -> [PlexMetadata] {
        var seen = Set<String>()
        var items = [PlexMetadata]()
        for row in newestFirst(rows) {
            guard let key = groupKey(row, groupingByShow: groupingByShow), seen.insert(key).inserted else { continue }
            items.append(PlexMetadata(historyEntry: row))
            if items.count == limit { break }
        }
        return items
    }

    /// History returned to an owner token spans every account on the server. When more than one
    /// account appears, the rows are narrowed to the owner (account id 1); single-account mirrors
    /// and auto-scoped shared-user tokens are left untouched.
    package static func ownerScoped(_ rows: [PlexHistoryEntry]) -> [PlexHistoryEntry] {
        let accounts = Set(rows.compactMap(\.accountID))
        guard accounts.count > 1 else { return rows }
        return rows.filter { $0.accountID == ownerAccountID }
    }

    /// The rail is hidden while a filter narrows the grid, and leaves out whatever the Continue banner already offers.
    package static func visible(
        _ recents: [PlexMetadata],
        continueItem: PlexMetadata?,
        kind: LibraryGridKind,
        isFiltering: Bool
    ) -> [PlexMetadata] {
        guard !isFiltering else { return [] }
        return recents.filter { !LibraryContinue.isFeatured($0, by: continueItem, kind: kind) }
    }

    /// Whether a reloaded rail differs from the one on show in a way that needs a redraw.
    package static func differs(_ next: [PlexMetadata], from current: [PlexMetadata]) -> Bool {
        next.map(\.id) != current.map(\.id) || next.map(\.viewedAt) != current.map(\.viewedAt)
    }

    private static func newestFirst(_ rows: [PlexHistoryEntry]) -> [PlexHistoryEntry] {
        rows.sorted { ($0.viewedAt ?? 0) > ($1.viewedAt ?? 0) }
    }

    /// A TV rail collapses to one card per show; a movie rail keys on the item itself.
    private static func groupKey(_ row: PlexHistoryEntry, groupingByShow: Bool) -> String? {
        if groupingByShow, let show = row.grandparentRatingKey { return show }
        return row.ratingKey
    }
}

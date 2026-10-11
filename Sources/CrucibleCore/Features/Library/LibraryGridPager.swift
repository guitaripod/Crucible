import Foundation

/// The paging state of one library grid: which items are loaded, how far into the section the
/// server has been read, and when the next page is due.
package struct LibraryGridPager: Sendable {
    package static let pageSize = 50
    package static let prefetchThreshold = 10
    package static let reloadCeiling = 300
    package static let refreshWindow = 200

    package enum JumpPlan: Equatable, Sendable {
        case scroll(toIndex: Int)
        case loadThenScroll(size: Int)
    }

    package enum ReloadPlan: Equatable, Sendable {
        case refetchLoaded(size: Int)
        case refreshWindow(offset: Int, size: Int)
    }

    package private(set) var ids: [String] = []
    package private(set) var serverOffset = 0
    package private(set) var totalSize = 0
    package private(set) var hasLoaded = false
    package private(set) var isLoading = false
    private var itemsById: [String: PlexMetadata] = [:]

    package init() {}

    package func item(withId id: String) -> PlexMetadata? {
        itemsById[id]
    }

    /// The size that refetches every page already loaded in one request, so a refresh keeps the
    /// scroll position and pagination.
    package var reloadSize: Int {
        max(serverOffset, Self.pageSize)
    }

    /// How to bring watched and progress state up to date after the screen was away. Up to
    /// `reloadCeiling` loaded items are refetched in one request, which also picks up new titles at the
    /// front. Beyond that (after a deep scroll or an A–Z jump) only a window around `anchor` is read and
    /// merged in place, so the cost does not grow with how far the grid was scrolled.
    package func reloadPlan(anchor: Int) -> ReloadPlan {
        guard serverOffset > Self.reloadCeiling else { return .refetchLoaded(size: reloadSize) }
        let latest = max(0, ids.count - Self.refreshWindow)
        let offset = min(max(0, anchor - Self.refreshWindow / 2), latest)
        return .refreshWindow(offset: offset, size: Self.refreshWindow)
    }

    /// Replaces the data of items that are already loaded, leaving the order, the offsets and the
    /// paging position alone.
    package mutating func merge(items: [PlexMetadata]) {
        for item in items where itemsById[item.id] != nil {
            itemsById[item.id] = item
        }
        isLoading = false
    }

    package mutating func beginFetch() {
        isLoading = true
    }

    package mutating func endFetch() {
        isLoading = false
    }

    /// Page one replaces what is loaded; later pages extend it. Items without an id are dropped and
    /// duplicates keep their first position.
    package mutating func apply(items: [PlexMetadata], offset: Int, totalSize: Int) {
        self.totalSize = totalSize
        if offset == 0 {
            replace(with: items)
        } else {
            append(items)
        }
        serverOffset = offset + items.count
        hasLoaded = true
        isLoading = false
    }

    package func shouldLoadNextPage(near index: Int) -> Bool {
        index >= ids.count - Self.prefetchThreshold && serverOffset < totalSize && !isLoading
    }

    /// How to reach the item at `offset` of the whole section: scroll straight there when it is
    /// loaded, scroll to the end when the server has nothing more, otherwise read up to it first.
    package func jumpPlan(toOffset offset: Int) -> JumpPlan {
        if offset < ids.count { return .scroll(toIndex: offset) }
        guard serverOffset < totalSize else { return .scroll(toIndex: max(0, ids.count - 1)) }
        return .loadThenScroll(size: offset - serverOffset + Self.pageSize)
    }

    private mutating func replace(with items: [PlexMetadata]) {
        var seen = Set<String>()
        ids = items.map(\.id).filter { !$0.isEmpty && seen.insert($0).inserted }
        itemsById = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private mutating func append(_ items: [PlexMetadata]) {
        var seen = Set(ids)
        for item in items where !item.id.isEmpty {
            itemsById[item.id] = item
            if seen.insert(item.id).inserted { ids.append(item.id) }
        }
    }
}

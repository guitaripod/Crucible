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
    /// Whether copies of one title fold into one cell (`LibraryDuplicates`).
    private let foldsOverride: Bool?
    private var foldsCopies = true
    /// The grid index each item read from the server landed on, by its offset in the section.
    private var indexByOffset: [Int] = []
    private var slotsByKey: [String: [Int]] = [:]
    private var copiesById: [String: [String]] = [:]

    /// `foldsCopies` decides folding for good; left out, the Merge Duplicates setting decides it each time page one arrives.
    package init(foldsCopies: Bool? = nil) {
        foldsOverride = foldsCopies
    }

    /// The other copies of the title shown as `id`, best first after it.
    package func copies(of id: String) -> [PlexMetadata] {
        (copiesById[id] ?? []).compactMap { itemsById[$0] }
    }

    /// How many titles the section holds once copies are merged: exact when every page is read, otherwise the server's count
    /// less the copies found so far.
    package var titleCount: Int {
        max(ids.count, totalSize - copiesById.values.reduce(0) { $0 + $1.count })
    }

    /// The grid index of the item at `offset` of the whole section.
    package func index(ofOffset offset: Int) -> Int {
        guard !indexByOffset.isEmpty else { return offset }
        return indexByOffset[min(max(offset, 0), indexByOffset.count - 1)]
    }

    /// The section offset of the item shown at grid `index`.
    package func offset(ofIndex index: Int) -> Int {
        indexByOffset.firstIndex { $0 >= index } ?? index
    }

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
        let latest = max(0, serverOffset - Self.refreshWindow)
        let offset = min(max(0, offset(ofIndex: anchor) - Self.refreshWindow / 2), latest)
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
        if offset < serverOffset { return .scroll(toIndex: index(ofOffset: offset)) }
        guard serverOffset < totalSize else { return .scroll(toIndex: max(0, ids.count - 1)) }
        return .loadThenScroll(size: offset - serverOffset + Self.pageSize)
    }

    private mutating func replace(with items: [PlexMetadata]) {
        ids = []
        itemsById = [:]
        indexByOffset = []
        slotsByKey = [:]
        copiesById = [:]
        foldsCopies = foldsOverride ?? Preferences.mergesDuplicateTitles
        append(items)
    }

    private mutating func append(_ items: [PlexMetadata]) {
        for item in items {
            guard !item.id.isEmpty else {
                indexByOffset.append(max(ids.count - 1, 0))
                continue
            }
            let known = itemsById[item.id] != nil
            itemsById[item.id] = item
            if known {
                indexByOffset.append(ids.firstIndex(of: item.id) ?? max(ids.count - 1, 0))
            } else if foldsCopies, let key = LibraryDuplicates.key(of: item),
                      let slot = slotsByKey[key]?.first(where: { itemsById[ids[$0]].map { LibraryDuplicates.areCopies($0, item) } ?? false }) {
                fold(item, into: slot)
                indexByOffset.append(slot)
            } else {
                if foldsCopies, let key = LibraryDuplicates.key(of: item) { slotsByKey[key, default: []].append(ids.count) }
                indexByOffset.append(ids.count)
                ids.append(item.id)
            }
        }
    }

    /// Puts a copy behind the cell at `slot`, or in it when it plays better than the copy shown there.
    private mutating func fold(_ item: PlexMetadata, into slot: Int) {
        let shownId = ids[slot]
        var copies = copiesById.removeValue(forKey: shownId) ?? []
        if let shown = itemsById[shownId], LibraryDuplicates.outranks(item, shown) {
            ids[slot] = item.id
            copiesById[item.id] = [shownId] + copies
        } else {
            copies.append(item.id)
            copiesById[shownId] = copies
        }
    }
}

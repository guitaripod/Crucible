import Foundation

/// The paging state of a genre grid. A genre can span several library sections, each read page by
/// page in the server's title order; the pager merges the sections by title and releases a title
/// only when every section that still has more has a title buffered to compare it with, so the grid
/// never has to reorder what is already on screen.
package struct GenreMergePager: Sendable {
    package static let pageSize = 50
    package static let prefetchThreshold = 10

    private struct Cursor: Sendable {
        var buffer: [PlexMetadata] = []
        var nextStart = 0
        var total: Int?
        var isExhausted = false
    }

    private let order: [GenreSource]
    private var cursors: [GenreSource: Cursor]
    private var released = Set<String>()
    package private(set) var items: [PlexMetadata] = []
    package private(set) var hasLoadedFirstPages = false

    package init(sources: [GenreSource]) {
        order = sources
        cursors = Dictionary(sources.map { ($0, Cursor()) }, uniquingKeysWith: { first, _ in first })
    }

    /// The sections that need their next page before more titles can be released.
    package var sourcesToFetch: [GenreSource] {
        order.filter { source in
            guard let cursor = cursors[source] else { return false }
            return cursor.buffer.isEmpty && !cursor.isExhausted
        }
    }

    /// Where in `source` the next page starts.
    package func nextStart(for source: GenreSource) -> Int {
        cursors[source]?.nextStart ?? 0
    }

    /// Whether more titles can still be read or released.
    package var hasMore: Bool {
        cursors.values.contains { !$0.buffer.isEmpty || !$0.isExhausted }
    }

    /// The number of titles the server reports for the genre, known once every section has answered once.
    package var totalCount: Int? {
        guard hasLoadedFirstPages else { return nil }
        let totals = cursors.values.compactMap(\.total)
        return totals.count == cursors.count ? totals.reduce(0, +) : nil
    }

    package func shouldLoadNextPage(near index: Int, isLoading: Bool) -> Bool {
        !isLoading && hasMore && !sourcesToFetch.isEmpty && index >= items.count - Self.prefetchThreshold
    }

    /// Takes the page that started at `start` in `source`. A page shorter than the page size, or one
    /// that reaches the reported total, is the section's last.
    package mutating func apply(page: [PlexMetadata], total: Int?, start: Int, for source: GenreSource) {
        guard var cursor = cursors[source], start == cursor.nextStart else { return }
        cursor.buffer.append(contentsOf: page)
        cursor.nextStart = start + Self.pageSize
        cursor.total = total ?? cursor.total
        let reachedTotal = (cursor.total ?? 0) > 0 && cursor.nextStart >= (cursor.total ?? 0)
        cursor.isExhausted = page.count < Self.pageSize || reachedTotal
        cursors[source] = cursor
        hasLoadedFirstPages = cursors.values.allSatisfy { $0.nextStart > 0 }
    }

    /// Moves every title that can be ordered now from the section buffers into `items`, returning
    /// how many were added. Duplicates across sections keep their first position.
    @discardableResult
    package mutating func release() -> Int {
        let before = items.count
        while sourcesToFetch.isEmpty, let source = sourceWithNextTitle() {
            guard var cursor = cursors[source], !cursor.buffer.isEmpty else { break }
            let next = cursor.buffer.removeFirst()
            cursors[source] = cursor
            if !next.id.isEmpty, released.insert(next.id).inserted {
                items.append(next)
            }
        }
        return items.count - before
    }

    private func sourceWithNextTitle() -> GenreSource? {
        var best: (source: GenreSource, title: String)?
        for source in order {
            guard let head = cursors[source]?.buffer.first else { continue }
            if let current = best, head.title.localizedStandardCompare(current.title) != .orderedAscending { continue }
            best = (source, head.title)
        }
        return best?.source
    }
}

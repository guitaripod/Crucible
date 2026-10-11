import Foundation

/// The paging state machine behind the history list: where the next page starts, how many plays the
/// server has, and whether a load is running or failed. It owns no tasks; `HistoryFeed` drives it.
package struct HistoryPager: Equatable, Sendable {
    package static let pageSize = 50
    package static let prefetchDistance = 10
    package static let minimumVisibleCount = 12

    package private(set) var offset = 0
    package private(set) var total = 0
    package private(set) var isLoading = false
    package private(set) var isLoadingMore = false
    package private(set) var hasFailed = false

    package init() {}

    /// Whether the server has plays beyond the ones loaded. A missing `totalSize` counts as zero, so it
    /// stops paging.
    package var hasMore: Bool { offset < total }

    /// True when the position is within the last `prefetchDistance` entries of `count`.
    package static func isWithinPrefetchWindow(position: Int, count: Int) -> Bool {
        position >= count - prefetchDistance
    }

    package func needsFirstPage(isEmpty: Bool) -> Bool {
        isEmpty && !isLoading
    }

    package mutating func beginLoading() {
        isLoading = true
    }

    package mutating func finishLoading(offset pageOffset: Int, count: Int, total: Int?) {
        self.total = total ?? 0
        offset = pageOffset + count
        hasFailed = false
        isLoading = false
        isLoadingMore = false
    }

    package mutating func failLoading() {
        isLoading = false
        isLoadingMore = false
        hasFailed = true
    }

    package mutating func cancelLoading() {
        isLoading = false
        isLoadingMore = false
    }

    package mutating func reset() {
        offset = 0
        total = 0
        isLoadingMore = false
        hasFailed = false
    }

    package mutating func clearFailure() {
        hasFailed = false
    }

    /// Keeps fetching while the visible list is too short to scroll or the weekly summary could still be
    /// missing plays from older pages. Returns the offset to load, or nil when nothing should load.
    package mutating func claimNextPage(visibleCount: Int, oldestViewedAt: Int?, now: Date) -> Int? {
        guard hasMore, !isLoadingMore, !isLoading, !hasFailed else { return nil }
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970
        let oldest = oldestViewedAt.map(Double.init) ?? 0
        guard visibleCount < Self.minimumVisibleCount || oldest >= weekAgo else { return nil }
        isLoadingMore = true
        return offset
    }

    /// The scroll-driven variant: it ignores a previous failure, so scrolling retries a failed page.
    package mutating func claimPrefetchPage() -> Int? {
        guard hasMore, !isLoadingMore else { return nil }
        isLoadingMore = true
        return offset
    }

    package func emptyState(isEmpty: Bool, visibleIsEmpty: Bool, filter: HistoryFilter) -> HistoryEmptyState {
        if isEmpty {
            if isLoading { return .loading }
            return hasFailed ? .loadFailed : .noActivity
        }
        if visibleIsEmpty && !hasMore { return .noMatches(filter) }
        return .populated
    }
}

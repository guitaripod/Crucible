import Foundation

/// Loads the watch history one page at a time and keeps the plays loaded so far. A screen owns one
/// feed, calls the intent methods below, and reacts to `onEvent` by redrawing from `items` and `pager`.
@MainActor
package final class HistoryFeed {
    package enum Event: Sendable {
        case pageLoaded
        case failed
    }

    package typealias Request = @Sendable (PlexEndpoint) async throws -> PlexMediaContainer

    package private(set) var items: [HistoryItem] = []
    package private(set) var pager = HistoryPager()
    package var onEvent: (@MainActor (Event) -> Void)?

    private let request: Request
    private let now: @Sendable () -> Date
    private var loadTask: Task<Void, Never>?

    package init(request: @escaping Request, now: @escaping @Sendable () -> Date = { Date() }) {
        self.request = request
        self.now = now
    }

    package convenience init(api: APIClient) {
        self.init(request: { try await api.requestContainer($0) })
    }

    deinit {
        loadTask?.cancel()
    }

    package func items(matching filter: HistoryFilter) -> [HistoryItem] {
        items.filter { filter.includes($0) }
    }

    package func emptyState(filter: HistoryFilter) -> HistoryEmptyState {
        pager.emptyState(isEmpty: items.isEmpty, visibleIsEmpty: items(matching: filter).isEmpty, filter: filter)
    }

    /// Loads the first page when nothing is loaded and nothing is loading; call it on every appearance.
    package func loadFirstPageIfNeeded() {
        if pager.needsFirstPage(isEmpty: items.isEmpty) {
            loadPage(offset: 0)
        }
    }

    package func refresh() {
        pager.reset()
        loadPage(offset: 0)
    }

    package func retry() {
        pager.clearFailure()
        loadPage(offset: 0)
    }

    /// Fetches the next page while the visible list is short or the weekly summary could still be
    /// missing plays. Call it after every redraw with the number of rows the current filter shows.
    package func loadMoreIfNeeded(visibleCount: Int) {
        guard let offset = pager.claimNextPage(visibleCount: visibleCount, oldestViewedAt: items.last?.viewedAt, now: now()) else { return }
        loadPage(offset: offset)
    }

    /// Fetches the next page because the user scrolled or focused near the end of the list.
    package func prefetchMore() {
        guard let offset = pager.claimPrefetchPage() else { return }
        loadPage(offset: offset)
    }

    /// Stops any running load, for example when the screen is popped.
    package func cancel() {
        loadTask?.cancel()
        loadTask = nil
        pager.cancelLoading()
    }

    /// The full metadata for a play, or nil when the server no longer has it. The caller starts playback.
    package func metadata(for item: HistoryItem) async throws -> PlexMetadata? {
        try await request(.metadata(ratingKey: item.ratingKey)).Metadata?.first
    }

    private func loadPage(offset: Int) {
        loadTask?.cancel()
        pager.beginLoading()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await request(.history(start: offset, size: HistoryPager.pageSize))
                guard !Task.isCancelled else { return }
                let page = HistoryItem.items(in: container, offset: offset)
                pager.finishLoading(offset: offset, count: page.count, total: container.totalSize)
                items = offset == 0 ? page : items + page
                loadTask = nil
                onEvent?(.pageLoaded)
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("History page \(offset) failed: \(error.localizedDescription)", .networking)
                loadTask = nil
                pager.failLoading()
                onEvent?(.failed)
            }
        }
    }
}

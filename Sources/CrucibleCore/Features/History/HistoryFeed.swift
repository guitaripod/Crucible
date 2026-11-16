import Foundation
import MidgarCore

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
    /// A look for new plays asked for while a page was loading, made once that page is in.
    private var refreshTopPending = false
    private var pagerBeforeRefresh: HistoryPager?

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

    /// Reloads from the top and replaces the list. While it runs the list stays as it was, and if the
    /// request fails the paging state comes back too, so the old list can still be paged.
    package func refresh() {
        if pagerBeforeRefresh == nil, !items.isEmpty {
            pagerBeforeRefresh = pager
        }
        pager.reset()
        loadPage(offset: 0)
    }

    /// Fetches the newest page and puts the plays that came since on top, keeping the plays paged in below: for a screen
    /// coming back into view, where replacing the list would drop everything the viewer scrolled to and the row they left
    /// from. When the page does not reach the newest play already listed (more came than a page holds), it refreshes.
    package func refreshTop() {
        guard let newestKnown = items.first, loadTask == nil else {
            refreshTopPending = loadTask != nil && !items.isEmpty
            loadFirstPageIfNeeded()
            return
        }
        pager.beginLoading()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await request(.history(start: 0, size: HistoryPager.pageSize))
                guard !Task.isCancelled else { return }
                let played = HistoryItem.items(in: container, offset: 0)
                guard let overlap = played.firstIndex(where: { $0.ratingKey == newestKnown.ratingKey && $0.viewedAt == newestKnown.viewedAt }) else {
                    loadTask = nil
                    pager.cancelLoading()
                    refresh()
                    return
                }
                let fresh = Array(played.prefix(overlap))
                if !fresh.isEmpty {
                    let current = await CurrentMetadata.fetch(fresh.map(\.ratingKey), request: request)
                    guard !Task.isCancelled else { return }
                    items = fresh.map { CurrentMetadata.played($0, now: current).placedOnTop } + items
                    pager.noteAdded(fresh.count)
                }
                pager.cancelLoading()
                loadTask = nil
                if !fresh.isEmpty { onEvent?(.pageLoaded) }
            } catch {
                guard !Task.isCancelled else { return }
                MidgarLog.error("History refresh failed: \(error.localizedDescription)", category: .networking)
                loadTask = nil
                pager.cancelLoading()
            }
        }
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
        restorePagerAfterFailedRefresh()
        pager.cancelLoading()
    }

    /// Forgets a play the server has deleted, keeping the next page where the server's list now continues.
    package func drop(_ item: HistoryItem) {
        guard let index = items.firstIndex(of: item) else { return }
        items.remove(at: index)
        pager.noteRemoved()
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
                let played = HistoryItem.items(in: container, offset: offset)
                let current = await CurrentMetadata.fetch(played.map(\.ratingKey), request: request)
                guard !Task.isCancelled else { return }
                let page = played.map { CurrentMetadata.played($0, now: current) }
                pager.finishLoading(offset: offset, count: page.count, total: container.totalSize)
                pagerBeforeRefresh = nil
                items = offset == 0 ? page : items + page
                loadTask = nil
                onEvent?(.pageLoaded)
                if refreshTopPending {
                    refreshTopPending = false
                    if offset > 0 { refreshTop() }
                }
            } catch {
                guard !Task.isCancelled else { return }
                MidgarLog.error("History page \(offset) failed: \(error.localizedDescription)", category: .networking)
                loadTask = nil
                if pagerBeforeRefresh != nil {
                    restorePagerAfterFailedRefresh()
                    pager.cancelLoading()
                } else {
                    pager.failLoading()
                }
                onEvent?(.failed)
            }
        }
    }

    private func restorePagerAfterFailedRefresh() {
        guard let saved = pagerBeforeRefresh else { return }
        pagerBeforeRefresh = nil
        pager = saved
    }
}

import Foundation

/// What a genre grid does apart from drawing: the first page of every library section the genre
/// spans paints the grid, and the next pages arrive as the focus nears the end, like a library grid.
/// The iPhone genre screen keeps `GenreBrowseSession`, which reads everything at once.
@MainActor
package final class GenreGridModel {
    package enum ContentState: Equatable, Sendable {
        case loading
        case content
        case empty
        case failed(message: String)
    }

    package enum Update: Sendable {
        case contentState
        case pageLoaded
        case pageFailed
    }

    package let genre: SearchGenre
    package var onUpdate: (@MainActor (Update) -> Void)?
    package private(set) var contentState = ContentState.loading
    package private(set) var pager: GenreMergePager

    private let loader: SearchLoader
    private var loadTask: Task<Void, Never>?
    private var isLoading = false

    package init(genre: SearchGenre, loader: SearchLoader) {
        self.genre = genre
        self.loader = loader
        pager = GenreMergePager(sources: genre.sources)
    }

    deinit {
        loadTask?.cancel()
    }

    package var items: [PlexMetadata] { pager.items }

    /// Reads the first pages. Calling it again after a failure starts over (Try Again); after the
    /// grid has loaded it does nothing.
    package func appear() {
        guard !isLoading, contentState != .content else { return }
        pager = GenreMergePager(sources: genre.sources)
        setState(.loading)
        fetchNextPages()
    }

    /// Cancels the read in flight. A first page that never arrived leaves the screen loading until `appear()` runs again.
    package func disappear() {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    /// Call as focus reaches `index` of `items`; reads the next page when it is due.
    package func itemFocused(at index: Int) {
        guard contentState == .content, pager.shouldLoadNextPage(near: index, isLoading: isLoading) else { return }
        fetchNextPages()
    }

    private func setState(_ state: ContentState) {
        guard contentState != state else { return }
        contentState = state
        onUpdate?(.contentState)
    }

    private func fetchNextPages() {
        let sources = pager.sourcesToFetch
        guard !sources.isEmpty else { return }
        isLoading = true
        let requests = sources.map { ($0, pager.nextStart(for: $0)) }
        loadTask = Task { [weak self, loader] in
            do {
                let pages = try await Self.read(requests, with: loader)
                guard !Task.isCancelled, let self else { return }
                apply(pages)
            } catch {
                guard !Task.isCancelled, (error as? URLError)?.code != .cancelled, let self else { return }
                AppLogger.error("Genre browse failed genre=\(genre.title): \(error.localizedDescription)", .networking)
                fail(error)
            }
        }
    }

    private nonisolated static func read(
        _ requests: [(GenreSource, Int)],
        with loader: SearchLoader
    ) async throws -> [(source: GenreSource, start: Int, items: [PlexMetadata], total: Int?)] {
        try await withThrowingTaskGroup(of: (GenreSource, Int, [PlexMetadata], Int?).self) { group in
            for (source, start) in requests {
                group.addTask {
                    let page = try await loader.genrePage(source: source, start: start, size: GenreMergePager.pageSize)
                    return (source, start, page.items, page.total)
                }
            }
            var pages = [(source: GenreSource, start: Int, items: [PlexMetadata], total: Int?)]()
            for try await page in group { pages.append((page.0, page.1, page.2, page.3)) }
            return pages
        }
    }

    private func apply(_ pages: [(source: GenreSource, start: Int, items: [PlexMetadata], total: Int?)]) {
        isLoading = false
        for page in pages {
            pager.apply(page: page.items, total: page.total, start: page.start, for: page.source)
        }
        let isFirstPaint = contentState != .content
        pager.release()
        if pager.items.isEmpty && !pager.hasMore {
            setState(.empty)
        } else if isFirstPaint {
            setState(.content)
        }
        if contentState == .content { onUpdate?(.pageLoaded) }
    }

    private func fail(_ error: Error) {
        isLoading = false
        if contentState == .content {
            onUpdate?(.pageFailed)
        } else {
            setState(.failed(message: error.localizedDescription))
        }
    }
}

import Foundation

@MainActor
package final class SearchSession {
    package nonisolated static let defaultDebounce = Duration.milliseconds(300)

    package var onChange: ((SearchState) -> Void)?
    package private(set) var state: SearchState = .idle(SearchIdleContent(recents: [], genres: [], recentlyAdded: []))
    package private(set) var resultsQuery: String?

    private let loader: SearchLoader
    private let recentsStore: SearchRecentsStore
    private let debounce: Duration
    private var query = ""
    private var scope: SearchScope = .all
    private var activeQuery: String?
    private var results: SearchResults?
    private var genres: [SearchGenre] = []
    private var recentlyAdded: [PlexMetadata] = []
    private var searchTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?

    package init(loader: SearchLoader, recents: SearchRecentsStore = .preferences, debounce: Duration = SearchSession.defaultDebounce) {
        self.loader = loader
        self.recentsStore = recents
        self.debounce = debounce
    }

    deinit {
        searchTask?.cancel()
        idleTask?.cancel()
    }

    private var isSearching: Bool {
        SearchQuery.isSearchable(query)
    }

    /// Shows the idle content and loads the genres and recently added titles behind it.
    package func start() {
        showIdle()
        loadIdle()
    }

    /// Refreshes the idle content when the screen comes back. A query still in the field is restored instead: a search that
    /// `suspend()` interrupted runs again, and results that changed in the meantime are rendered again.
    package func resume() {
        guard !isSearching else {
            restoreSearch()
            return
        }
        showIdle()
        loadIdle()
    }

    /// Cancels in-flight work when the screen goes away. A query that never produced results is forgotten so it can run again.
    package func suspend() {
        searchTask?.cancel()
        idleTask?.cancel()
        if activeQuery != resultsQuery { activeQuery = nil }
    }

    /// Feeds the search field's text and scope. Queries shorter than the minimum return to idle; a query that already has
    /// results (a scope change, for instance) re-renders from them; a new query runs after the debounce.
    package func update(query raw: String?, scope: SearchScope) {
        self.scope = scope
        let query = SearchQuery.normalized(raw)
        self.query = query
        guard SearchQuery.isSearchable(query) else {
            searchTask?.cancel()
            activeQuery = nil
            results = nil
            resultsQuery = nil
            showIdle()
            return
        }
        if query == resultsQuery {
            renderResults()
        } else if query != activeQuery {
            performSearch(query: query, debounce: true)
        }
    }

    /// Runs a recent search straight away, with the scope reset to All.
    package func select(recent recentQuery: String) {
        query = recentQuery
        scope = .all
        if recentQuery == resultsQuery {
            searchTask?.cancel()
            activeQuery = recentQuery
            renderResults()
        } else {
            performSearch(query: recentQuery, debounce: false)
        }
    }

    /// Runs the failed query again, but only while it is still what the search field holds.
    package func retry(_ failedQuery: String) {
        guard query == failedQuery else { return }
        performSearch(query: failedQuery, debounce: false)
    }

    /// Records the current query in the recent searches. Call it when a search result is opened.
    package func rememberCurrentQuery() {
        recentsStore.update { $0.remember(query) }
    }

    package func clearRecents() {
        recentsStore.update { $0.clear() }
        showIdle()
    }

    package func removeRecent(_ recentQuery: String) {
        recentsStore.update { $0.remove(recentQuery) }
        showIdle()
    }

    private func emit(_ newState: SearchState) {
        state = newState
        onChange?(newState)
    }

    private func showIdle() {
        emit(.idle(SearchIdleContent(recents: recentsStore.load(), genres: genres, recentlyAdded: recentlyAdded)))
    }

    private func loadIdle() {
        idleTask?.cancel()
        idleTask = Task { [weak self, loader] in
            async let loadedGenres = loader.genres()
            async let loadedRecent = loader.recentlyAdded()
            let (newGenres, newRecent) = await (loadedGenres, loadedRecent)
            guard !Task.isCancelled, let self else { return }
            genres = newGenres
            recentlyAdded = newRecent
            if !isSearching { showIdle() }
        }
    }

    private func performSearch(query: String, debounce: Bool) {
        searchTask?.cancel()
        activeQuery = query
        if resultsQuery == nil { emit(.loading) }
        searchTask = Task { [weak self, loader, delay = self.debounce] in
            if debounce {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self else { return }
            do {
                let found = try await loader.search(query: query)
                guard !Task.isCancelled else { return }
                results = found
                resultsQuery = query
                renderResults()
            } catch {
                guard !Task.isCancelled, (error as? URLError)?.code != .cancelled else { return }
                AppLogger.error("Search failed query=\(query): \(error.localizedDescription)", .networking)
                activeQuery = nil
                results = nil
                resultsQuery = nil
                emit(.failed(query: query, message: error.localizedDescription))
            }
        }
    }

    private func restoreSearch() {
        if query == resultsQuery {
            renderResults(onlyIfChanged: true)
        } else if query != activeQuery {
            performSearch(query: query, debounce: false)
        }
    }

    private func renderResults(onlyIfChanged: Bool = false) {
        guard let results, let query = resultsQuery else { return }
        let parts = results.parts(for: scope)
        let rendered: SearchState = parts.isEmpty ? .empty(query: query, scope: scope) : .results(query: query, parts: parts)
        guard !onlyIfChanged || rendered != state else { return }
        emit(rendered)
    }
}

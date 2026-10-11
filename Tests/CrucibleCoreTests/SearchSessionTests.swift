import Foundation
import Testing
@testable import CrucibleCore

@MainActor
struct SearchSessionTests {
    private struct Boom: LocalizedError {
        var errorDescription: String? { "boom" }
    }

    @MainActor
    private final class Harness {
        let session: SearchSession
        let log = SearchRequestLog()
        let memory: SearchMemoryRecents
        private(set) var states: [SearchState] = []

        init(
            recents: [String] = [],
            debounce: Duration = .milliseconds(20),
            handler: @escaping @Sendable (PlexEndpoint) async throws -> PlexMediaContainer
        ) {
            memory = SearchMemoryRecents(recents)
            let log = log
            let loader = SearchLoader { endpoint in
                await log.record(endpoint)
                return try await handler(endpoint)
            }
            session = SearchSession(loader: loader, recents: memory.store, debounce: debounce)
            session.onChange = { [unowned self] state in states.append(state) }
        }

        var last: SearchState? { states.last }

        var kinds: [String] {
            states.map {
                switch $0 {
                case .idle: return "idle"
                case .loading: return "loading"
                case .results: return "results"
                case .empty: return "empty"
                case .failed: return "failed"
                }
            }
        }

        func waitForState(count: Int) async {
            await searchWaitUntil { states.count >= count }
        }

        func waitFor(_ kind: String, count: Int = 1) async {
            await searchWaitUntil { kinds.filter { $0 == kind }.count >= count }
        }
    }

    private static func serving(_ container: PlexMediaContainer) -> @Sendable (PlexEndpoint) async throws -> PlexMediaContainer {
        { endpoint in
            if case .search = endpoint { return container }
            return try SearchFixtures.container([:])
        }
    }

    @Test func defaultDebounceIsThreeHundredMilliseconds() {
        #expect(SearchSession.defaultDebounce == .milliseconds(300))
    }

    @Test func shortQueriesStayIdleAndNeverHitTheServer() async {
        let harness = Harness(handler: Self.serving(SearchFixtures.allHits))
        harness.session.update(query: " a ", scope: .all)
        harness.session.update(query: nil, scope: .all)
        #expect(harness.kinds == ["idle", "idle"])
        #expect(await harness.log.count == 0)
    }

    @Test func aQueryShowsLoadingThenResultsAfterTheDebounce() async {
        let harness = Harness(handler: Self.serving(SearchFixtures.allHits))
        harness.session.update(query: "  halo ", scope: .all)
        #expect(harness.kinds == ["loading"])
        await harness.waitFor("results")

        guard case .results(let query, let parts) = harness.last else {
            Issue.record("expected results, got \(String(describing: harness.last))")
            return
        }
        #expect(query == "halo")
        #expect(parts.top?.id == "1")
        #expect(parts.shows.map(\.id) == ["2"])
        #expect(await harness.log.searchQueries == ["halo"])
        #expect(harness.session.resultsQuery == "halo")
    }

    @Test func rapidTypingRunsOnlyTheLastQuery() async {
        let harness = Harness(debounce: .milliseconds(60), handler: Self.serving(SearchFixtures.allHits))
        for text in ["ha", "hal", "halo"] {
            harness.session.update(query: text, scope: .all)
        }
        await harness.waitFor("results")
        try? await Task.sleep(for: .milliseconds(120))
        #expect(await harness.log.searchQueries == ["halo"])
        #expect(harness.kinds.filter { $0 == "results" }.count == 1)
    }

    @Test func theSameQueryWhileItIsActiveDoesNotFireAgain() async {
        let harness = Harness(handler: Self.serving(SearchFixtures.allHits))
        harness.session.update(query: "halo", scope: .all)
        harness.session.update(query: "halo", scope: .all)
        await harness.waitFor("results")
        harness.session.update(query: "halo", scope: .all)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(await harness.log.searchQueries == ["halo"])
    }

    @Test func aScopeChangeRerendersFromCachedResultsWithoutANetworkCall() async {
        let harness = Harness(handler: Self.serving(SearchFixtures.allHits))
        harness.session.update(query: "halo", scope: .all)
        await harness.waitFor("results")

        harness.session.update(query: "halo", scope: .movies)
        guard case .results(_, let movies) = harness.last else {
            Issue.record("expected results")
            return
        }
        #expect(movies.top?.id == "1" && movies.shows.isEmpty && movies.episodes.isEmpty)
        #expect(await harness.log.searchQueries == ["halo"])
    }

    @Test func aScopeWithNoMatchesIsEmptyWithItsScope() async throws {
        let moviesOnly = try SearchFixtures.searchContainer([[SearchFixtures.haloMovie]])
        let harness = Harness(handler: Self.serving(moviesOnly))
        harness.session.update(query: "halo", scope: .all)
        await harness.waitFor("results")
        harness.session.update(query: "halo", scope: .episodes)
        #expect(harness.last == .empty(query: "halo", scope: .episodes))
    }

    @Test func noHitsAtAllIsEmpty() async {
        let harness = Harness(handler: Self.serving(SearchFixtures.noHits))
        harness.session.update(query: "zzz", scope: .all)
        await harness.waitFor("empty")
        #expect(harness.last == .empty(query: "zzz", scope: .all))
    }

    @Test func loadingOnlyShowsWhenThereAreNoCachedResults() async {
        let harness = Harness(handler: Self.serving(SearchFixtures.allHits))
        harness.session.update(query: "halo", scope: .all)
        await harness.waitFor("results")
        harness.session.update(query: "halo 2", scope: .all)
        #expect(harness.kinds == ["loading", "results"])
        await harness.waitFor("results", count: 2)
        #expect(harness.kinds == ["loading", "results", "results"])
    }

    @Test func clearingTheQueryReturnsToIdleAndForgetsTheResults() async {
        let harness = Harness(handler: Self.serving(SearchFixtures.allHits))
        harness.session.update(query: "halo", scope: .all)
        await harness.waitFor("results")
        harness.session.update(query: "", scope: .all)
        #expect(harness.kinds.last == "idle")
        #expect(harness.session.resultsQuery == nil)

        harness.session.update(query: "halo", scope: .all)
        await harness.waitFor("results", count: 2)
        #expect(await harness.log.searchQueries == ["halo", "halo"])
    }

    @Test func aStaleResponseNeverOverwritesTheNewerQuery() async {
        let gate = SearchGate()
        let harness = Harness(debounce: .zero) { endpoint in
            guard case .search(let query) = endpoint else { return try SearchFixtures.container([:]) }
            if query == "ha" { await gate.wait() }
            return query == "ha" ? SearchFixtures.noHits : SearchFixtures.allHits
        }
        harness.session.update(query: "ha", scope: .all)
        while !(await gate.hasWaiter) { try? await Task.sleep(for: .milliseconds(2)) }
        harness.session.update(query: "hal", scope: .all)
        await gate.open()
        await harness.waitFor("results")
        try? await Task.sleep(for: .milliseconds(60))

        #expect(harness.session.resultsQuery == "hal")
        #expect(harness.kinds == ["loading", "loading", "results"])
    }

    @Test func aFailureShowsTheMessageAndAllowsTheSameQueryAgain() async {
        let counter = SearchRequestLog()
        let harness = Harness { endpoint in
            guard case .search = endpoint else { return try SearchFixtures.container([:]) }
            await counter.record(endpoint)
            if await counter.count == 1 { throw Boom() }
            return SearchFixtures.allHits
        }
        harness.session.update(query: "halo", scope: .all)
        await harness.waitFor("failed")
        #expect(harness.last == .failed(query: "halo", message: "boom"))
        #expect(harness.session.resultsQuery == nil)

        harness.session.update(query: "halo", scope: .all)
        #expect(harness.kinds.last == "loading")
        await harness.waitFor("results")
        #expect(harness.kinds.last == "results")
    }

    @Test func retryRunsImmediatelyOnlyWhileTheQueryIsStillCurrent() async {
        let counter = SearchRequestLog()
        let harness = Harness(debounce: .seconds(5)) { endpoint in
            guard case .search = endpoint else { return try SearchFixtures.container([:]) }
            await counter.record(endpoint)
            if await counter.count == 1 { throw Boom() }
            return SearchFixtures.allHits
        }
        harness.session.select(recent: "halo")
        await harness.waitFor("failed")
        #expect(harness.last == .failed(query: "halo", message: "boom"))

        harness.session.retry("other")
        try? await Task.sleep(for: .milliseconds(40))
        #expect(await counter.count == 1)

        harness.session.retry("halo")
        await harness.waitFor("results")
        #expect(harness.kinds.suffix(2) == ["loading", "results"])
    }

    @Test func aCancelledRequestIsIgnored() async {
        let harness = Harness { endpoint in
            if case .search = endpoint { throw URLError(.cancelled) }
            return try SearchFixtures.container([:])
        }
        harness.session.update(query: "halo", scope: .all)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(harness.kinds == ["loading"])
    }

    @Test func recentsRunAtOnceWithScopeResetToAll() async {
        let harness = Harness(debounce: .seconds(5), handler: Self.serving(SearchFixtures.allHits))
        harness.session.update(query: "dune", scope: .movies)
        harness.session.select(recent: "halo")
        await harness.waitFor("results")
        #expect(await harness.log.searchQueries == ["halo"])
        guard case .results(_, let parts) = harness.last else {
            Issue.record("expected results")
            return
        }
        #expect(parts.shows.map(\.id) == ["2"])
    }

    @Test func selectingTheRecentThatAlreadyHasResultsRerendersThem() async {
        let harness = Harness(handler: Self.serving(SearchFixtures.allHits))
        harness.session.update(query: "halo", scope: .movies)
        await harness.waitFor("results")
        harness.session.select(recent: "halo")
        guard case .results(_, let parts) = harness.last else {
            Issue.record("expected results")
            return
        }
        #expect(parts.shows.map(\.id) == ["2"])
        #expect(await harness.log.searchQueries == ["halo"])
    }

    @Test func selectingTheCachedRecentCancelsASearchStillInFlight() async {
        let gate = SearchGate()
        let harness = Harness(debounce: .zero) { endpoint in
            guard case .search(let query) = endpoint else { return try SearchFixtures.container([:]) }
            if query == "halo 2" { await gate.wait() }
            return SearchFixtures.allHits
        }
        harness.session.update(query: "halo", scope: .all)
        await harness.waitFor("results")
        harness.session.update(query: "halo 2", scope: .all)
        while !(await gate.hasWaiter) { try? await Task.sleep(for: .milliseconds(2)) }

        harness.session.select(recent: "halo")
        await gate.open()
        try? await Task.sleep(for: .milliseconds(60))

        #expect(harness.session.resultsQuery == "halo")
        #expect(harness.kinds == ["loading", "results", "results"])
        harness.session.update(query: "halo", scope: .all)
        #expect(await harness.log.searchQueries == ["halo", "halo 2"])
    }

    @Test func resumeRunsAgainASearchThatSuspendInterrupted() async {
        let harness = Harness(debounce: .seconds(5), handler: Self.serving(SearchFixtures.allHits))
        harness.session.update(query: "halo", scope: .all)
        harness.session.suspend()
        harness.session.resume()
        await harness.waitFor("results")
        #expect(await harness.log.searchQueries == ["halo"])
    }

    @Test func resumeRendersChangedResultsOnlyWhenTheyChanged() async {
        let harness = Harness(handler: Self.serving(SearchFixtures.allHits))
        harness.session.update(query: "halo", scope: .all)
        await harness.waitFor("results")
        harness.session.suspend()
        harness.session.resume()
        #expect(harness.kinds == ["loading", "results"])

        harness.session.update(query: "halo", scope: .movies)
        #expect(harness.kinds == ["loading", "results", "results"])
        harness.session.suspend()
        harness.session.resume()
        #expect(harness.kinds == ["loading", "results", "results"])
        #expect(await harness.log.searchQueries == ["halo"])
    }

    @Test func suspendCancelsADebouncingSearchAndLetsItRunAgain() async {
        let harness = Harness(debounce: .milliseconds(80), handler: Self.serving(SearchFixtures.allHits))
        harness.session.update(query: "halo", scope: .all)
        harness.session.suspend()
        try? await Task.sleep(for: .milliseconds(160))
        #expect(await harness.log.count == 0)

        harness.session.update(query: "halo", scope: .all)
        await harness.waitFor("results")
        #expect(harness.kinds.last == "results")
        #expect(await harness.log.searchQueries == ["halo"])
    }

    @Test func suspendKeepsTheActiveQueryWhenResultsAreCached() async {
        let harness = Harness(handler: Self.serving(SearchFixtures.allHits))
        harness.session.update(query: "halo", scope: .all)
        await harness.waitFor("results")
        harness.session.suspend()
        harness.session.update(query: "halo", scope: .all)
        #expect(harness.kinds.last == "results")
        #expect(await harness.log.searchQueries == ["halo"])
    }

    @Test func openingAResultRemembersTheNormalisedQuery() async {
        let harness = Harness(recents: ["dune"], handler: Self.serving(SearchFixtures.allHits))
        harness.session.update(query: " halo ", scope: .all)
        harness.session.rememberCurrentQuery()
        #expect(harness.memory.queries == ["halo", "dune"])

        harness.session.update(query: "h", scope: .all)
        harness.session.rememberCurrentQuery()
        #expect(harness.memory.queries == ["halo", "dune"])
    }

    @Test func clearAndRemoveRefreshTheIdleContent() async {
        let harness = Harness(recents: ["halo", "dune"], handler: Self.serving(SearchFixtures.allHits))
        harness.session.removeRecent("halo")
        guard case .idle(let afterRemove) = harness.last else {
            Issue.record("expected idle")
            return
        }
        #expect(afterRemove.recents == ["dune"])

        harness.session.clearRecents()
        guard case .idle(let afterClear) = harness.last else {
            Issue.record("expected idle")
            return
        }
        #expect(afterClear.recents.isEmpty && harness.memory.queries.isEmpty)
    }

    @Test func startShowsRecentsAtOnceThenAddsGenresAndRecentlyAdded() async throws {
        let sections = try SearchFixtures.directories([(key: "1", title: "Movies", type: "movie")])
        let genres = try SearchFixtures.directories([(key: "9", title: "Drama", type: nil)])
        let added = try SearchFixtures.page([SearchFixtures.haloMovie, try SearchFixtures.item("8", "artist", "Band")])
        let harness = Harness(recents: ["halo"]) { endpoint in
            switch endpoint {
            case .sections: return sections
            case .sectionGenres: return genres
            case .recentlyAdded: return added
            default: throw Boom()
            }
        }
        harness.session.start()
        guard case .idle(let first) = harness.last else {
            Issue.record("expected idle")
            return
        }
        #expect(first.recents == ["halo"] && first.genres.isEmpty && first.recentlyAdded.isEmpty)

        await harness.waitForState(count: 2)
        guard case .idle(let second) = harness.last else {
            Issue.record("expected idle")
            return
        }
        #expect(second.genres.map(\.title) == ["Drama"])
        #expect(second.recentlyAdded.map(\.id) == ["1"])
        #expect(!second.isEmpty)
    }

    @Test func idleContentThatArrivesDuringASearchDoesNotReplaceIt() async throws {
        let gate = SearchGate()
        let sections = try SearchFixtures.directories([(key: "1", title: "Movies", type: "movie")])
        let harness = Harness(debounce: .zero) { endpoint in
            switch endpoint {
            case .sections:
                await gate.wait()
                return sections
            case .search: return SearchFixtures.allHits
            default: return try SearchFixtures.container([:])
            }
        }
        harness.session.start()
        harness.session.update(query: "halo", scope: .all)
        await harness.waitFor("results")
        await gate.open()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(harness.kinds == ["idle", "loading", "results"])
    }

    @Test func resumeRefreshesIdleOnlyWhenNoQueryIsOnScreen() async {
        let harness = Harness(handler: Self.serving(SearchFixtures.allHits))
        harness.session.resume()
        #expect(harness.kinds == ["idle"])

        harness.session.update(query: "halo", scope: .all)
        await harness.waitFor("results")
        let count = harness.states.count
        harness.session.resume()
        #expect(harness.states.count == count)
    }
}

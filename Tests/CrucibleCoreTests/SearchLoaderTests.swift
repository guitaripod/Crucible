import Foundation
import Testing
@testable import CrucibleCore

struct SearchLoaderTests {
    private struct Boom: Error {}

    private static func loader(
        log: RequestLog = RequestLog(),
        _ handler: @escaping @Sendable (PlexEndpoint) async throws -> PlexMediaContainer
    ) -> SearchLoader {
        SearchLoader { endpoint in
            await log.record(endpoint)
            return try await handler(endpoint)
        }
    }

    @Test func searchFlattensHubsThroughResults() async throws {
        let container = try SearchFixtures.searchContainer([
            [try SearchFixtures.item("1", "movie", "Alpha")],
            [try SearchFixtures.item("2", "show", "Beta"), try SearchFixtures.item("1", "movie", "Alpha")],
        ])
        let log = RequestLog()
        let results = try await Self.loader(log: log) { _ in container }.search(query: "al")
        #expect(results.ordered.map(\.id) == ["1", "2"])
        #expect(await log.searchQueries == ["al"])
    }

    @Test func searchPropagatesErrors() async {
        await #expect(throws: Boom.self) {
            _ = try await Self.loader { _ in throw Boom() }.search(query: "al")
        }
    }

    @Test func genresMergeAcrossSectionsCaseInsensitivelyInFirstSeenOrder() async throws {
        let sections = try SearchFixtures.directories([
            (key: "1", title: "Movies", type: "movie"),
            (key: "2", title: "Shows", type: "show"),
            (key: "3", title: "Music", type: "artist"),
        ])
        let movieGenres = try SearchFixtures.directories([
            (key: "10", title: "Drama", type: nil), (key: "11", title: "Comedy", type: nil),
        ])
        let showGenres = try SearchFixtures.directories([
            (key: "20", title: "drama", type: nil), (key: "21", title: "Mystery", type: nil),
        ])
        let log = RequestLog()
        let genres = await Self.loader(log: log) { endpoint in
            switch endpoint {
            case .sections: return sections
            case .sectionGenres(let sectionId): return sectionId == "1" ? movieGenres : showGenres
            default: throw Boom()
            }
        }.genres()

        #expect(genres.map(\.title) == ["Drama", "Comedy", "Mystery"])
        #expect(genres[0].sources == [GenreSource(sectionId: "1", key: "10"), GenreSource(sectionId: "2", key: "20")])
        #expect(genres[2].sources == [GenreSource(sectionId: "2", key: "21")])
        #expect(await log.count == 3)
    }

    @Test func genresAreCappedAtEight() async throws {
        let sections = try SearchFixtures.directories([(key: "1", title: "Movies", type: "movie")])
        let many = try SearchFixtures.directories((1...12).map { (key: "\($0)", title: "Genre \($0)", type: nil) })
        let genres = await Self.loader { endpoint in
            if case .sections = endpoint { return sections }
            return many
        }.genres()
        #expect(genres.count == SearchLoader.maxGenres)
        #expect(genres.map(\.title) == (1...8).map { "Genre \($0)" })
    }

    @Test func genresSkipSectionsThatFailAndEntriesWithoutKeyOrTitle() async throws {
        let sections = try SearchFixtures.directories([
            (key: "1", title: "Movies", type: "movie"), (key: "2", title: "Shows", type: "show"),
        ])
        let showGenres = try SearchFixtures.container(["Directory": [["key": "5"], ["title": "NoKey"], ["key": "6", "title": "Horror"]]])
        let genres = await Self.loader { endpoint in
            switch endpoint {
            case .sections: return sections
            case .sectionGenres(let sectionId):
                if sectionId == "1" { throw Boom() }
                return showGenres
            default: throw Boom()
            }
        }.genres()
        #expect(genres == [SearchGenre(title: "Horror", sources: [GenreSource(sectionId: "2", key: "6")])])
    }

    @Test func genresAreEmptyWhenSectionsFail() async {
        let genres = await Self.loader { _ in throw Boom() }.genres()
        #expect(genres.isEmpty)
    }

    @Test func recentlyAddedKeepsMediaTypesAndDedupes() async throws {
        let container = try SearchFixtures.page([
            try SearchFixtures.item("1", "movie", "A"), try SearchFixtures.item("2", "show", "B"),
            try SearchFixtures.item("3", "season", "C"), try SearchFixtures.item("4", "episode", "D"),
            try SearchFixtures.item("5", "artist", "E"), try SearchFixtures.item("1", "movie", "A again"),
            try SearchFixtures.item("6", "collection", "F"),
        ])
        let log = RequestLog()
        let items = await Self.loader(log: log) { _ in container }.recentlyAdded()
        #expect(items.map(\.id) == ["1", "2", "3", "4"])
        let endpoints = await log.endpoints
        guard case .recentlyAdded(let start, let size) = endpoints.first else {
            Issue.record("expected a recentlyAdded request")
            return
        }
        #expect(start == 0 && size == 30)
    }

    @Test func recentlyAddedIsEmptyOnFailure() async {
        let items = await Self.loader { _ in throw Boom() }.recentlyAdded()
        #expect(items.isEmpty)
    }

    private static func genre(_ sources: [(String, String)]) -> SearchGenre {
        SearchGenre(title: "Drama", sources: sources.map { GenreSource(sectionId: $0.0, key: $0.1) })
    }

    private static func items(_ range: ClosedRange<Int>, prefix: String = "") throws -> [PlexMetadata] {
        try range.map { try SearchFixtures.item("\(prefix)\($0)", "movie", "Title \(String(format: "%04d", $0))") }
    }

    @Test func itemsPageByHundredUntilAShortPage() async throws {
        let all = try Self.items(1...250)
        let log = RequestLog()
        let result = try await Self.loader(log: log) { endpoint in
            guard case .sectionItems(_, let sort, let genre, let start, let size, _, _) = endpoint else { throw Boom() }
            #expect(sort == "titleSort:asc" && genre == "5" && size == 100)
            return try SearchFixtures.page(Array(all[start..<min(start + size, all.count)]), total: all.count)
        }.items(genre: Self.genre([("1", "5")]))

        #expect(result.count == 250)
        #expect(await log.sectionItemStarts == [0, 100, 200])
    }

    @Test func itemsStopWhenTheStartReachesTheTotal() async throws {
        let all = try Self.items(1...200)
        let log = RequestLog()
        let result = try await Self.loader(log: log) { endpoint in
            guard case .sectionItems(_, _, _, let start, let size, _, _) = endpoint else { throw Boom() }
            return try SearchFixtures.page(Array(all[start..<min(start + size, all.count)]), total: 200)
        }.items(genre: Self.genre([("1", "5")]))

        #expect(result.count == 200)
        #expect(await log.sectionItemStarts == [0, 100])
    }

    @Test func itemsKeepPagingWhenTheServerReportsNoTotal() async throws {
        let all = try Self.items(1...200)
        let log = RequestLog()
        _ = try await Self.loader(log: log) { endpoint in
            guard case .sectionItems(_, _, _, let start, let size, _, _) = endpoint else { throw Boom() }
            return try SearchFixtures.page(Array(all[start..<min(start + size, all.count)]))
        }.items(genre: Self.genre([("1", "5")]))
        #expect(await log.sectionItemStarts == [0, 100, 200])
    }

    @Test func itemsAreCappedAtTwoThousandPerSource() async throws {
        let log = RequestLog()
        let result = try await Self.loader(log: log) { endpoint in
            guard case .sectionItems(_, _, _, let start, let size, _, _) = endpoint else { throw Boom() }
            return try SearchFixtures.page(try Self.items((start + 1)...(start + size)), total: 9000)
        }.items(genre: Self.genre([("1", "5")]))

        #expect(result.count == 2000)
        #expect(await log.sectionItemStarts.count == 20)
    }

    @Test func itemsMergeSourcesDedupeAndSortNaturally() async throws {
        let movies = [
            try SearchFixtures.item("1", "movie", "Zebra"),
            try SearchFixtures.item("2", "movie", "Item 10"),
            try SearchFixtures.item("3", "movie", "item 2"),
        ]
        let shows = [try SearchFixtures.item("2", "movie", "Item 10"), try SearchFixtures.item("4", "show", "Alpha")]
        let result = try await Self.loader { endpoint in
            guard case .sectionItems(let sectionId, _, _, _, _, _, _) = endpoint else { throw Boom() }
            return try SearchFixtures.page(sectionId == "1" ? movies : shows)
        }.items(genre: Self.genre([("1", "5"), ("2", "6")]))

        #expect(result.map(\.title) == ["Alpha", "item 2", "Item 10", "Zebra"])
    }

    @Test func itemsFailWhenAnySourceFails() async throws {
        await #expect(throws: Boom.self) {
            _ = try await Self.loader { endpoint in
                guard case .sectionItems(let sectionId, _, _, _, _, _, _) = endpoint else { throw Boom() }
                if sectionId == "2" { throw Boom() }
                return try SearchFixtures.page([])
            }.items(genre: Self.genre([("1", "5"), ("2", "6")]))
        }
    }

    @Test func itemsStopWhenCancelled() async throws {
        let log = RequestLog()
        let gate = Gate()
        let load = Self.loader(log: log) { _ in
            await gate.wait()
            return try SearchFixtures.page(try Self.items(1...100), total: 9000)
        }
        let target = Self.genre([("1", "5")])
        let task = Task { try await load.items(genre: target) }
        while !(await gate.hasWaiter) { try await Task.sleep(for: .milliseconds(2)) }
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await log.sectionItemStarts == [0])
    }
}

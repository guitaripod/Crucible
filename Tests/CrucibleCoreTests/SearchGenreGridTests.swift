import Foundation
import Testing
@testable import CrucibleCore

struct GenreMergePagerTests {
    private static let movies = GenreSource(sectionId: "1", key: "5")
    private static let shows = GenreSource(sectionId: "2", key: "6")

    private static func titles(_ names: [String], prefix: String = "") throws -> [PlexMetadata] {
        try names.map { try SearchFixtures.item("\(prefix)\($0)", "movie", $0) }
    }

    private static func numbered(_ range: ClosedRange<Int>, prefix: String) throws -> [PlexMetadata] {
        try range.map { try SearchFixtures.item("\(prefix)\($0)", "movie", "Title \(String(format: "%04d", $0))") }
    }

    @Test func aSingleShortPageReleasesEverythingAndEndsTheGenre() throws {
        var pager = GenreMergePager(sources: [Self.movies])
        #expect(pager.sourcesToFetch == [Self.movies])
        pager.apply(page: try Self.titles(["A", "B", "C"]), total: 3, start: 0, for: Self.movies)
        #expect(pager.release() == 3)
        #expect(pager.items.map(\.title) == ["A", "B", "C"])
        #expect(!pager.hasMore)
        #expect(pager.sourcesToFetch.isEmpty)
        #expect(pager.totalCount == 3)
    }

    @Test func aFullPageKeepsTheSectionOpenUntilTheTotalIsReached() throws {
        var pager = GenreMergePager(sources: [Self.movies])
        pager.apply(page: try Self.numbered(1...50, prefix: "m"), total: 120, start: 0, for: Self.movies)
        pager.release()
        #expect(pager.items.count == 50)
        #expect(pager.hasMore)
        #expect(pager.sourcesToFetch == [Self.movies])
        #expect(pager.nextStart(for: Self.movies) == 50)

        pager.apply(page: try Self.numbered(51...100, prefix: "m"), total: 120, start: 50, for: Self.movies)
        pager.release()
        #expect(pager.items.count == 100)
        #expect(pager.sourcesToFetch == [Self.movies])

        pager.apply(page: try Self.numbered(101...120, prefix: "m"), total: 120, start: 100, for: Self.movies)
        pager.release()
        #expect(pager.items.count == 120)
        #expect(!pager.hasMore)
    }

    @Test func aFullPageThatReachesTheTotalIsTheLast() throws {
        var pager = GenreMergePager(sources: [Self.movies])
        pager.apply(page: try Self.numbered(1...50, prefix: "m"), total: 50, start: 0, for: Self.movies)
        pager.release()
        #expect(!pager.hasMore)
    }

    @Test func sectionsAreMergedByTitleAndWaitForTheSlowerSection() throws {
        var pager = GenreMergePager(sources: [Self.movies, Self.shows])
        let movies = try Self.numbered(1...50, prefix: "m").enumerated().map { index, _ in
            try SearchFixtures.item("m\(index)", "movie", String(format: "M%03d", index * 2))
        }
        let shows = try (0..<50).map { try SearchFixtures.item("s\($0)", "show", String(format: "M%03d", $0 * 2 + 1)) }
        pager.apply(page: movies, total: 200, start: 0, for: Self.movies)
        #expect(pager.release() == 0)
        pager.apply(page: shows, total: 200, start: 0, for: Self.shows)
        pager.release()

        #expect(pager.items.count == 99)
        #expect(pager.items.map(\.title) == (0..<99).map { String(format: "M%03d", $0) })
        #expect(pager.sourcesToFetch == [Self.movies])
        #expect(pager.totalCount == 400)
    }

    @Test func duplicatesAcrossSectionsKeepTheirFirstPosition() throws {
        var pager = GenreMergePager(sources: [Self.movies, Self.shows])
        pager.apply(page: try Self.titles(["A", "B"]), total: 2, start: 0, for: Self.movies)
        pager.apply(page: [try SearchFixtures.item("A", "movie", "A"), try SearchFixtures.item("C", "show", "C")], total: 2, start: 0, for: Self.shows)
        pager.release()
        #expect(pager.items.map(\.id) == ["A", "B", "C"])
    }

    @Test func titlesSortNaturally() throws {
        var pager = GenreMergePager(sources: [Self.movies, Self.shows])
        pager.apply(page: try Self.titles(["item 2", "Zebra"]), total: 2, start: 0, for: Self.movies)
        pager.apply(page: try Self.titles(["Item 10"], prefix: "s"), total: 1, start: 0, for: Self.shows)
        pager.release()
        #expect(pager.items.map(\.title) == ["item 2", "Item 10", "Zebra"])
    }

    @Test func aPageForTheWrongOffsetIsIgnored() throws {
        var pager = GenreMergePager(sources: [Self.movies])
        pager.apply(page: try Self.titles(["A"]), total: 1, start: 50, for: Self.movies)
        #expect(pager.release() == 0)
        #expect(pager.sourcesToFetch == [Self.movies])
    }

    @Test func nextPageIsDueNearTheEndOnly() throws {
        var pager = GenreMergePager(sources: [Self.movies])
        pager.apply(page: try Self.numbered(1...50, prefix: "m"), total: 200, start: 0, for: Self.movies)
        pager.release()
        #expect(!pager.shouldLoadNextPage(near: 10, isLoading: false))
        #expect(pager.shouldLoadNextPage(near: 40, isLoading: false))
        #expect(!pager.shouldLoadNextPage(near: 49, isLoading: true))
    }
}

@MainActor
struct GenreGridModelTests {
    private static let movies = GenreSource(sectionId: "1", key: "5")
    private static let genre = SearchGenre(title: "Drama", sources: [movies])

    private final class Recorder {
        private(set) var updates: [GenreGridModel.Update] = []

        func record(_ update: GenreGridModel.Update) {
            updates.append(update)
        }
    }

    private static func model(
        log: SearchRequestLog = SearchRequestLog(),
        _ handler: @escaping @Sendable (Int) async throws -> PlexMediaContainer
    ) -> (GenreGridModel, Recorder) {
        let loader = SearchLoader { endpoint in
            await log.record(endpoint)
            guard case .sectionItems(_, _, _, let start, _, _, _) = endpoint else { throw URLError(.badURL) }
            return try await handler(start)
        }
        let model = GenreGridModel(genre: genre, loader: loader)
        let recorder = Recorder()
        model.onUpdate = { recorder.record($0) }
        return (model, recorder)
    }

    private nonisolated static func page(_ range: ClosedRange<Int>, total: Int) throws -> PlexMediaContainer {
        try SearchFixtures.page(try range.map { try SearchFixtures.item("m\($0)", "movie", "Title \(String(format: "%04d", $0))") }, total: total)
    }

    @Test func theFirstPagePaintsTheGridWithoutReadingTheRest() async throws {
        let log = SearchRequestLog()
        let (model, _) = Self.model(log: log) { start in try Self.page((start + 1)...(start + 50), total: 500) }
        model.appear()
        #expect(model.contentState == .loading)
        await searchWaitUntil { model.contentState == .content }

        #expect(model.items.count == 50)
        #expect(await log.sectionItemStarts == [0])
        #expect(model.pager.totalCount == 500)
    }

    @Test func focusNearTheEndReadsTheNextPageOnce() async throws {
        let log = SearchRequestLog()
        let (model, _) = Self.model(log: log) { start in try Self.page((start + 1)...(start + 50), total: 500) }
        model.appear()
        await searchWaitUntil { model.contentState == .content }

        model.itemFocused(at: 5)
        model.itemFocused(at: 45)
        model.itemFocused(at: 46)
        await searchWaitUntil { model.items.count == 100 }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.items.count == 100)
        #expect(await log.sectionItemStarts == [0, 50])
    }

    @Test func aGenreSmallerThanOnePageIsDoneAtOnce() async throws {
        let (model, _) = Self.model { _ in try Self.page(1...7, total: 7) }
        model.appear()
        await searchWaitUntil { model.contentState == .content }
        model.itemFocused(at: 3)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.items.count == 7)
    }

    @Test func noTitlesIsEmpty() async throws {
        let (model, _) = Self.model { _ in try SearchFixtures.page([], total: 0) }
        model.appear()
        await searchWaitUntil { model.contentState == .empty }
        #expect(model.items.isEmpty)
    }

    @Test func aFailedFirstPageIsFailedAndAppearAgainRecovers() async throws {
        let attempts = SearchRequestLog()
        let (model, _) = Self.model(log: attempts) { start in
            if await attempts.count == 1 { throw URLError(.notConnectedToInternet) }
            return try Self.page((start + 1)...(start + 3), total: 3)
        }
        model.appear()
        await searchWaitUntil { if case .failed = model.contentState { return true } else { return false } }
        model.appear()
        #expect(model.contentState == .loading)
        await searchWaitUntil { model.contentState == .content }
        #expect(model.items.count == 3)
    }

    @Test func aFailedLaterPageKeepsTheGridAndRetriesOnTheNextFocus() async throws {
        let attempts = SearchRequestLog()
        let (model, recorder) = Self.model(log: attempts) { start in
            if start == 50, await attempts.count == 2 { throw URLError(.timedOut) }
            return try Self.page((start + 1)...(start + 50), total: 500)
        }
        model.appear()
        await searchWaitUntil { model.contentState == .content }
        model.itemFocused(at: 45)
        await searchWaitUntil { recorder.updates.contains { if case .pageFailed = $0 { return true } else { return false } } }
        #expect(model.items.count == 50)
        #expect(model.contentState == .content)

        model.itemFocused(at: 46)
        await searchWaitUntil { model.items.count == 100 }
        #expect(model.items.count == 100)
    }

    @Test func aCancelledReadIsIgnoredAndLeavesTheScreenReadyToStartAgain() async throws {
        let gate = SearchGate()
        let (model, _) = Self.model { start in
            await gate.wait()
            return try Self.page((start + 1)...(start + 3), total: 3)
        }
        model.appear()
        while !(await gate.hasWaiter) { try? await Task.sleep(for: .milliseconds(2)) }
        model.disappear()
        await gate.open()
        try? await Task.sleep(for: .milliseconds(60))
        #expect(model.contentState == .loading)
        #expect(model.items.isEmpty)

        model.appear()
        await searchWaitUntil { model.contentState == .content }
        #expect(model.items.count == 3)
    }
}

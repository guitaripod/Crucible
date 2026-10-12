@testable import CrucibleCore
import Foundation
import Testing
@testable import CrucibleDemo

struct DemoWatchTests {
    private func allHistory(_ demo: DemoHarness, query: String = "") async throws -> [PlexHistoryEntry] {
        var rows = [PlexHistoryEntry]()
        var start = 0
        while true {
            let page: PlexHistoryResponse = try await demo.api.request(.history(start: start, size: 100))
            let batch = page.MediaContainer.Metadata ?? []
            rows += batch
            start += batch.count
            if batch.count < 100 || start >= (page.MediaContainer.totalSize ?? 0) { return rows }
        }
    }

    @Test func historyHoldsAYearOfBelievableViewing() async throws {
        try await withDemo { demo in
            let rows = try await allHistory(demo)
            #expect(rows.count >= 300)
            let times = rows.compactMap(\.viewedAt)
            #expect(times == times.sorted(by: >))
            let now = Int(Date().timeIntervalSince1970)
            #expect((times.first ?? 0) > now - 6 * 3600)
            #expect((times.last ?? now) < now - 300 * 86400)
            #expect((times.last ?? 0) >= now - 366 * 86400)
            #expect(times.allSatisfy { $0 <= now })
            let calendar = Calendar.current
            let days = Set(times.map { calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0))) })
            #expect(days.count >= 120)
            #expect(Set(rows.compactMap(\.librarySectionID)).isSuperset(of: [1, 2, 3]))
            let shows = Dictionary(grouping: rows.compactMap(\.grandparentTitle), by: { $0 }).mapValues(\.count)
            #expect(shows.count >= 6)
            #expect(shows["The Salt Road"] ?? 0 > shows["Halftide"] ?? 0)
            let busiest = Dictionary(grouping: times) { calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0))) }.values.map(\.count).max() ?? 0
            #expect(busiest >= 10)
            #expect(rows.allSatisfy { $0.ratingKey?.isEmpty == false && $0.thumb?.isEmpty == false })
            let episode = try #require(rows.first { $0.type == "episode" })
            #expect(episode.grandparentRatingKey != nil && episode.parentIndex != nil && episode.index != nil)
        }
    }

    @Test func historyIsTheSameEveryTimeItIsBuiltForADay() async throws {
        let first = try await DemoHarness.start()
        let second = try await DemoHarness.start()
        let a: PlexHistoryResponse = try await first.api.request(.history(start: 0, size: 500))
        let b: PlexHistoryResponse = try await second.api.request(.history(start: 0, size: 500))
        let older = (a.MediaContainer.Metadata ?? []).dropFirst(5).map { "\($0.ratingKey ?? "")@\($0.viewedAt ?? 0)" }
        let other = (b.MediaContainer.Metadata ?? []).dropFirst(5).map { "\($0.ratingKey ?? "")@\($0.viewedAt ?? 0)" }
        #expect(older == other)
        await first.stop()
        await second.stop()
    }

    @Test func historyFiltersByLibraryAndSortsEitherWay() async throws {
        try await withDemo { demo in
            let section: PlexHistoryResponse = try await demo.api.request(.sectionHistory(sectionId: "3", size: 100))
            let docs = section.MediaContainer.Metadata ?? []
            #expect(!docs.isEmpty)
            #expect(docs.allSatisfy { $0.librarySectionID == 3 })
            let ascending: PlexHistoryResponse = try await demo.api.request(.history(start: 0, size: 30, sort: "viewedAt:asc"))
            let times = (ascending.MediaContainer.Metadata ?? []).compactMap(\.viewedAt)
            #expect(times == times.sorted())
            let headline = try #require(await YouHistoryHeadline.latest(api: demo.api))
            #expect(headline.contains("Halcyon"))
        }
    }

    @Test func scrobbleMakesTheItemWatchedAndAddsAHistoryRow() async throws {
        try await withDemo { demo in
            #expect(try await demo.metadata("1008").isWatched == false)
            try await demo.api.requestConfirmed(.scrobble(ratingKey: "1008"))
            await demo.api.invalidateCache()
            let watched = try await demo.metadata("1008")
            #expect(watched.isWatched)
            #expect(watched.viewOffset == nil)
            let latest: PlexHistoryResponse = try await demo.api.request(.history(start: 0, size: 1))
            #expect(latest.MediaContainer.Metadata?.first?.ratingKey == "1008")
            let unwatched = try await demo.api.requestContainer(.sectionItems(sectionId: "1", size: 100, unwatched: true)).Metadata ?? []
            #expect(!unwatched.contains { $0.id == "1008" })
            try await demo.api.requestConfirmed(.unscrobble(ratingKey: "1008"))
            #expect(try await demo.metadata("1008").isWatched == false)
        }
    }

    @Test func scrobblingAShowOrSeasonRecountsItsEpisodes() async throws {
        try await withDemo { demo in
            try await demo.api.requestConfirmed(.scrobble(ratingKey: "2009"))
            await demo.api.invalidateCache()
            let show = try await demo.metadata("2009")
            #expect(show.isWatched)
            #expect(show.viewedLeafCount == show.leafCount)
            try await demo.api.requestConfirmed(.unscrobble(ratingKey: "3003"))
            await demo.api.invalidateCache()
            let season = try await demo.api.requestContainer(.children(ratingKey: "2001")).Metadata?.first { $0.id == "3003" }
            #expect(season?.isWatched == false)
        }
    }

    @Test func timelineAndProgressUpdateTheResumePosition() async throws {
        try await withDemo { demo in
            try await demo.api.requestVoid(.timeline(ratingKey: "1011", state: "playing", timeMs: 600_000, durationMs: 8_280_000))
            let playing = try await demo.metadata("1011")
            #expect(playing.viewOffset == 600_000)
            #expect(playing.isWatched == false)
            let hubs = try await demo.api.requestContainer(.hubs()).Hub ?? []
            let continuing = hubs.first { $0.hubIdentifier == "home.continue" }?.Metadata ?? []
            #expect(continuing.first?.id == "1011")

            try await demo.api.requestVoid(.progress(ratingKey: "1011", timeMs: 900_000))
            #expect(try await demo.metadata("1011").viewOffset == 900_000)
        }
    }

    @Test func stoppingAtTheEndOfTheClipOrTheTitleFinishesIt() async throws {
        try await withDemo { demo in
            try await demo.api.requestVoid(.timeline(ratingKey: "1011", state: "stopped", timeMs: 29_500, durationMs: 8_280_000))
            let finishedClip = try await demo.metadata("1011")
            #expect(finishedClip.isWatched && finishedClip.viewOffset == nil)

            try await demo.api.requestVoid(.timeline(ratingKey: "1002", state: "stopped", timeMs: 7_000_000, durationMs: 7_500_000))
            #expect(try await demo.metadata("1002").isWatched)

            try await demo.api.requestVoid(.timeline(ratingKey: "4001", state: "stopped", timeMs: 12_000, durationMs: 2_760_000))
            let early = try await demo.metadata("4001")
            #expect(early.viewOffset == nil || early.viewOffset == 12_000 || early.isWatched)
        }
    }

    @Test func finishingAnEpisodeMovesOnDeckToTheNextOne() async throws {
        try await withDemo { demo in
            let deckBefore = try await demo.api.requestContainer(.onDeck).Metadata ?? []
            let northbound = try #require(deckBefore.first { $0.grandparentTitle == "Northbound" })
            try await demo.api.requestConfirmed(.scrobble(ratingKey: northbound.id))
            let deckAfter = try await demo.api.requestContainer(.onDeck).Metadata ?? []
            let next = try #require(deckAfter.first { $0.grandparentTitle == "Northbound" })
            #expect(next.id != northbound.id)
            #expect(next.index == (northbound.index ?? 0) + 1)
        }
    }

    @Test func theStateFileSurvivesARestart() async throws {
        let file = DemoHarness.temporaryStateFile()
        try await withDemo(stateFile: file) { demo in
            try await demo.api.requestConfirmed(.scrobble(ratingKey: "1008"))
            try await demo.api.requestVoid(.timeline(ratingKey: "1011", state: "paused", timeMs: 777_000, durationMs: 8_280_000))
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        try await withDemo(stateFile: file) { demo in
            let watched = try await demo.metadata("1008")
            #expect(watched.isWatched)
            #expect(try await demo.metadata("1011").viewOffset == 777_000)
            let latest: PlexHistoryResponse = try await demo.api.request(.history(start: 0, size: 1))
            #expect(latest.MediaContainer.Metadata?.first?.ratingKey == "1008")
            let hubs = try await demo.api.requestContainer(.hubs()).Hub ?? []
            #expect(hubs.first { $0.hubIdentifier == "home.continue" }?.Metadata?.first?.id == "1011")
        }
    }

    @Test func aDamagedStateFileIsIgnored() async throws {
        let file = DemoHarness.temporaryStateFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        try await withDemo(stateFile: file) { demo in
            let movie = try await demo.metadata("1001")
            #expect(movie.title == "Halcyon")
        }
    }
}

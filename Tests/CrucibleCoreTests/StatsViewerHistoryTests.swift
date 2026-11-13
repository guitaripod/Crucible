import Foundation
import GRDB
import Testing
@testable import CrucibleCore
@testable import CrucibleStats

struct StatsViewerHistoryTests {
    private typealias F = StatsFixtures

    private func makeStore() throws -> (StatsStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("viewer-history-tests-\(UUID().uuidString)", isDirectory: true)
        let url = folder.appendingPathComponent("Stats", isDirectory: true).appendingPathComponent("stats.sqlite")
        return (StatsStore(database: try StatsDatabase(url: url)), folder)
    }

    private func play(_ ratingKey: String, type: String, show: String? = nil, at date: Date, account: Int? = nil) -> Play {
        let viewedAt = F.unix(date)
        let components = F.time.components(forViewedAt: viewedAt)
        return Play(
            id: nil, ratingKey: ratingKey, type: type, title: ratingKey, grandparentTitle: show, grandparentRatingKey: show,
            grandparentThumb: nil, thumb: nil, parentIndex: nil, idx: nil, viewedAt: viewedAt, dayEpoch: components.dayEpoch,
            hourLocal: components.hourLocal, weekday: components.weekday, monthEpoch: components.monthEpoch,
            monthDay: components.monthDay, year: components.year, librarySectionID: nil, librarySectionTitle: nil,
            accountID: account, deviceID: nil
        )
    }

    private func mark(_ store: StatsStore, complete: Bool, lowWater: Date?) async throws {
        var state = try await store.syncState()
        state.historyComplete = complete
        state.lowWaterViewedAt = lowWater.map(F.unix)
        try await store.saveSyncState(state)
    }

    private func history(_ store: StatsStore) async throws -> ProViewerFacts.History? {
        try await store.viewerHistory(now: F.now, time: F.time)
    }

    @Test func aMirrorThatWasNeverSyncedSaysNothing() async throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try await history(store) == nil)
        _ = try await store.syncState()
        #expect(try await history(store) == nil)
    }

    @Test func aBackfillThatHasNotReachedJanuarySaysNothing() async throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await store.insertPlays([play("m1", type: "movie", at: F.date(2026, 6, 1)), play("m2", type: "movie", at: F.date(2026, 5, 1))])
        try await mark(store, complete: false, lowWater: F.date(2026, 5, 1))
        #expect(try await history(store) == nil)
    }

    @Test func aBackfillPastJanuaryKnowsTheYearButNotTheWholeHistory() async throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await store.insertPlays([
            play("m1", type: "movie", at: F.date(2026, 6, 1)),
            play("e1", type: "episode", show: "s1", at: F.date(2026, 2, 1)),
            play("e2", type: "episode", show: "s1", at: F.date(2025, 12, 20)),
        ])
        try await mark(store, complete: false, lowWater: F.date(2025, 12, 20))
        let found = try await history(store)
        #expect(found?.year == 2026)
        #expect(found?.playsThisYear == 2)
        #expect(found?.moviesThisYear == 1)
        #expect(found?.episodesThisYear == 1)
        #expect(found?.playsAllTime == nil)
        #expect(found?.firstYear == nil)
    }

    @Test func aFinishedBackfillCountsEveryPlayAndTheYearItBegan() async throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await store.insertPlays([
            play("m1", type: "movie", at: F.date(2026, 6, 1)),
            play("m1", type: "movie", at: F.date(2026, 3, 1)),
            play("e1", type: "episode", show: "s1", at: F.date(2026, 2, 1)),
            play("e2", type: "episode", show: "s1", at: F.date(2024, 7, 4)),
            play("m2", type: "movie", at: F.date(2019, 11, 2)),
        ])
        try await mark(store, complete: true, lowWater: F.date(2019, 11, 2))
        let found = try await history(store)
        #expect(found?.playsThisYear == 3)
        #expect(found?.moviesThisYear == 1)
        #expect(found?.episodesThisYear == 1)
        #expect(found?.playsAllTime == 5)
        #expect(found?.firstYear == 2019)
        #expect(found?.hoursThisYear == nil)
    }

    @Test func hoursComeFromKnownRuntimesOnceEnoughAreKnown() async throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await store.insertPlays([
            play("m1", type: "movie", at: F.date(2026, 6, 1)),
            play("m2", type: "movie", at: F.date(2026, 3, 1)),
        ])
        try await store.saveItemMeta(ItemMeta(ratingKey: "m1", durationMs: 7_200_000, year: 2001, enrichedAt: 0), genres: [])
        try await store.saveItemMeta(ItemMeta(ratingKey: "m2", durationMs: 5_400_000, year: 2002, enrichedAt: 0), genres: [])
        try await mark(store, complete: true, lowWater: F.date(2026, 3, 1))
        #expect(try await history(store)?.hoursThisYear == 4)
    }

    @Test func aQuietYearStillKnowsTheWholeHistory() async throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await store.insertPlays([play("m1", type: "movie", at: F.date(2023, 6, 1)), play("m2", type: "movie", at: F.date(2022, 6, 1))])
        try await mark(store, complete: true, lowWater: F.date(2022, 6, 1))
        let found = try await history(store)
        #expect(found?.playsThisYear == 0)
        #expect(found?.playsAllTime == 2)
        #expect(found?.firstYear == 2022)
    }

    @Test func anEmptyFinishedMirrorSaysNothing() async throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await mark(store, complete: true, lowWater: nil)
        #expect(try await history(store) == nil)
    }

    @Test func onASharedServerOnlyTheOwnersPlaysCount() async throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await store.insertPlays([
            play("m1", type: "movie", at: F.date(2026, 6, 1), account: 1),
            play("m2", type: "movie", at: F.date(2026, 5, 1), account: 2),
            play("m3", type: "movie", at: F.date(2021, 5, 1), account: 2),
            play("m4", type: "movie", at: F.date(2022, 5, 1), account: 1),
        ])
        try await mark(store, complete: true, lowWater: F.date(2021, 5, 1))
        let found = try await history(store)
        #expect(found?.playsThisYear == 1)
        #expect(found?.playsAllTime == 2)
        #expect(found?.firstYear == 2022)
    }
}

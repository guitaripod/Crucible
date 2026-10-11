import Foundation
import Testing
@testable import CrucibleStats

struct StatsDatabaseTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("stats-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Stats", isDirectory: true)
            .appendingPathComponent("stats.sqlite")
    }

    private func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent())
    }

    private func play(_ ratingKey: String, type: String = "movie", title: String = "Heat", show: String? = nil, viewedAt: Int) -> Play {
        let components = StatsTime().components(forViewedAt: viewedAt)
        return Play(
            id: nil,
            ratingKey: ratingKey,
            type: type,
            title: title,
            grandparentTitle: show,
            grandparentRatingKey: show.map { _ in "show-\(ratingKey)" },
            grandparentThumb: nil,
            thumb: "/thumb/\(ratingKey)",
            parentIndex: nil,
            idx: nil,
            viewedAt: viewedAt,
            dayEpoch: components.dayEpoch,
            hourLocal: components.hourLocal,
            weekday: components.weekday,
            monthEpoch: components.monthEpoch,
            monthDay: components.monthDay,
            year: components.year,
            librarySectionID: nil,
            librarySectionTitle: nil,
            accountID: nil,
            deviceID: nil
        )
    }

    private func finishBackfill(_ store: StatsStore) async throws {
        var state = try await store.syncState()
        state.historyComplete = true
        state.highWaterViewedAt = 1_700_000_000
        state.lowWaterViewedAt = 1_600_000_000
        state.backfillOffset = 0
        state.totalRows = try await store.totalRows()
        try await store.saveSyncState(state)
    }

    @Test func aFreshMirrorStartsAnUnfinishedBackfillAtTheFirstPage() async throws {
        let url = temporaryURL()
        defer { cleanUp(url) }
        let store = StatsStore(database: try StatsDatabase(url: url))
        let state = try await store.syncState()
        #expect(!state.historyComplete)
        #expect(state.backfillOffset == 0)
        #expect(state.highWaterViewedAt == nil)
        #expect(state.totalRows == 0)
    }

    @Test func syncStateSurvivesReopeningTheFile() async throws {
        let url = temporaryURL()
        defer { cleanUp(url) }
        let first = StatsStore(database: try StatsDatabase(url: url))
        try await first.insertPlays([play("a", viewedAt: 1_700_000_000)])
        var state = try await first.syncState()
        state.backfillOffset = 300
        try await first.saveSyncState(state)

        let reopened = StatsStore(database: try StatsDatabase(url: url))
        let restored = try await reopened.syncState()
        #expect(restored.backfillOffset == 300)
        #expect(!restored.historyComplete)
        #expect(try await reopened.totalRows() == 1)
    }

    @Test func aPurgedMirrorRestartsTheBackfillFromScratch() async throws {
        let url = temporaryURL()
        defer { cleanUp(url) }
        let store = StatsStore(database: try StatsDatabase(url: url))
        try await store.insertPlays([play("a", viewedAt: 1_700_000_000), play("b", viewedAt: 1_700_000_100)])
        try await finishBackfill(store)
        #expect(try await store.syncState().historyComplete)

        StatsDatabase.destroy(at: url)

        let rebuilt = StatsStore(database: try StatsDatabase.openOrRebuild(at: url))
        let state = try await rebuilt.syncState()
        #expect(!state.historyComplete)
        #expect(state.backfillOffset == 0)
        #expect(state.highWaterViewedAt == nil)
        #expect(state.lowWaterViewedAt == nil)
        #expect(try await rebuilt.totalRows() == 0)
    }

    @Test func aTruncatedFileIsReplacedByAFreshMirror() async throws {
        let url = temporaryURL()
        defer { cleanUp(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is not a database, a purge cut it short".utf8).write(to: url)

        #expect(throws: (any Error).self) { try StatsDatabase(url: url) }

        let store = StatsStore(database: try StatsDatabase.openOrRebuild(at: url))
        let state = try await store.syncState()
        #expect(!state.historyComplete)
        #expect(try await store.totalRows() == 0)
    }

    @Test func aFileThatCannotBeOpenedIsKeptNotRebuilt() async throws {
        let url = temporaryURL()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            cleanUp(url)
        }
        let store = StatsStore(database: try StatsDatabase(url: url))
        try await store.insertPlays([play("a", viewedAt: 1_700_000_000)])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        #expect(throws: (any Error).self) { try StatsDatabase.openOrRebuild(at: url) }

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let reopened = StatsStore(database: try StatsDatabase(url: url))
        #expect(try await reopened.totalRows() == 1)
    }

    @Test func openingAHealthyMirrorKeepsItsRows() async throws {
        let url = temporaryURL()
        defer { cleanUp(url) }
        let store = StatsStore(database: try StatsDatabase(url: url))
        try await store.insertPlays([play("a", viewedAt: 1_700_000_000)])

        let again = StatsStore(database: try StatsDatabase.openOrRebuild(at: url))
        #expect(try await again.totalRows() == 1)
    }

    @Test func replayedPagesDoNotDuplicatePlays() async throws {
        let url = temporaryURL()
        defer { cleanUp(url) }
        let store = StatsStore(database: try StatsDatabase(url: url))
        let page = [play("a", viewedAt: 1_700_000_000), play("b", viewedAt: 1_700_000_100)]
        try await store.insertPlays(page)
        try await store.insertPlays(page)
        #expect(try await store.totalRows() == 2)
    }

    @Test func theLoaderBuildsAPageFromTheMirror() async throws {
        let url = temporaryURL()
        defer { cleanUp(url) }
        let store = StatsStore(database: try StatsDatabase(url: url))
        let now = Int(Date().timeIntervalSince1970)
        try await store.insertPlays([
            play("a", viewedAt: now - 3_600),
            play("b", viewedAt: now - 7_200),
            play("e1", type: "episode", title: "Pilot", show: "Severance", viewedAt: now - 10_800),
        ])

        let page = try await StatsPageLoader(store: store).load(range: .allTime)
        #expect(!page.isEmpty)
        #expect(page.snapshot.overview.totalPlays == 3)
        #expect(page.sections.first == .hero)
        #expect(page.sections.contains(.topMovies))
    }

    @Test func anEmptyMirrorLoadsAnEmptyPage() async throws {
        let url = temporaryURL()
        defer { cleanUp(url) }
        let store = StatsStore(database: try StatsDatabase(url: url))
        let page = try await StatsPageLoader(store: store).load(range: .year)
        #expect(page.isEmpty)
        #expect(page.sections.isEmpty)
    }

    @Test func theDayDrillDownListsEachTitleOnce() async throws {
        let url = temporaryURL()
        defer { cleanUp(url) }
        let store = StatsStore(database: try StatsDatabase(url: url))
        let noon = Int(StatsFixtures.date(2026, 6, 15).timeIntervalSince1970)
        try await store.insertPlays([
            play("a", viewedAt: noon),
            play("a", viewedAt: noon + 600),
            play("e1", type: "episode", title: "Pilot", show: "Severance", viewedAt: noon + 1_200),
        ])
        let dayEpoch = StatsTime().components(forViewedAt: noon).dayEpoch

        let posters = try await StatsPageLoader(store: store).playedOnDay(dayEpoch)
        #expect(posters.count == 2)
        #expect(Set(posters.map(\.title)) == ["Heat", "Severance"])
    }
}

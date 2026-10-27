import Foundation
import Testing
@testable import CrucibleCore

@MainActor
struct HomeFeedTests {
    private typealias F = HomeFixtures

    private struct Offline: Error {}

    private final class Harness: @unchecked Sendable {
        var hubs: Result<PlexMediaContainer, Error> = .success(F.hubsContainer([]))
        var recent: Result<PlexMediaContainer, Error> = .success(F.metadataContainer([]))
        var stored: HomeSnapshot?
        var saved: [HomeSnapshot] = []
        var machineID: String? = "machine-1"
        var excluded: Set<Int> = []
        var now = Date(timeIntervalSince1970: 1_000)

        @MainActor func makeFeed() -> HomeFeed {
            HomeFeed(environment: HomeFeed.Environment(
                fetchHubs: { [self] in try self.hubs.get() },
                fetchRecentlyAdded: { [self] in try self.recent.get() },
                loadSnapshot: { [self] in stored },
                saveSnapshot: { [self] in saved.append($0) },
                machineIdentifier: { [self] in machineID },
                excludedLibraries: { [self] in excluded },
                now: { [self] in now }
            ))
        }
    }

    private func standardHubs() -> PlexMediaContainer {
        F.hubsContainer([
            F.hub("home.continue", [
                F.raw("1", fields: ["duration": 2_400_000, "viewOffset": 60_000]),
                F.raw("2", fields: ["duration": 2_400_000, "viewOffset": 120_000]),
            ]),
            F.hub("home.ondeck", [F.raw("2"), F.raw("3")]),
            F.hub("home.recent", [F.raw("4"), F.raw("4"), F.raw("5")]),
        ])
    }

    private func snapshot(machine: String = "machine-1", schema: Int = HomeSnapshotStore.schemaVersion, keys: [String] = ["1"]) -> HomeSnapshot {
        HomeSnapshot(
            schema: schema,
            machineIdentifier: machine,
            savedAt: 1,
            cards: keys.map { key in
                var card = F.item(key, fields: ["duration": 2_400_000, "viewOffset": 60_000]).homeCard(bucket: "cw")
                card.art = "/art/\(key)"
                return card
            }
        )
    }

    @Test func refreshArrangesDedupesAndSavesTheSnapshot() async throws {
        let harness = Harness()
        harness.hubs = .success(standardHubs())
        let feed = harness.makeFeed()
        try await feed.refresh()

        #expect(feed.arrangement.hero?.id == "1")
        #expect(feed.arrangement.continueRail.map(\.id) == ["2"])
        #expect(feed.arrangement.upNext.map(\.id) == ["3"])
        #expect(feed.arrangement.recent.map(\.id) == ["4", "5"])
        #expect(feed.item(id: "5")?.id == "5")
        #expect(feed.item(id: "99") == nil)

        let saved = try #require(harness.saved.last)
        #expect(saved.machineIdentifier == "machine-1")
        #expect(saved.schema == HomeSnapshotStore.schemaVersion)
        #expect(saved.savedAt == 1_000)
        #expect(saved.cards.map(\.bucket) == ["cw", "cw", "od", "od", "ra", "ra"])
    }

    @Test func snapshotWithoutAMachineIdentifierIsSavedWithAnEmptyOne() async throws {
        let harness = Harness()
        harness.machineID = nil
        harness.hubs = .success(standardHubs())
        try await harness.makeFeed().refresh()
        #expect(harness.saved.last?.machineIdentifier == "")
    }

    @Test func failedRefreshKeepsHydratedContentAndThrows() async {
        let harness = Harness()
        harness.stored = snapshot(keys: ["1", "2"])
        let feed = harness.makeFeed()
        #expect(feed.hydrateFromSnapshot())
        harness.hubs = .failure(Offline())

        await #expect(throws: Offline.self) { try await feed.refresh() }
        #expect(feed.arrangement.hero?.id == "1")
        #expect(!feed.isEmpty)
        #expect(harness.saved.isEmpty)
    }

    @Test func failedRefreshOnAnEmptyFeedLeavesItEmpty() async {
        let harness = Harness()
        harness.hubs = .failure(Offline())
        let feed = harness.makeFeed()
        await #expect(throws: Offline.self) { try await feed.refresh() }
        #expect(feed.isEmpty)
    }

    @Test func hydrationRequiresMatchingMachineAndCards() {
        let harness = Harness()
        harness.stored = snapshot(machine: "other")
        #expect(!harness.makeFeed().hydrateFromSnapshot())

        harness.stored = snapshot(keys: [])
        #expect(!harness.makeFeed().hydrateFromSnapshot())

        harness.stored = nil
        #expect(!harness.makeFeed().hydrateFromSnapshot())

        harness.stored = snapshot()
        harness.machineID = nil
        #expect(!harness.makeFeed().hydrateFromSnapshot())
    }

    @Test func hydrationFillsContentAndKeepsSnapshotArtAfterRefresh() async throws {
        let harness = Harness()
        harness.stored = snapshot(keys: ["1", "2"])
        let feed = harness.makeFeed()
        #expect(feed.hydrateFromSnapshot())
        #expect(feed.arrangement.hero?.id == "1")
        #expect(feed.cachedArt == ["1": "/art/1", "2": "/art/2"])

        harness.hubs = .success(standardHubs())
        try await feed.refresh()
        #expect(feed.cachedArt["1"] == "/art/1")
        #expect(feed.arrangement.upNext.map(\.id) == ["3"])
    }

    @Test func libraryVisibilityReappliesToTheLastFetchedContent() async throws {
        let harness = Harness()
        harness.hubs = .success(F.hubsContainer([
            F.hub("home.continue", [F.raw("1", fields: ["librarySectionID": 1])]),
            F.hub("home.recent", [F.raw("2", fields: ["librarySectionID": 2]), F.raw("3", fields: ["librarySectionID": 1])]),
        ]))
        let feed = harness.makeFeed()
        try await feed.refresh()
        #expect(feed.arrangement.recent.map(\.id) == ["2", "3"])

        harness.excluded = [2]
        feed.reapplyLibraryVisibility()
        #expect(feed.arrangement.recent.map(\.id) == ["3"])
        #expect(feed.item(id: "2") == nil)

        harness.excluded = []
        feed.reapplyLibraryVisibility()
        #expect(feed.arrangement.recent.map(\.id) == ["2", "3"])
    }

    @Test func excludingEveryLibraryEmptiesTheFeed() async throws {
        let harness = Harness()
        harness.excluded = [1]
        harness.hubs = .success(F.hubsContainer([F.hub("home.continue", [F.raw("1", fields: ["librarySectionID": 1])])]))
        let feed = harness.makeFeed()
        try await feed.refresh()
        #expect(feed.isEmpty)
    }

    @Test func savedSnapshotOnlyHoldsVisibleItems() async throws {
        let harness = Harness()
        harness.excluded = [2]
        harness.hubs = .success(F.hubsContainer([
            F.hub("home.recent", [F.raw("1", fields: ["librarySectionID": 1]), F.raw("2", fields: ["librarySectionID": 2])]),
        ]))
        try await harness.makeFeed().refresh()
        #expect(harness.saved.last?.cards.map(\.ratingKey) == ["1"])
    }

    @Test func cancelledRefreshAppliesNothing() async {
        let harness = Harness()
        harness.hubs = .success(standardHubs())
        let feed = harness.makeFeed()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await feed.refresh()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(feed.isEmpty)
        #expect(harness.saved.isEmpty)
    }

    @Test func surprisePoolMergesFreshRecentsWithOnScreenOnes() async throws {
        let harness = Harness()
        harness.hubs = .success(F.hubsContainer([F.hub("home.recent", [F.raw("1")])]))
        harness.recent = .success(F.metadataContainer([F.raw("1"), F.raw("7", type: "show")]))
        let feed = harness.makeFeed()
        try await feed.refresh()

        var picks = Set<SurpriseMe.Target>()
        for _ in 0..<100 {
            if let pick = try await feed.surprise(.any) { picks.insert(pick) }
        }
        #expect(picks == [.movie("1"), .show("7")])
    }

    @Test func surpriseFallsBackToOnScreenItemsWhenTheFetchFails() async throws {
        let harness = Harness()
        harness.hubs = .success(F.hubsContainer([F.hub("home.recent", [F.raw("1")])]))
        harness.recent = .failure(Offline())
        let feed = harness.makeFeed()
        try await feed.refresh()
        #expect(try await feed.surprise(.any) == .movie("1"))
    }

    @Test func surpriseReportsAFailedLookupOnlyWhenNothingOnScreenCanStandIn() async throws {
        let harness = Harness()
        harness.recent = .failure(Offline())
        await #expect(throws: SurpriseMe.LookupFailure.self) { try await harness.makeFeed().surprise(.any) }

        harness.hubs = .success(F.hubsContainer([F.hub("home.recent", [F.raw("1")])]))
        let feed = harness.makeFeed()
        try await feed.refresh()
        #expect(try await feed.surprise(.any) == .movie("1"))
        await #expect(throws: SurpriseMe.LookupFailure.self) { try await feed.surprise(.show) }
    }

    @Test func surpriseWithASuccessfulEmptyLookupPicksNothing() async throws {
        let harness = Harness()
        #expect(try await harness.makeFeed().surprise(.any) == nil)
    }

    @Test func surpriseFiltersFreshItemsByLibraryVisibility() async throws {
        let harness = Harness()
        harness.excluded = [2]
        harness.recent = .success(F.metadataContainer([F.raw("7", fields: ["librarySectionID": 2])]))
        #expect(try await harness.makeFeed().surprise(.any) == nil)
    }

    @Test func heroModelUsesTheBucketEyebrowAndCachedArt() async throws {
        let harness = Harness()
        harness.stored = snapshot(keys: ["1"])
        let feed = harness.makeFeed()
        feed.hydrateFromSnapshot()
        let hero = try #require(feed.arrangement.hero)
        #expect(feed.heroModel(for: hero).eyebrow == "Continue Watching")
        #expect(feed.heroModel(for: hero).backdropPath == "/art/1")
        #expect(feed.heroModel(for: hero, bucket: .recentlyAdded).eyebrow == "Recently Added")
    }
}

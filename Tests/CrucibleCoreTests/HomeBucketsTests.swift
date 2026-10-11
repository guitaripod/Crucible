import Foundation
import Testing
@testable import CrucibleCore

struct HomeBucketsTests {
    private typealias F = HomeFixtures

    private func ids(_ items: [PlexMetadata]) -> [String] { items.map(\.id) }

    @Test func hubsAreBucketedByIdentifierSubstring() {
        let buckets = HomeBuckets(hubs: F.hubs([
            F.hub("home.continue", [F.raw("1")]),
            F.hub("home.inprogress.extra", [F.raw("2")]),
            F.hub("home.ondeck", [F.raw("3")]),
            F.hub("library.recentlyAdded.1", [F.raw("4")]),
            F.hub("home.recent", [F.raw("5")]),
        ]))
        #expect(ids(buckets.continueWatching) == ["1", "2"])
        #expect(ids(buckets.onDeck) == ["3"])
        #expect(ids(buckets.recent) == ["4", "5"])
    }

    @Test func identifierMatchingIgnoresCase() {
        let buckets = HomeBuckets(hubs: F.hubs([
            F.hub("Home.ContinueWatching", [F.raw("1")]),
            F.hub("Home.OnDeck", [F.raw("2")]),
        ]))
        #expect(ids(buckets.continueWatching) == ["1"])
        #expect(ids(buckets.onDeck) == ["2"])
    }

    @Test func continueMatchesBeforeOnDeckAndRecent() {
        let buckets = HomeBuckets(hubs: F.hubs([F.hub("continue.ondeck.recent", [F.raw("1")])]))
        #expect(ids(buckets.continueWatching) == ["1"])
        #expect(buckets.onDeck.isEmpty)
        #expect(buckets.recent.isEmpty)
    }

    @Test func hubsWithoutIdentifierItemsOrKnownNameAreSkipped() {
        let buckets = HomeBuckets(hubs: F.hubs([
            F.hub(nil, [F.raw("1")]),
            F.hub("home.continue", nil),
            F.hub("home.continue", []),
            F.hub("home.playlists", [F.raw("2")]),
        ]))
        #expect(buckets.count == 0)
        #expect(HomeBuckets(hubs: nil).count == 0)
    }

    @Test func snapshotCardsAreCappedPerBucketAndCarryArt() {
        let many = (0..<30).map { F.item("cw\($0)", fields: ["art": "/art/\($0)", "grandparentArt": "/gp/\($0)"]) }
        let buckets = HomeBuckets(continueWatching: many, onDeck: Array(many.prefix(3)), recent: Array(many.prefix(21)))
        let cards = buckets.snapshotCards()
        #expect(cards.filter { $0.bucket == "cw" }.count == HomeBuckets.snapshotCardCap)
        #expect(cards.filter { $0.bucket == "od" }.count == 3)
        #expect(cards.filter { $0.bucket == "ra" }.count == 20)
        #expect(cards.first?.art == "/art/0")
        #expect(cards.first?.grandparentArt == "/gp/0")
    }

    @Test func snapshotRoundTripsIntoBucketsAndArt() {
        let source = HomeBuckets(
            continueWatching: [F.item("1", fields: ["art": "/a/1"])],
            onDeck: [F.item("2", type: "episode", fields: ["grandparentArt": "/g/2", "art": "/a/2"])],
            recent: [F.item("3")]
        )
        let snapshot = HomeSnapshot(schema: HomeSnapshotStore.schemaVersion, machineIdentifier: "m", savedAt: 1, cards: source.snapshotCards())
        let restored = HomeBuckets(snapshot: snapshot)
        #expect(ids(restored.continueWatching) == ["1"])
        #expect(ids(restored.onDeck) == ["2"])
        #expect(ids(restored.recent) == ["3"])
        #expect(HomeBuckets.cachedArt(in: snapshot) == ["1": "/a/1", "2": "/g/2"])
    }

    @Test func unknownSnapshotBucketCodesLandInRecent() {
        let card = F.item("9").homeCard(bucket: "zz")
        let restored = HomeBuckets(snapshot: HomeSnapshot(schema: 2, machineIdentifier: "m", savedAt: 1, cards: [card]))
        #expect(ids(restored.recent) == ["9"])
    }

    @Test func visibleDropsExcludedLibrariesButKeepsItemsWithNoLibrary() {
        let buckets = HomeBuckets(
            continueWatching: [F.item("1", fields: ["librarySectionID": 1]), F.item("2", fields: ["librarySectionID": 2])],
            onDeck: [F.item("3")],
            recent: [F.item("4", fields: ["librarySectionID": 2])]
        )
        let visible = buckets.visible(excluding: [2])
        #expect(ids(visible.continueWatching) == ["1"])
        #expect(ids(visible.onDeck) == ["3"])
        #expect(visible.recent.isEmpty)
    }

    @Test func visibleDedupesAfterFilteringAndKeepsFirstOccurrence() {
        let buckets = HomeBuckets(continueWatching: [F.item("1", title: "first"), F.item("1", title: "second"), F.item("2")])
        let visible = buckets.visible(excluding: [])
        #expect(ids(visible.continueWatching) == ["1", "2"])
        #expect(visible.continueWatching.first?.title == "first")
    }
}

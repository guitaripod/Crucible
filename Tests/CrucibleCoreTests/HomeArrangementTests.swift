import Foundation
import Testing
@testable import CrucibleCore

struct HomeArrangementTests {
    private typealias F = HomeFixtures

    private func items(_ keys: String...) -> [PlexMetadata] { keys.map { F.item($0) } }
    private func ids(_ items: [PlexMetadata]) -> [String] { items.map(\.id) }

    @Test func heroIsFirstContinueWatchingAndLeavesTheRail() {
        let arrangement = HomeArrangement(buckets: HomeBuckets(
            continueWatching: items("1", "2", "3"),
            onDeck: items("5"),
            recent: items("9")
        ))
        #expect(arrangement.hero?.id == "1")
        #expect(arrangement.heroIsContinue)
        #expect(ids(arrangement.continueRail) == ["2", "3"])
        #expect(arrangement.heroEyebrow == "Continue Watching")
    }

    @Test func heroFallsBackToFirstOnDeckAndLeavesUpNext() {
        let arrangement = HomeArrangement(buckets: HomeBuckets(onDeck: items("5", "6", "7")))
        #expect(arrangement.hero?.id == "5")
        #expect(!arrangement.heroIsContinue)
        #expect(arrangement.continueRail.isEmpty)
        #expect(ids(arrangement.upNext) == ["6", "7"])
        #expect(arrangement.heroEyebrow == "Up Next")
    }

    @Test func upNextSkipsEverythingInContinueWatching() {
        let arrangement = HomeArrangement(buckets: HomeBuckets(
            continueWatching: items("1", "2"),
            onDeck: items("2", "1", "3")
        ))
        #expect(ids(arrangement.upNext) == ["3"])
    }

    @Test func recentIsPassedThroughUntouched() {
        let arrangement = HomeArrangement(buckets: HomeBuckets(continueWatching: items("1"), recent: items("1", "2")))
        #expect(ids(arrangement.recent) == ["1", "2"])
        #expect(!arrangement.isEmpty)
    }

    @Test func emptyArrangementHasNoHeroAndIsEmpty() {
        let arrangement = HomeArrangement(buckets: HomeBuckets())
        #expect(arrangement.isEmpty)
        #expect(arrangement.hero == nil)
        #expect(HomeArrangement().isEmpty)
    }

    @Test func recentAloneIsNotEmpty() {
        #expect(!HomeArrangement(buckets: HomeBuckets(recent: items("1"))).isEmpty)
    }

    @Test func itemsAndTitlesPerBucket() {
        let arrangement = HomeArrangement(buckets: HomeBuckets(
            continueWatching: items("1", "2"),
            onDeck: items("3"),
            recent: items("4")
        ))
        #expect(ids(arrangement.items(for: .hero)) == ["1"])
        #expect(ids(arrangement.items(for: .continueWatching)) == ["2"])
        #expect(ids(arrangement.items(for: .upNext)) == ["3"])
        #expect(ids(arrangement.items(for: .recentlyAdded)) == ["4"])
        #expect(arrangement.title(for: .hero) == "Continue Watching")
        #expect(arrangement.title(for: .continueWatching) == "Continue Watching")
        #expect(arrangement.title(for: .upNext) == "Up Next")
        #expect(arrangement.title(for: .recentlyAdded) == "Recently Added")
    }

    @Test func weekCardNeedsContentAndActivity() {
        let filled = HomeArrangement(buckets: HomeBuckets(recent: items("1")))
        #expect(filled.showsWeekCard(hasWeekActivity: true))
        #expect(!filled.showsWeekCard(hasWeekActivity: false))
        #expect(!HomeArrangement().showsWeekCard(hasWeekActivity: true))
    }
}

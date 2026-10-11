import Foundation
import Testing
@testable import CrucibleCore

struct LibraryRecentlyWatchedTests {
    private let episodes = #"""
    [
      {"ratingKey":"101","type":"episode","title":"E1","grandparentRatingKey":"5","grandparentTitle":"Show A","viewedAt":1000},
      {"ratingKey":"102","type":"episode","title":"E2","grandparentRatingKey":"5","grandparentTitle":"Show A","viewedAt":3000},
      {"ratingKey":"201","type":"episode","title":"X1","grandparentRatingKey":"6","grandparentTitle":"Show B","viewedAt":2000},
      {"ratingKey":"102","type":"episode","title":"E2 again","grandparentRatingKey":"5","grandparentTitle":"Show A","viewedAt":500}
    ]
    """#

    @Test func aShowRailKeepsOneCardPerSeriesNewestFirst() throws {
        let rows = try LibraryFixtures.history(episodes)
        let items = RecentlyWatched.railItems(from: rows, groupingByShow: true, limit: 20)
        #expect(items.map(\.id) == ["102", "201"])
        #expect(items.map(\.viewedAt) == [3000, 2000])
    }

    @Test func aMovieRailKeepsOneCardPerItem() throws {
        let rows = try LibraryFixtures.history(episodes)
        let items = RecentlyWatched.railItems(from: rows, groupingByShow: false, limit: 20)
        #expect(items.map(\.id) == ["102", "201", "101"])
    }

    @Test func theRailStopsAtTheLimit() throws {
        let rows = try LibraryFixtures.history(episodes)
        #expect(RecentlyWatched.railItems(from: rows, groupingByShow: false, limit: 2).map(\.id) == ["102", "201"])
    }

    @Test func rowsWithoutAGroupKeyAreSkipped() throws {
        let rows = try LibraryFixtures.history(#"[{"title":"No key","viewedAt":10},{"ratingKey":"7","type":"movie","title":"Keyed","viewedAt":5}]"#)
        #expect(RecentlyWatched.railItems(from: rows, groupingByShow: false, limit: 20).map(\.id) == ["7"])
    }

    @Test func aShowRailFallsBackToTheEpisodeWhenTheSeriesIsUnknown() throws {
        let rows = try LibraryFixtures.history(#"[{"ratingKey":"7","type":"episode","title":"Orphan","viewedAt":5}]"#)
        #expect(RecentlyWatched.railItems(from: rows, groupingByShow: true, limit: 20).map(\.id) == ["7"])
    }

    @Test func rowsWithoutATimestampSortLast() throws {
        let rows = try LibraryFixtures.history(#"[{"ratingKey":"1","title":"Undated"},{"ratingKey":"2","title":"Dated","viewedAt":9}]"#)
        #expect(RecentlyWatched.railItems(from: rows, groupingByShow: false, limit: 20).map(\.id) == ["2", "1"])
    }

    @Test func manyAccountsNarrowTheHistoryToTheOwner() throws {
        let rows = try LibraryFixtures.history(#"""
        [
          {"ratingKey":"1","viewedAt":1,"accountID":1},
          {"ratingKey":"2","viewedAt":2,"accountID":5},
          {"ratingKey":"3","viewedAt":3,"accountID":1},
          {"ratingKey":"4","viewedAt":4}
        ]
        """#)
        #expect(RecentlyWatched.ownerScoped(rows).compactMap(\.ratingKey) == ["1", "3"])
    }

    @Test func aSingleAccountIsLeftUntouched() throws {
        let sharedUser = try LibraryFixtures.history(#"[{"ratingKey":"1","accountID":42},{"ratingKey":"2","accountID":42},{"ratingKey":"3"}]"#)
        #expect(RecentlyWatched.ownerScoped(sharedUser).count == 3)
        let none = try LibraryFixtures.history(#"[{"ratingKey":"1"},{"ratingKey":"2"}]"#)
        #expect(RecentlyWatched.ownerScoped(none).count == 2)
    }

    @Test func theRailHidesWhileFilteringAndWithoutTheContinueItem() throws {
        let recents = try LibraryFixtures.items(#"[{"ratingKey":"1","type":"movie","title":"A"},{"ratingKey":"2","type":"movie","title":"B"}]"#)
        let featured = recents[0]
        #expect(RecentlyWatched.visible(recents, continueItem: nil, kind: .movie, isFiltering: false).map(\.id) == ["1", "2"])
        #expect(RecentlyWatched.visible(recents, continueItem: featured, kind: .movie, isFiltering: false).map(\.id) == ["2"])
        #expect(RecentlyWatched.visible(recents, continueItem: nil, kind: .movie, isFiltering: true).isEmpty)
    }

    @Test func aShowRailDropsTheSeriesTheBannerOffers() throws {
        let recents = try LibraryFixtures.items(#"[{"ratingKey":"20","type":"episode","title":"E","grandparentRatingKey":"5"},{"ratingKey":"30","type":"episode","title":"F","grandparentRatingKey":"6"}]"#)
        let featured = try LibraryFixtures.item(#"{"ratingKey":"21","type":"episode","title":"G","grandparentRatingKey":"5","viewOffset":100}"#)
        #expect(RecentlyWatched.visible(recents, continueItem: featured, kind: .show, isFiltering: false).map(\.id) == ["30"])
    }

    @Test func aReloadedRailRedrawsOnlyWhenItChanged() throws {
        let rail = try LibraryFixtures.items(#"[{"ratingKey":"1","title":"A","viewedAt":10},{"ratingKey":"2","title":"B","viewedAt":5}]"#)
        let same = try LibraryFixtures.items(#"[{"ratingKey":"1","title":"A","viewedAt":10},{"ratingKey":"2","title":"B","viewedAt":5}]"#)
        let replayed = try LibraryFixtures.items(#"[{"ratingKey":"1","title":"A","viewedAt":99},{"ratingKey":"2","title":"B","viewedAt":5}]"#)
        let reordered = try LibraryFixtures.items(#"[{"ratingKey":"2","title":"B","viewedAt":5},{"ratingKey":"1","title":"A","viewedAt":10}]"#)
        #expect(!RecentlyWatched.differs(same, from: rail))
        #expect(RecentlyWatched.differs(replayed, from: rail))
        #expect(RecentlyWatched.differs(reordered, from: rail))
        #expect(RecentlyWatched.differs([], from: rail))
        #expect(!RecentlyWatched.differs([], from: []))
    }

    @Test func limitsMatchTheRailAndTheSeeAllGrid() {
        #expect(RecentlyWatched.railLimit == 20)
        #expect(RecentlyWatched.gridLimit == 120)
    }
}

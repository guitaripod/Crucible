import Foundation
import Testing
@testable import CrucibleCore
@testable import CrucibleStats

struct HomeWeekCardModelTests {
    @Test func totalUsesTheWeekFormat() {
        let model = HomeWeekCardModel(dailySeconds: [0, 0, 0, 0, 0, 0, 0], todayIndex: 0, thisWeekSeconds: 26_400, deltaPercent: nil)
        #expect(model.total == "7 h 20 m")
        #expect(model.delta == nil)
    }

    @Test func deltaTextCoversMoreLessSameAndNone() {
        #expect(HomeWeekCardModel.deltaText(25) == "25% more than last week")
        #expect(HomeWeekCardModel.deltaText(-40) == "40% less than last week")
        #expect(HomeWeekCardModel.deltaText(0) == "Same as last week")
        #expect(HomeWeekCardModel.deltaText(nil) == nil)
    }

    @Test func barsAreNormalisedAgainstTheBusiestDayAndMarkToday() {
        let model = HomeWeekCardModel(dailySeconds: [3600, 7200, 0, 1800, 0, 0, 0], todayIndex: 3, thisWeekSeconds: 12_600, deltaPercent: 10)
        #expect(model.bars.count == 7)
        #expect(model.bars.map(\.ratio) == [0.5, 1, 0, 0.25, 0, 0, 0])
        #expect(model.bars.map(\.isToday) == [false, false, false, true, false, false, false])
    }

    @Test func allZeroDaysGiveFlatBarsWithoutDividingByZero() {
        let model = HomeWeekCardModel(dailySeconds: Array(repeating: 0, count: 7), todayIndex: 2, thisWeekSeconds: 0, deltaPercent: nil)
        #expect(model.bars.allSatisfy { $0.ratio == 0 })
    }

    @Test func shortOrEmptyDailyListsAreZeroPaddedToSevenBars() {
        let model = HomeWeekCardModel(dailySeconds: [60, 120], todayIndex: 1, thisWeekSeconds: 180, deltaPercent: nil)
        #expect(model.bars.count == 7)
        #expect(model.bars[1].ratio == 1)
        #expect(model.bars[6].ratio == 0)
        #expect(HomeWeekCardModel(dailySeconds: [], todayIndex: 0, thisWeekSeconds: 0, deltaPercent: nil).bars.count == 7)
    }

    @Test func accessibilityLabelSpellsOutTimeAndDelta() {
        let model = HomeWeekCardModel(dailySeconds: [4500, 0, 0, 0, 0, 0, 0], todayIndex: 0, thisWeekSeconds: 4500, deltaPercent: -10)
        #expect(model.accessibilityLabel == "This week · 1 hour, 15 minutes watched · 10% less than last week")
        let plain = HomeWeekCardModel(dailySeconds: [], todayIndex: 0, thisWeekSeconds: 30, deltaPercent: nil)
        #expect(plain.accessibilityLabel == "This week · less than a minute watched")
    }

    @Test func summaryProducesACardOnlyWhenThereIsActivity() {
        let empty = HomeWeekSummary(
            dailySeconds: Array(repeating: 0, count: 7), todayIndex: 0, thisWeekSeconds: 0,
            lastWeekSameSpanSeconds: 0, lastWeekSeconds: 0
        )
        #expect(empty.cardModel == nil)
        let busy = HomeWeekSummary(
            dailySeconds: [3600, 0, 0, 0, 0, 0, 0], todayIndex: 0, thisWeekSeconds: 3600,
            lastWeekSameSpanSeconds: 1800, lastWeekSeconds: 5000
        )
        let model = busy.cardModel
        #expect(model?.total == "1 h 0 m")
        #expect(model?.delta == "100% more than last week")
        let quietNow = HomeWeekSummary(
            dailySeconds: Array(repeating: 0, count: 7), todayIndex: 0, thisWeekSeconds: 0,
            lastWeekSameSpanSeconds: 0, lastWeekSeconds: 600
        )
        #expect(quietNow.cardModel?.total == "0 min")
    }
}

struct HomeStateCopyTests {
    @Test func emptyCopyDependsOnLibraryFiltering() {
        let plain = HomeStateCopy.empty(librariesAreFiltered: false)
        #expect(plain.title == "Nothing Here Yet")
        #expect(plain.message == "Add media to your Plex libraries to see it here.")
        let filtered = HomeStateCopy.empty(librariesAreFiltered: true)
        #expect(filtered.title == "Nothing From These Libraries")
        #expect(filtered.message == "Home is limited to the libraries you chose in Settings.")
    }

    @Test func loadFailureCopyUsesTheConnectionMessage() {
        let copy = HomeStateCopy.loadFailed(APIError.timedOut)
        #expect(copy.title == "Couldn't Reach Server")
        #expect(copy.message == ConnectionError.message(for: APIError.timedOut))
    }
}

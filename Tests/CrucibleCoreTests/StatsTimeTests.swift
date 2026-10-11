import Foundation
import Testing
@testable import CrucibleStats

struct StatsTimeTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let newYork: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, in calendar: Calendar = StatsTimeTests.utc) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func epochStartsOnAThursdayInJanuary1970() {
        let components = StatsTime(calendar: Self.utc).components(forViewedAt: 0)
        #expect(components.dayEpoch == 0)
        #expect(components.hourLocal == 0)
        #expect(components.weekday == 5)
        #expect(components.monthEpoch == 1970 * 12)
        #expect(components.monthDay == 101)
        #expect(components.year == 1970)
    }

    @Test func componentsBucketByLocalCalendar() {
        let viewedAt = Int(date(1970, 2, 1, hour: 5).timeIntervalSince1970)
        let components = StatsTime(calendar: Self.utc).components(forViewedAt: viewedAt)
        #expect(components.dayEpoch == 31)
        #expect(components.hourLocal == 5)
        #expect(components.weekday == 1)
        #expect(components.monthEpoch == 1970 * 12 + 1)
        #expect(components.monthDay == 201)
    }

    @Test func localMidnightBelongsToTheNewLocalDay() {
        let time = StatsTime(calendar: Self.newYork)
        let lateEvening = Int(date(2026, 6, 15, hour: 23, in: Self.newYork).timeIntervalSince1970)
        let afterMidnight = Int(date(2026, 6, 16, hour: 0, in: Self.newYork).timeIntervalSince1970)
        #expect(time.components(forViewedAt: afterMidnight).dayEpoch == time.components(forViewedAt: lateEvening).dayEpoch + 1)
        #expect(time.components(forViewedAt: afterMidnight).hourLocal == 0)
    }

    @Test func consecutiveLocalDaysDifferByOneAcrossDaylightSavingChanges() {
        let time = StatsTime(calendar: Self.newYork)
        let days = (5...12).map { time.components(forViewedAt: Int(date(2026, 3, $0, hour: 12, in: Self.newYork).timeIntervalSince1970)).dayEpoch }
        for pair in zip(days, days.dropFirst()) {
            #expect(pair.1 - pair.0 == 1)
        }
    }

    @Test func dayEpochRoundTripsToTheStartOfThatDay() {
        let time = StatsTime(calendar: Self.utc)
        let now = date(2026, 6, 15, hour: 18)
        let today = time.todayDayEpoch(now: now)
        #expect(time.date(forDayEpoch: today) == date(2026, 6, 15, hour: 0))
        #expect(time.todayDayEpoch(now: date(2026, 6, 16, hour: 0)) == today + 1)
    }

    @Test func monthEpochSplitsIntoYearAndMonth() {
        #expect(StatsTime.monthEpochToYearMonth(2026 * 12 + 5).year == 2026)
        #expect(StatsTime.monthEpochToYearMonth(2026 * 12 + 5).month == 6)
        #expect(StatsTime.monthEpochToYearMonth(1970 * 12).month == 1)
    }

    @Test func monthSymbolsCoverTheYear() {
        #expect(StatsTime.monthSymbols.count == 12)
        #expect(StatsTime.monthSymbols.first == "Jan")
        #expect(StatsTime.monthSymbols.last == "Dec")
    }

    @Test func heatmapAlignsToSundaysAndBucketsIntensity() {
        let time = StatsTime(calendar: Self.utc)
        let today = time.todayDayEpoch(now: date(2026, 6, 15))
        let days = [
            DayCount(dayEpoch: today, count: 5),
            DayCount(dayEpoch: today - 1, count: 1),
            DayCount(dayEpoch: today - 2, count: 0),
            DayCount(dayEpoch: today - 400, count: 3),
            DayCount(dayEpoch: today + 3, count: 9),
        ]
        let model = time.heatmapModel(days: days, today: today)

        #expect(model.columns == 53)
        #expect(model.lastDayEpoch == today)
        #expect(Self.utc.component(.weekday, from: time.date(forDayEpoch: model.firstDayEpoch)) == 1)
        #expect(model.lastDayEpoch - model.firstDayEpoch < 53 * 7)

        #expect(model.cells.count == 2)
        let busiest = model.cells.first { $0.dayEpoch == today }
        let quietest = model.cells.first { $0.dayEpoch == today - 1 }
        #expect(busiest?.level == 4)
        #expect(quietest?.level == 1)
        #expect(busiest?.row == 1)
        #expect(busiest?.column == (today - model.firstDayEpoch) / 7)
    }

    @Test func heatmapLabelsTheFirstColumnOfEachMonth() {
        let time = StatsTime(calendar: Self.utc)
        let today = time.todayDayEpoch(now: date(2026, 6, 15))
        let model = time.heatmapModel(days: [], today: today)
        #expect(model.cells.isEmpty)
        #expect(model.monthLabels[0] != nil)
        let labels = model.monthLabels.keys.sorted().compactMap { model.monthLabels[$0] }
        #expect(labels.last == "Jun")
        #expect(labels.count >= 12)
    }

    @Test func rangeLowerBoundsAreRelativeToNow() {
        let now = date(2026, 6, 15, hour: 12)
        let nowSeconds = Int(now.timeIntervalSince1970)
        #expect(StatsRange.allTime.lowerViewedAt(now: now, calendar: Self.utc) == nil)
        #expect(StatsRange.week.lowerViewedAt(now: now, calendar: Self.utc) == nowSeconds - 7 * 86_400)
        #expect(StatsRange.month.lowerViewedAt(now: now, calendar: Self.utc) == nowSeconds - 30 * 86_400)
        #expect(StatsRange.year.lowerViewedAt(now: now, calendar: Self.utc) == Int(date(2026, 1, 1, hour: 0).timeIntervalSince1970))
    }

    @Test func rangeTitlesAreStable() {
        #expect(StatsRange.allCases.map(\.title) == ["Week", "Month", "Year", "All"])
    }

    @Test func scopeClauseComposesAccountAndLibraryFilters() {
        #expect(StatsScope().clause() == "")
        #expect(StatsScope(accountID: 1).clause() == " AND accountID = 1")
        #expect(StatsScope(excludedSections: [2, 3]).clause() == " AND (librarySectionID IS NULL OR librarySectionID NOT IN (2,3))")
        #expect(StatsScope(accountID: 1, excludedSections: [4]).clause(column: "p.accountID") == " AND p.accountID = 1 AND (p.librarySectionID IS NULL OR p.librarySectionID NOT IN (4))")
    }
}

import Foundation
import Testing
@testable import CrucibleCore

struct HistoryDayTests {
    private let calendar = HistoryFixtures.utc
    private let now = HistoryFixtures.now

    private func day(daysAgo: Int) -> Date {
        calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(HistoryFixtures.ago(days: daysAgo))))
    }

    @Test func undatedPlaysLandInTheEarlierBucket() {
        #expect(HistoryDay.start(for: nil, calendar: calendar) == .distantPast)
        #expect(HistoryDay.title(for: .distantPast, now: now, calendar: calendar) == "Earlier")
    }

    @Test func datedPlaysLandOnTheStartOfTheirDay() {
        let start = HistoryDay.start(for: HistoryFixtures.ago(hours: 3), calendar: calendar)
        #expect(start == calendar.startOfDay(for: now))
    }

    @Test func titlesNameTodayAndYesterday() {
        #expect(HistoryDay.title(for: day(daysAgo: 0), now: now, calendar: calendar) == "Today")
        #expect(HistoryDay.title(for: day(daysAgo: 1), now: now, calendar: calendar) == "Yesterday")
    }

    @Test func yesterdayHoldsAtTheStartOfToday() {
        let midnight = calendar.startOfDay(for: now).addingTimeInterval(60)
        #expect(HistoryDay.title(for: day(daysAgo: 1), now: midnight, calendar: calendar) == "Yesterday")
        #expect(HistoryDay.title(for: day(daysAgo: 0), now: midnight, calendar: calendar) == "Today")
    }

    @Test func olderDaysShowTheYearOnlyWhenItIsNotThisYear() {
        let sameYear = HistoryDay.title(for: day(daysAgo: 20), now: now, calendar: calendar)
        let otherYear = HistoryDay.title(for: day(daysAgo: 400), now: now, calendar: calendar)
        #expect(!sameYear.contains("2026"))
        #expect(!sameYear.isEmpty)
        #expect(otherYear.contains("2025"))
    }

    @Test func groupsKeepServerOrderAndSplitByDay() {
        let items = [
            HistoryFixtures.item(key: "a", viewedAt: HistoryFixtures.ago(hours: 1)),
            HistoryFixtures.item(key: "b", viewedAt: HistoryFixtures.ago(hours: 2)),
            HistoryFixtures.item(key: "c", viewedAt: HistoryFixtures.ago(days: 1)),
            HistoryFixtures.item(key: "d", viewedAt: nil),
            HistoryFixtures.item(key: "e", viewedAt: HistoryFixtures.ago(hours: 5)),
            HistoryFixtures.item(key: "f", viewedAt: nil)
        ]
        let groups = HistoryDay.groups(of: items, calendar: calendar)
        #expect(groups.map(\.day) == [day(daysAgo: 0), day(daysAgo: 1), .distantPast])
        #expect(groups.map { $0.items.map(\.ratingKey) } == [["a", "b", "e"], ["c"], ["d", "f"]])
    }

    @Test func noItemsMakeNoGroups() {
        #expect(HistoryDay.groups(of: [], calendar: calendar).isEmpty)
    }
}

struct HistorySummaryTests {
    private let now = HistoryFixtures.now

    private func play(hoursAgo: Int, minutes: Int?) -> HistoryItem {
        HistoryFixtures.item(viewedAt: HistoryFixtures.ago(hours: hoursAgo), duration: minutes.map { $0 * 60_000 })
    }

    @Test func nothingThisWeekHasNoSummary() {
        #expect(HistorySummary.text(for: [], now: now) == nil)
        let old = HistoryFixtures.item(viewedAt: HistoryFixtures.ago(days: 8), duration: 60_000)
        let undated = HistoryFixtures.item(viewedAt: nil, duration: 60_000)
        #expect(HistorySummary.text(for: [old, undated], now: now) == nil)
    }

    @Test func singularPlayWithMinutes() {
        #expect(HistorySummary.text(for: [play(hoursAgo: 1, minutes: 45)], now: now) == "1 play this week · 45 m")
    }

    @Test func pluralPlaysWithHoursAndMinutes() {
        let items = [play(hoursAgo: 1, minutes: 90), play(hoursAgo: 30, minutes: 50), play(hoursAgo: 60, minutes: 40)]
        #expect(HistorySummary.text(for: items, now: now) == "3 plays this week · 3 h 0 m")
    }

    @Test func hourBoundaryUsesHoursForSixtyMinutes() {
        #expect(HistorySummary.text(for: [play(hoursAgo: 1, minutes: 60)], now: now) == "1 play this week · 1 h 0 m")
        #expect(HistorySummary.text(for: [play(hoursAgo: 1, minutes: 59)], now: now) == "1 play this week · 59 m")
    }

    @Test func oneUnknownDurationDropsTheWholeTime() {
        let items = [play(hoursAgo: 1, minutes: 90), play(hoursAgo: 2, minutes: nil)]
        #expect(HistorySummary.text(for: items, now: now) == "2 plays this week")
    }

    @Test func subMinuteTotalsOmitTheTime() {
        let short = HistoryFixtures.item(viewedAt: HistoryFixtures.ago(hours: 1), duration: 30_000)
        #expect(HistorySummary.text(for: [short], now: now) == "1 play this week")
    }

    @Test func unknownDurationOutsideTheWeekDoesNotMatter() {
        let items = [play(hoursAgo: 1, minutes: 30), HistoryFixtures.item(viewedAt: HistoryFixtures.ago(days: 9), duration: nil)]
        #expect(HistorySummary.text(for: items, now: now) == "1 play this week · 30 m")
    }

    @Test func exactlyOneWeekAgoStillCounts() {
        let edge = HistoryFixtures.item(viewedAt: HistoryFixtures.ago(days: 7), duration: 60_000)
        let beyond = HistoryFixtures.item(viewedAt: HistoryFixtures.ago(days: 7) - 1, duration: 60_000)
        #expect(HistorySummary.text(for: [edge], now: now) == "1 play this week · 1 m")
        #expect(HistorySummary.text(for: [beyond], now: now) == nil)
    }
}

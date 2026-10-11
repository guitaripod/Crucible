import Foundation
import Testing
@testable import CrucibleStats

struct StatsYearInReviewTests {
    private typealias F = StatsFixtures

    private func summary(_ overview: StatsOverview, heatmap: [DayCount] = []) -> YearInReviewSummary? {
        var snapshot = F.baseSnapshot(overview: overview)
        snapshot.heatmap = heatmap
        return YearInReviewSummary(snapshot: snapshot, time: F.time, now: F.now)
    }

    @Test func anEmptySnapshotHasNoCard() {
        #expect(YearInReviewSummary(snapshot: StatsSnapshot(), time: F.time, now: F.now) == nil)
    }

    @Test func hoursLeadWhenRuntimesAreKnown() {
        let card = summary(F.makeOverview(estHours: 120.4))
        #expect(card?.caption == "2026 SO FAR")
        #expect(card?.primary == "120")
        #expect(card?.unit == "hours")
    }

    @Test func fewerThanHalfAnHourReadsAsUnderOne() {
        let card = summary(F.makeOverview(estHours: 0.2))
        #expect(card?.primary == "<1")
        #expect(card?.unit == "hours")
    }

    @Test func oneHourIsSingular() {
        #expect(summary(F.makeOverview(estHours: 1.1))?.unit == "hour")
    }

    @Test func playsLeadWhileRuntimesAreUnknown() {
        let many = summary(F.makeOverview(totalPlays: 12, estHours: nil))
        #expect(many?.primary == "12")
        #expect(many?.unit == "plays")
        #expect(summary(F.makeOverview(totalPlays: 1, estHours: nil))?.unit == "play")
    }

    @Test func detailListsMoviesEpisodesAndTheStreak() {
        let full = summary(F.makeOverview(episodes: 80, movies: 1, currentStreak: 3))
        #expect(full?.detail == "1 movie · 80 episodes · 3-day streak")
        let sparse = summary(F.makeOverview(episodes: 1, movies: 0, currentStreak: 0))
        #expect(sparse?.detail == "1 episode")
        let none = summary(F.makeOverview(episodes: 0, movies: 0, currentStreak: 0))
        #expect(none?.detail == "")
    }

    @Test func spokenTextReadsTheWholeCard() {
        let card = summary(F.makeOverview(episodes: 80, movies: 0, currentStreak: 0, estHours: 120.4))
        #expect(card?.spokenText == "2026 So Far. 120 hours. 80 episodes. Statistics")
    }

    @Test func stripCoversSeventyEightDaysInThreeRows() {
        #expect(YearInReviewSummary.stripCount == 78)
        #expect(YearInReviewSummary.stripColumns * YearInReviewSummary.stripRows == 78)
        #expect(summary(F.makeOverview())?.strip.count == 78)
    }

    @Test func stripIsFlatWithoutActivity() {
        #expect(YearInReviewSummary.stripLevels(from: [], today: F.today) == Array(repeating: 0, count: 78))
    }

    @Test func stripEndsToday() {
        let levels = YearInReviewSummary.stripLevels(from: [DayCount(dayEpoch: F.today, count: 5)], today: F.today)
        #expect(levels.last == 1)
        #expect(levels.dropLast().allSatisfy { $0 == 0 })
    }

    @Test func stripIgnoresDaysOutsideTheWindow() {
        let levels = YearInReviewSummary.stripLevels(from: [DayCount(dayEpoch: F.today - 78, count: 9), DayCount(dayEpoch: F.today + 1, count: 9)], today: F.today)
        #expect(levels == Array(repeating: 0, count: 78))
    }

    @Test func stripBucketsByQuantileSoLightWatchersStillGetContrast() {
        let days = (0..<5).map { DayCount(dayEpoch: F.today - $0, count: $0 + 1) }
        let levels = YearInReviewSummary.stripLevels(from: days, today: F.today)
        #expect(Array(levels.suffix(5)) == [5, 4, 3, 2, 1])
        #expect(levels.allSatisfy { (0...5).contains($0) })
    }

    @Test func stripFollowsTheSnapshotHeatmap() {
        let card = summary(F.makeOverview(), heatmap: [DayCount(dayEpoch: F.today - 1, count: 2)])
        #expect(card?.strip.suffix(2) == [1, 0])
    }
}

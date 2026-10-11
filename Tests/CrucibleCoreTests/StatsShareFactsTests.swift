import Foundation
import Testing
@testable import CrucibleStats

struct StatsShareFactsTests {
    private typealias F = StatsFixtures

    private func facts(_ snapshot: StatsSnapshot, range: StatsRange = .year) -> StatsShareFacts {
        StatsShareFacts(page: F.page(snapshot, range: range), time: F.time, now: F.now)
    }

    @Test func periodAndHeadlineFollowTheRange() {
        let snapshot = F.fullSnapshot()
        #expect(facts(snapshot, range: .week).period == "LAST 7 DAYS")
        #expect(facts(snapshot, range: .week).shareTitle == "My Week in Crucible")
        #expect(facts(snapshot, range: .month).period == "LAST 30 DAYS")
        #expect(facts(snapshot, range: .month).shareTitle == "My Month in Crucible")
        #expect(facts(snapshot, range: .year).period == "2026")
        #expect(facts(snapshot, range: .year).shareTitle == "My 2026 in Crucible")
        #expect(facts(snapshot, range: .allTime).period == "ALL TIME")
        #expect(facts(snapshot, range: .allTime).shareTitle == "My Crucible, All Time")
    }

    @Test func heroKeepsOnlyTheFirstClauseOfTheDetail() {
        let result = facts(F.fullSnapshot())
        #expect(result.heroValue == 120.formatted())
        #expect(result.heroUnit == "hours")
        #expect(result.heroDetail == "watched in 2026")
        #expect(result.eyebrow == "You're a Prime-Time Viewer")
    }

    @Test func figuresPreferTheLongestBingeOverTheTitleCount() {
        let withBinge = facts(F.fullSnapshot())
        #expect(withBinge.figures.map(\.label) == ["Plays", "Days Active", "Day Streak", "Longest Binge"])
        #expect(withBinge.figures.map(\.value) == ["100", "40", "3", "3h"])

        var snapshot = F.fullSnapshot()
        snapshot.binges = []
        let withoutBinge = facts(snapshot)
        #expect(withoutBinge.figures.last?.label == "Titles")
        #expect(withoutBinge.figures.last?.value == "32")
    }

    @Test func topTitlesRankByPlaysWithTiesGoingToShows() {
        var snapshot = F.fullSnapshot()
        snapshot.topShows = [
            ShowStat(ratingKey: "s1", title: "Severance", thumb: "/s1", count: 20),
            ShowStat(ratingKey: "s2", title: "Slow Horses", thumb: nil, count: 5),
        ]
        snapshot.topMovies = [
            MovieStat(ratingKey: "m1", title: "Heat", thumb: "/m1", count: 5, lastViewedAt: 1),
            MovieStat(ratingKey: "m2", title: "Ronin", thumb: nil, count: 1, lastViewedAt: 1),
        ]
        let titles = facts(snapshot).titles
        #expect(titles.map(\.name) == ["Severance", "Slow Horses", "Heat"])
        #expect(titles.map(\.rank) == [1, 2, 3])
        #expect(titles.map(\.caption) == ["20 episodes", "5 episodes", "Movie · 5 plays"])
        #expect(titles.map(\.placeholderSymbol) == ["tv", "tv", "film"])
        #expect(titles.map(\.thumb) == ["/s1", nil, "/m1"])
    }

    @Test func captionsUseTheSingularForOnePlay() {
        var snapshot = F.fullSnapshot()
        snapshot.topShows = [ShowStat(ratingKey: "s1", title: "Severance", thumb: nil, count: 1)]
        snapshot.topMovies = [MovieStat(ratingKey: "m1", title: "Heat", thumb: nil, count: 1, lastViewedAt: 1)]
        #expect(facts(snapshot).titles.map(\.caption) == ["1 episode", "Movie"])
    }

    @Test func summaryReadsAsOneSentenceWithTheTopTitles() {
        let result = facts(F.fullSnapshot())
        #expect(result.summary == "My 2026 in Crucible: \(120.formatted()) hours watched in 2026, 100 plays, 40 days active. Most watched: Severance, Heat.")
    }

    @Test func summaryOmitsTheTitleLineWhenNothingRanked() {
        var snapshot = F.baseSnapshot()
        snapshot.topShows = []
        snapshot.topMovies = []
        let result = facts(snapshot)
        #expect(result.titles.isEmpty)
        #expect(result.summary == "My 2026 in Crucible: \(120.formatted()) hours watched in 2026, 100 plays, 40 days active.")
    }

    @Test func genresKeepTheTopFourAndTheHeatmapOnlyWhenThereIsActivity() {
        var snapshot = F.fullSnapshot()
        snapshot.genres = ["A", "B", "C", "D", "E"].enumerated().map { GenreStat(genre: $1, count: 10 - $0) }
        #expect(facts(snapshot).genres == ["A", "B", "C", "D"])
        #expect(facts(snapshot).heatmap != nil)
        snapshot.heatmap = []
        #expect(facts(snapshot).heatmap == nil)
    }
}

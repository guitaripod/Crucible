import Foundation
import Testing
@testable import CrucibleStats

struct StatsPageTests {
    private typealias F = StatsFixtures

    @Test func heroShowsEstimatedHoursWithTheCoverageNote() {
        let page = F.page(F.baseSnapshot())
        #expect(page.hero.value == 120)
        #expect(page.hero.unit == "hours")
        #expect(page.hero.detail == "watched in 2026 · estimate, 83% counted")
    }

    @Test func heroUsesTheSingularForOneHour() {
        let page = F.page(F.baseSnapshot(overview: F.makeOverview(estHours: 1.2)))
        #expect(page.hero.value == 1)
        #expect(page.hero.unit == "hour")
    }

    @Test func heroFallsBackToPlaysWhileRuntimesAreUnknown() {
        let unknown = F.page(F.baseSnapshot(overview: F.makeOverview(totalPlays: 7, estHours: nil)), range: .week)
        #expect(unknown.hero.value == 7)
        #expect(unknown.hero.unit == "plays")
        #expect(unknown.hero.detail == "watched in the last 7 days")

        let tiny = F.page(F.baseSnapshot(overview: F.makeOverview(totalPlays: 1, estHours: 0.3)), range: .month)
        #expect(tiny.hero.value == 1)
        #expect(tiny.hero.unit == "play")
        #expect(tiny.hero.detail == "watched in the last 30 days")
    }

    @Test func heroDetailNamesTheRange() {
        let all = F.page(F.baseSnapshot(overview: F.makeOverview(estHours: nil)), range: .allTime)
        #expect(all.hero.detail == "watched in total")
    }

    @Test func heroEyebrowIsTheVerdictOrAGenericLine() {
        #expect(F.page(F.baseSnapshot()).hero.eyebrow == "You're a Prime-Time Viewer")
        var silent = F.baseSnapshot()
        silent.hourHistogram = Array(repeating: 0, count: 24)
        #expect(F.page(silent).hero.eyebrow == "Your viewing")
        #expect(F.page(silent).clock.verdict.isEmpty)
    }

    @Test func heroSinceLineNamesTheFirstWatchedMonth() {
        #expect(F.page(F.baseSnapshot()).hero.since == "Your viewing, visualized")
        let since = F.unix(F.date(2023, 3, 10))
        let page = F.page(F.baseSnapshot(overview: F.makeOverview(memberSince: since)))
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        #expect(page.hero.since == "Watching since \(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(since))))")
    }

    @Test func verdictPicksTheDominantPattern() {
        var owl = F.baseSnapshot()
        owl.hourHistogram = F.hours([23: 6, 1: 4, 20: 10])
        #expect(F.page(owl).clock.verdict == "You're a Night Owl")

        var bird = F.baseSnapshot()
        bird.hourHistogram = F.hours([7: 8, 20: 10])
        #expect(F.page(bird).clock.verdict == "You're an Early Bird")

        var weekend = F.baseSnapshot()
        weekend.hourHistogram = F.hours([20: 10])
        weekend.weekdayHistogram = F.weekdays([0: 5, 6: 5])
        #expect(F.page(weekend).clock.verdict == "You're a Weekend Warrior")

        #expect(F.page(F.baseSnapshot()).clock.verdict == "You're a Prime-Time Viewer")
    }

    @Test func kpiTilesFollowTheOverview() {
        let page = F.page(F.baseSnapshot(overview: F.makeOverview(daysActive: 40, episodes: 1500, movies: 20, shows: 12, currentStreak: 3, longestStreak: 9)))
        #expect(page.tiles.map(\.key) == ["days", "streak", "shows", "movies", "episodes"])
        #expect(page.tiles.map(\.value) == ["40", "3", "12", "20", "1.5K"])
        #expect(page.tiles[1].caption == "days · best 9")
    }

    @Test func streakCaptionDropsTheBestWhenTheStreakIsTheBest() {
        let page = F.page(F.baseSnapshot(overview: F.makeOverview(currentStreak: 5, longestStreak: 5)))
        #expect(page.tiles[1].caption == "days")
    }

    @Test func firstTileCarriesTheWeeklySparkline() {
        var snapshot = F.baseSnapshot()
        snapshot.weeklySparkline = [3, 1, 4]
        let page = F.page(snapshot)
        #expect(page.tiles[0].sparkline == [3, 1, 4])
        #expect(page.tiles[1].sparkline.isEmpty)
    }

    @Test func longestBingeIsTheWidestSessionInHoursOrMinutes() throws {
        var snapshot = F.baseSnapshot()
        let start = F.unix(F.date(2026, 3, 1))
        snapshot.binges = [
            BingeSession(showTitle: "A", showRatingKey: nil, episodeCount: 3, startViewedAt: start, endViewedAt: start + 45 * 60),
            BingeSession(showTitle: "B", showRatingKey: nil, episodeCount: 4, startViewedAt: start, endViewedAt: start + 9 * 3600 + 20 * 60),
        ]
        let binge = try #require(F.page(snapshot).longestBinge)
        #expect(binge.value == "9 h")
        #expect(binge.date == Date(timeIntervalSince1970: TimeInterval(start)).formatted(.dateTime.month(.abbreviated).day()))
        let tile = try #require(F.page(snapshot).tiles.last)
        #expect(tile.key == "binge")
        #expect(tile.caption == binge.date)

        snapshot.binges = [BingeSession(showTitle: "A", showRatingKey: nil, episodeCount: 3, startViewedAt: start, endViewedAt: start + 45 * 60)]
        #expect(F.page(snapshot).longestBinge?.value == "45 min")
    }

    @Test func aBingeUnderAMinuteIsNotShown() {
        var snapshot = F.baseSnapshot()
        let start = F.unix(F.date(2026, 3, 1))
        snapshot.binges = [BingeSession(showTitle: "A", showRatingKey: nil, episodeCount: 3, startViewedAt: start, endViewedAt: start + 59)]
        let page = F.page(snapshot)
        #expect(page.longestBinge == nil)
        #expect(page.tiles.count == 5)
    }

    @Test func emptySnapshotHasNoSections() {
        let page = F.page(StatsSnapshot())
        #expect(page.isEmpty)
        #expect(page.sections.isEmpty)
        #expect(StatsPage.empty.isEmpty)
    }

    @Test func aFullSnapshotShowsEverySectionInScreenOrder() {
        let page = F.page(F.fullSnapshot())
        #expect(page.sections == [.hero, .kpis, .heatmap, .topShows, .topMovies, .clock, .momentum, .binges, .libraries, .genres, .onThisDay, .superlatives])
    }

    @Test func aBareSnapshotKeepsOnlyTheAlwaysOnSectionsAndThePendingTaste() {
        let page = F.page(F.baseSnapshot())
        #expect(page.sections == [.hero, .kpis, .clock, .genres])
    }

    @Test func tasteDisappearsOnceCoverageIsEnoughButNoGenresExist() {
        var snapshot = F.baseSnapshot()
        snapshot.enrichment.genreCoverage = 0.5
        #expect(!F.page(snapshot).sections.contains(.genres))
        snapshot.genres = [GenreStat(genre: "Drama", count: 1)]
        #expect(F.page(snapshot).sections.contains(.genres))
    }

    @Test func momentumAndLibrariesNeedTwoEntries() {
        var snapshot = F.fullSnapshot()
        snapshot.monthly = [MonthCount(monthEpoch: 2026 * 12, count: 4)]
        snapshot.libraries = [LibrarySlice(title: "TV", count: 80)]
        let page = F.page(snapshot)
        #expect(page.momentum == nil)
        #expect(!page.sections.contains(.momentum))
        #expect(!page.sections.contains(.libraries))
    }

    @Test func topShowsRankAgainstTheLeader() {
        var snapshot = F.fullSnapshot()
        snapshot.topShows = [
            ShowStat(ratingKey: "a", title: "A", thumb: nil, count: 20, watchedEpisodes: 18, leafCount: 20),
            ShowStat(ratingKey: "b", title: "B", thumb: "/b", count: 5, watchedEpisodes: nil, leafCount: nil),
            ShowStat(ratingKey: "c", title: "C", thumb: nil, count: 1, watchedEpisodes: 1, leafCount: 4),
        ]
        let rows = F.page(snapshot).topShows
        #expect(rows.map(\.rank) == [1, 2, 3])
        #expect(rows.map(\.valueText) == ["18 eps", "5 eps", "1 ep"])
        #expect(rows.map(\.fraction) == [1, 0.25, 0.05])
        #expect(rows[0].completion == 0.9)
        #expect(rows[1].completion == nil)
        #expect(rows[2].completion == 0.25)
    }

    @Test func genresRankAgainstTheLeaderAndCycleColours() {
        guard case .ranked(let rows) = F.page(F.fullSnapshot()).genres else {
            Issue.record("expected ranked genres")
            return
        }
        #expect(rows.map(\.title) == ["Drama", "Sci-Fi"])
        #expect(rows.map(\.valueText) == ["40", "10"])
        #expect(rows.map(\.fraction) == [1, 0.25])
        #expect(rows.map(\.colorIndex) == [0, 1])
        #expect(rows[0].accessibilityLabel == "Drama, 40 plays")
    }

    @Test func genresAreAPendingBarWhileEnrichmentRuns() {
        var snapshot = F.baseSnapshot()
        snapshot.enrichment.genreCoverage = 0.234
        guard case .pending(let pending) = F.page(snapshot).genres else {
            Issue.record("expected pending genres")
            return
        }
        #expect(pending.title == "Analyzing your taste…")
        #expect(pending.accessibilityLabel == "Analyzing your taste, 23 percent")
        #expect(pending.barFraction == 0.234)
    }

    @Test func pendingBarNeverReadsAsEmptyOrOverfull() {
        let none = StatsPage.GenresPending(title: "", progress: 0, accessibilityLabel: "")
        let over = StatsPage.GenresPending(title: "", progress: 4, accessibilityLabel: "")
        #expect(none.barFraction == 0.02)
        #expect(over.barFraction == 1)
    }

    @Test func momentumNamesThePeakMonth() throws {
        let momentum = try #require(F.page(F.fullSnapshot()).momentum)
        #expect(momentum.values == [10, 30])
        #expect(momentum.peakText == "Mar 2026")
        #expect(momentum.summary == "Plays per month. Peak in Mar 2026 with 30 plays.")
    }

    @Test func librariesBuildTheDonutAndTheLegend() {
        let libraries = F.page(F.fullSnapshot()).libraries
        #expect(libraries.segments.map(\.label) == ["TV", "Movies"])
        #expect(libraries.segments.map(\.colorIndex) == [0, 1])
        #expect(libraries.centerTitle == "100")
        #expect(libraries.centerSubtitle == "plays")
        #expect(libraries.legend.map(\.value) == ["80", "20"])
        #expect(libraries.accessibilitySummary == "Plays by library. TV, 80. Movies, 20")
    }

    @Test func theLegendStopsAtSixLibrariesButTheDonutKeepsAll() {
        var snapshot = F.fullSnapshot()
        snapshot.libraries = (1...8).map { LibrarySlice(title: "L\($0)", count: 1_000 * $0) }
        let libraries = F.page(snapshot).libraries
        #expect(libraries.segments.count == 8)
        #expect(libraries.legend.count == 6)
        #expect(libraries.centerTitle == "36K")
    }

    @Test func clockSummaryNamesTheBusiestHour() {
        var snapshot = F.baseSnapshot()
        snapshot.hourHistogram = F.hours([0: 3, 15: 9])
        #expect(F.page(snapshot).clock.accessibilitySummary == "Plays by hour of day. Busiest at 3 PM, 75 percent of plays.")
        snapshot.hourHistogram = F.hours([0: 4])
        #expect(F.page(snapshot).clock.accessibilitySummary == "Plays by hour of day. Busiest at 12 AM, 100 percent of plays.")
        snapshot.hourHistogram = Array(repeating: 0, count: 24)
        #expect(F.page(snapshot).clock.accessibilitySummary == "Plays by hour of day.")
    }

    @Test func postersCarryTheirCaptionsAndDestinations() {
        let page = F.page(F.fullSnapshot())
        #expect(page.topMovies.map(\.title) == ["Heat"])
        #expect(page.topMovies[0].subtitle == "2× watched")
        #expect(page.topMovies[0].destination == .movie(ratingKey: "m1"))
        #expect(page.onThisDay[0].title == "Severance")
        #expect(page.onThisDay[0].subtitle == "1 year ago")
        #expect(page.onThisDay[0].posterPath == "/t/e1")
        #expect(page.onThisDay[0].placeholderSymbol == "tv")
        #expect(page.onThisDay[0].destination == .episode(ratingKey: "e1", showRatingKey: "s1"))
    }

    @Test func heatmapUsesTheTodayOfTheClockItWasGiven() {
        let page = F.page(F.fullSnapshot())
        #expect(page.heatmap.lastDayEpoch == F.today)
        #expect(page.heatmap.cells.count == 2)
    }

    @Test func placeholdersExplainEachEmptyState() {
        #expect(StatsPlaceholder.forEmptyPage(syncedAtLeastOnce: false, librariesFiltered: true) == .loading)
        #expect(StatsPlaceholder.forEmptyPage(syncedAtLeastOnce: true, librariesFiltered: false) == .empty(filtered: false))
        #expect(StatsPlaceholder.forEmptyPage(syncedAtLeastOnce: true, librariesFiltered: true) == .empty(filtered: true))

        #expect(StatsPlaceholder.loading.title == "Building your statistics")
        #expect(StatsPlaceholder.loading.symbol == nil)
        #expect(StatsPlaceholder.empty(filtered: false).title == "No watch history yet")
        #expect(StatsPlaceholder.empty(filtered: true).title == "No plays in these libraries")
        #expect(StatsPlaceholder.empty(filtered: true).symbol == "chart.bar.xaxis")
        #expect(StatsPlaceholder.unavailable.title == "Statistics unavailable")
        #expect(StatsPlaceholder.unavailable.symbol == "exclamationmark.triangle")
    }
}

import Foundation
@testable import CrucibleStats

enum StatsFixtures {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static let time = StatsTime(calendar: utc)

    static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    static let now = date(2026, 6, 15)

    static var today: Int { time.todayDayEpoch(now: now) }

    static func hours(_ counts: [Int: Int]) -> [Int] {
        var result = Array(repeating: 0, count: 24)
        for (hour, count) in counts { result[hour] = count }
        return result
    }

    static func weekdays(_ counts: [Int: Int]) -> [Int] {
        var result = Array(repeating: 0, count: 7)
        for (index, count) in counts { result[index] = count }
        return result
    }

    static func unix(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970)
    }

    static func makeOverview(
        totalPlays: Int = 100,
        daysActive: Int = 40,
        episodes: Int = 80,
        movies: Int = 20,
        shows: Int = 12,
        currentStreak: Int = 3,
        longestStreak: Int = 3,
        estHours: Double? = 120.4,
        coverage: Double = 0.83,
        memberSince: Int? = nil
    ) -> StatsOverview {
        var overview = StatsOverview()
        overview.totalPlays = totalPlays
        overview.daysActive = daysActive
        overview.episodes = episodes
        overview.moviesWatched = movies
        overview.showsWatched = shows
        overview.currentStreak = currentStreak
        overview.longestStreak = longestStreak
        overview.estHours = estHours
        overview.coverage = coverage
        overview.memberSinceViewedAt = memberSince
        return overview
    }

    static func baseSnapshot(overview: StatsOverview = makeOverview()) -> StatsSnapshot {
        var snapshot = StatsSnapshot()
        snapshot.overview = overview
        snapshot.hourHistogram = hours([20: 10])
        snapshot.weekdayHistogram = weekdays([2: 4, 3: 4])
        return snapshot
    }

    static func page(_ snapshot: StatsSnapshot, range: StatsRange = .year) -> StatsPage {
        StatsPage(snapshot: snapshot, range: range, time: time, now: now)
    }

    static func fullSnapshot() -> StatsSnapshot {
        var snapshot = baseSnapshot()
        snapshot.weeklySparkline = [1, 2, 3]
        snapshot.heatmap = [DayCount(dayEpoch: today, count: 3), DayCount(dayEpoch: today - 1, count: 1)]
        snapshot.monthly = [MonthCount(monthEpoch: 2026 * 12 + 1, count: 10), MonthCount(monthEpoch: 2026 * 12 + 2, count: 30)]
        snapshot.topShows = [ShowStat(ratingKey: "s1", title: "Severance", thumb: "/t/s1", count: 20, watchedEpisodes: 18, leafCount: 20)]
        snapshot.topMovies = [MovieStat(ratingKey: "m1", title: "Heat", thumb: "/t/m1", count: 2, lastViewedAt: 1)]
        snapshot.libraries = [LibrarySlice(title: "TV", count: 80), LibrarySlice(title: "Movies", count: 20)]
        snapshot.binges = [BingeSession(showTitle: "Severance", showRatingKey: "s1", episodeCount: 5, startViewedAt: unix(date(2026, 3, 1)), endViewedAt: unix(date(2026, 3, 1, hour: 15)))]
        snapshot.genres = [GenreStat(genre: "Drama", count: 40), GenreStat(genre: "Sci-Fi", count: 10)]
        snapshot.onThisDay = [OnThisDayItem(ratingKey: "e1", type: "episode", title: "Hello", grandparentTitle: "Severance", grandparentRatingKey: "s1", thumb: "/t/e1", grandparentThumb: "/t/s1", yearsAgo: 1)]
        snapshot.superlatives = [Superlative(symbol: "moon", headline: "Night Owl", title: "Late", caption: "Most plays after midnight")]
        return snapshot
    }
}

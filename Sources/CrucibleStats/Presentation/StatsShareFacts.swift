import Foundation

/// The words and numbers of the "Share Your Year" poster, resolved from a page without any artwork so
/// the same facts can be laid out for any format. The iPhone adds the downloaded posters on top.
package struct StatsShareFacts: Sendable {
    package struct Figure: Hashable, Sendable {
        package let value: String
        package let label: String
    }

    package struct Title: Hashable, Sendable {
        package let rank: Int
        package let name: String
        package let caption: String
        package let thumb: String?
        package let placeholderSymbol: String
    }

    package let period: String
    package let shareTitle: String
    package let eyebrow: String
    package let heroValue: String
    package let heroUnit: String
    package let heroDetail: String
    package let figures: [Figure]
    package let titles: [Title]
    package let genres: [String]
    package let heatmap: HeatmapModel?
    package let summary: String

    package init(page: StatsPage, time: StatsTime = StatsTime(), now: Date = Date()) {
        let overview = page.snapshot.overview
        let hero = page.hero
        let year = time.calendar.component(.year, from: now)
        let titles = Self.rankedTitles(in: page.snapshot)
        let value = hero.value.formatted()
        let detail = hero.detail.components(separatedBy: " · ").first ?? hero.detail
        let headline = Self.headline(page.range, year: year)

        period = Self.period(page.range, year: year)
        shareTitle = headline
        eyebrow = hero.eyebrow
        heroValue = value
        heroUnit = hero.unit
        heroDetail = detail
        figures = [
            Figure(value: StatsFormat.abbreviatedCount(overview.totalPlays), label: "Plays"),
            Figure(value: "\(overview.daysActive)", label: "Days Active"),
            Figure(value: "\(overview.longestStreak)", label: "Day Streak"),
            page.longestBinge.map { Figure(value: $0.value.replacingOccurrences(of: " ", with: ""), label: "Longest Binge") }
                ?? Figure(value: StatsFormat.abbreviatedCount(overview.showsWatched + overview.moviesWatched), label: "Titles"),
        ]
        self.titles = titles
        genres = page.snapshot.genres.prefix(4).map(\.genre)
        heatmap = page.heatmap.cells.isEmpty ? nil : page.heatmap
        summary = "\(headline): \(value) \(hero.unit) \(detail), \(overview.totalPlays) plays, \(overview.daysActive) days active."
            + (titles.isEmpty ? "" : " Most watched: \(titles.map(\.name).joined(separator: ", ")).")
    }

    private static func period(_ range: StatsRange, year: Int) -> String {
        switch range {
        case .week: return "LAST 7 DAYS"
        case .month: return "LAST 30 DAYS"
        case .year: return "\(year)"
        case .allTime: return "ALL TIME"
        }
    }

    private static func headline(_ range: StatsRange, year: Int) -> String {
        switch range {
        case .week: return "My Week in Crucible"
        case .month: return "My Month in Crucible"
        case .year: return "My \(year) in Crucible"
        case .allTime: return "My Crucible, All Time"
        }
    }

    /// The three most-played titles across shows and movies. Ties go to shows.
    private static func rankedTitles(in snapshot: StatsSnapshot) -> [Title] {
        struct Entry {
            let name: String
            let thumb: String?
            let count: Int
            let isShow: Bool
        }
        let shows = snapshot.topShows.map { Entry(name: $0.title, thumb: $0.thumb, count: $0.count, isShow: true) }
        let movies = snapshot.topMovies.map { Entry(name: $0.title, thumb: $0.thumb, count: $0.count, isShow: false) }
        let top = (shows + movies).enumerated()
            .sorted { ($0.element.count, $1.offset) > ($1.element.count, $0.offset) }
            .prefix(3)
            .map(\.element)
        return top.enumerated().map { index, entry in
            Title(
                rank: index + 1,
                name: entry.name,
                caption: entry.isShow
                    ? "\(entry.count) \(entry.count == 1 ? "episode" : "episodes")"
                    : (entry.count == 1 ? "Movie" : "Movie · \(entry.count) plays"),
                thumb: entry.thumb,
                placeholderSymbol: entry.isShow ? "tv" : "film"
            )
        }
    }
}

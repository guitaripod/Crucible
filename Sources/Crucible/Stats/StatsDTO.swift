import Foundation

struct StatsOverview: Hashable {
    var totalPlays = 0
    var daysActive = 0
    var episodes = 0
    var moviesWatched = 0
    var showsWatched = 0
    var currentStreak = 0
    var longestStreak = 0
    var estHours: Double?
    var coverage: Double = 0
    var memberSinceViewedAt: Int?
    var firstTitle: String?

    var isEmpty: Bool { totalPlays == 0 }
}

struct DayCount: Hashable {
    let dayEpoch: Int
    let count: Int
}

struct MonthCount: Hashable {
    let monthEpoch: Int
    let count: Int
}

struct ShowStat: Hashable {
    let ratingKey: String
    let title: String
    let thumb: String?
    let count: Int
    var watchedEpisodes: Int?
    var leafCount: Int?

    var completion: Double? {
        guard let leafCount, leafCount > 0, let watchedEpisodes else { return nil }
        return min(1.0, Double(watchedEpisodes) / Double(leafCount))
    }
}

struct MovieStat: Hashable {
    let ratingKey: String
    let title: String
    let thumb: String?
    let count: Int
    let lastViewedAt: Int
}

struct LibrarySlice: Hashable {
    let title: String
    let count: Int
}

struct GenreStat: Hashable {
    let genre: String
    let count: Int
}

struct BingeSession: Hashable {
    let showTitle: String
    let showRatingKey: String?
    let episodeCount: Int
    let startViewedAt: Int
    let endViewedAt: Int
}

struct OnThisDayItem: Hashable {
    let ratingKey: String
    let type: String?
    let title: String
    let grandparentTitle: String?
    let grandparentRatingKey: String?
    let thumb: String?
    let grandparentThumb: String?
    let yearsAgo: Int
}

struct HeatmapCell: Hashable {
    let column: Int
    let row: Int
    let level: Int
    let dayEpoch: Int
    let count: Int
}

struct HeatmapModel: Hashable {
    var cells: [HeatmapCell] = []
    var columns: Int = 0
    var firstDayEpoch: Int = 0
    var lastDayEpoch: Int = 0
    var monthLabels: [Int: String] = [:]
}

struct DonutSegment: Hashable {
    let label: String
    let value: Int
    let colorIndex: Int
}

struct Superlative: Hashable {
    let symbol: String
    let headline: String
    let title: String
    let caption: String
}

struct EnrichmentProgress: Hashable {
    var runtimeCoverage: Double = 0
    var genreCoverage: Double = 0
    var isRunning: Bool = false
}

/// The full snapshot the StatisticsViewController renders for one range selection.
struct StatsSnapshot {
    var overview = StatsOverview()
    var weeklySparkline: [Int] = []
    var heatmap: [DayCount] = []
    var hourHistogram: [Int] = Array(repeating: 0, count: 24)
    var weekdayHistogram: [Int] = Array(repeating: 0, count: 7)
    var monthly: [MonthCount] = []
    var topShows: [ShowStat] = []
    var topMovies: [MovieStat] = []
    var libraries: [LibrarySlice] = []
    var binges: [BingeSession] = []
    var genres: [GenreStat] = []
    var onThisDay: [OnThisDayItem] = []
    var superlatives: [Superlative] = []
    var enrichment = EnrichmentProgress()

    var isEmpty: Bool { overview.isEmpty }
}

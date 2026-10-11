import Foundation

package struct StatsOverview: Hashable, Sendable {
    package var totalPlays = 0
    package var daysActive = 0
    package var episodes = 0
    package var moviesWatched = 0
    package var showsWatched = 0
    package var currentStreak = 0
    package var longestStreak = 0
    package var estHours: Double?
    package var coverage: Double = 0
    package var memberSinceViewedAt: Int?
    var firstTitle: String?

    package var isEmpty: Bool { totalPlays == 0 }
}

package struct DayCount: Hashable, Sendable {
    package let dayEpoch: Int
    package let count: Int
}

package struct MonthCount: Hashable, Sendable {
    package let monthEpoch: Int
    package let count: Int
}

package struct ShowStat: Hashable, Sendable {
    package let ratingKey: String
    package let title: String
    package let thumb: String?
    package let count: Int
    package var watchedEpisodes: Int?
    package var leafCount: Int?

    package var completion: Double? {
        guard let leafCount, leafCount > 0, let watchedEpisodes else { return nil }
        return min(1.0, Double(watchedEpisodes) / Double(leafCount))
    }
}

package struct MovieStat: Hashable, Sendable {
    package let ratingKey: String
    package let title: String
    package let thumb: String?
    package let count: Int
    package let lastViewedAt: Int
}

package struct LibrarySlice: Hashable, Sendable {
    package let title: String
    package let count: Int
}

package struct GenreStat: Hashable, Sendable {
    package let genre: String
    package let count: Int
}

package struct BingeSession: Hashable, Sendable {
    package let showTitle: String
    package let showRatingKey: String?
    package let episodeCount: Int
    package let startViewedAt: Int
    package let endViewedAt: Int
}

package struct OnThisDayItem: Hashable, Sendable {
    package let ratingKey: String
    package let type: String?
    package let title: String
    package let grandparentTitle: String?
    package let grandparentRatingKey: String?
    package let thumb: String?
    package let grandparentThumb: String?
    package let yearsAgo: Int
}

package struct HeatmapCell: Hashable, Sendable {
    package let column: Int
    package let row: Int
    package let level: Int
    package let dayEpoch: Int
    package let count: Int
}

package struct HeatmapModel: Hashable, Sendable {
    package var cells: [HeatmapCell] = []
    package var columns: Int = 0
    package var firstDayEpoch: Int = 0
    package var lastDayEpoch: Int = 0
    package var monthLabels: [Int: String] = [:]

    package init(
        cells: [HeatmapCell] = [],
        columns: Int = 0,
        firstDayEpoch: Int = 0,
        lastDayEpoch: Int = 0,
        monthLabels: [Int: String] = [:]
    ) {
        self.cells = cells
        self.columns = columns
        self.firstDayEpoch = firstDayEpoch
        self.lastDayEpoch = lastDayEpoch
        self.monthLabels = monthLabels
    }
}

package struct DonutSegment: Hashable, Sendable {
    package let label: String
    package let value: Int
    package let colorIndex: Int

    package init(label: String, value: Int, colorIndex: Int) {
        self.label = label
        self.value = value
        self.colorIndex = colorIndex
    }
}

package struct Superlative: Hashable, Sendable {
    package let symbol: String
    package let headline: String
    package let title: String
    package let caption: String
}

package struct EnrichmentProgress: Hashable, Sendable {
    var runtimeCoverage: Double = 0
    package var genreCoverage: Double = 0
    var isRunning: Bool = false
}

/// The aggregates every Statistics screen renders for one range selection.
package struct StatsSnapshot: Equatable, Sendable {
    package var overview = StatsOverview()
    package var weeklySparkline: [Int] = []
    package var heatmap: [DayCount] = []
    package var hourHistogram: [Int] = Array(repeating: 0, count: 24)
    package var weekdayHistogram: [Int] = Array(repeating: 0, count: 7)
    package var monthly: [MonthCount] = []
    package var topShows: [ShowStat] = []
    package var topMovies: [MovieStat] = []
    package var libraries: [LibrarySlice] = []
    package var binges: [BingeSession] = []
    package var genres: [GenreStat] = []
    package var onThisDay: [OnThisDayItem] = []
    package var superlatives: [Superlative] = []

    package var enrichment = EnrichmentProgress()

    package init() {}

    package var isEmpty: Bool { overview.isEmpty }
}

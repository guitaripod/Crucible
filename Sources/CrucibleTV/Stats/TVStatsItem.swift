import CrucibleStats

/// The sections of the Statistics screen, top to bottom as they appear on Apple TV.
enum TVStatsSection: Hashable, CaseIterable {
    case controls, hero, kpis, heatmap, topShows, topMovies, clock, momentum, libraries, binges, genres, onThisDay, superlatives

    /// The data section of the page behind it; the controls row has none.
    var pageSection: StatsPageSection? {
        switch self {
        case .controls: nil
        case .hero: .hero
        case .kpis: .kpis
        case .heatmap: .heatmap
        case .topShows: .topShows
        case .topMovies: .topMovies
        case .clock: .clock
        case .momentum: .momentum
        case .libraries: .libraries
        case .binges: .binges
        case .genres: .genres
        case .onThisDay: .onThisDay
        case .superlatives: .superlatives
        }
    }

    var headerTitle: String? {
        switch self {
        case .topShows: "Top Shows"
        case .topMovies: "Top Movies"
        case .binges: "Binges & Streaks"
        case .onThisDay: "On This Day"
        case .superlatives: "Wrapped Moments"
        default: nil
        }
    }
}

/// One cell of the screen. Panels carry a version so they redraw when a new page arrives.
enum TVStatsItem: Hashable {
    case controls
    case hero(Int)
    case tile(StatsPage.Tile)
    case panel(TVStatsSection, Int)
    case poster(TVStatsSection, TVCardItem, StatsDestination)
    case binge(BingeSession, Int)
    case wrapped(Superlative)
}

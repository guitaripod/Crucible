import Foundation

/// What Crucible Pro unlocks, in the order the paywall lists it. Playback, browsing, search and the
/// whole Apple TV app are never in this list.
package enum ProFeature: String, CaseIterable, Sendable {
    case unlimitedDownloads
    case fullStatistics
    case yearInReviewPoster
    case topShelf

    package var title: String {
        switch self {
        case .unlimitedDownloads: return "Unlimited downloads"
        case .fullStatistics: return "Full Statistics"
        case .yearInReviewPoster: return "Year in Review poster"
        case .topShelf: return "Top Shelf"
        }
    }

    package var summary: String {
        switch self {
        case .unlimitedDownloads: return "Download whole seasons, queue as many titles as you like and keep the next episodes ready."
        case .fullStatistics: return "Every range, the library filter, patterns, binges and taste, built from your own Plex history."
        case .yearInReviewPoster: return "Preview and share your year as a Story or Square poster."
        case .topShelf: return "Continue Watching and Up Next on the Apple TV Home screen."
        }
    }

    package var symbol: String {
        switch self {
        case .unlimitedDownloads: return "arrow.down.circle"
        case .fullStatistics: return "chart.bar.xaxis"
        case .yearInReviewPoster: return "sparkles.rectangle.stack"
        case .topShelf: return "tv"
        }
    }

    /// The features worth showing on the current platform: downloads exist only on the iPhone and Top Shelf only on Apple TV.
    package static func listed(isTV: Bool = AppPlatform.isTV) -> [ProFeature] {
        allCases.filter { feature in
            switch feature {
            case .unlimitedDownloads: return !isTV
            case .topShelf: return isTV
            case .fullStatistics, .yearInReviewPoster: return true
            }
        }
    }
}

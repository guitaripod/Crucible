import CrucibleCore
import Foundation

/// Where opening a statistics poster, row or card leads. Screens map it to their own detail screens.
package enum StatsDestination: Hashable, Sendable {
    case movie(ratingKey: String)
    case episode(ratingKey: String, showRatingKey: String?)
    case show(ratingKey: String)

    package init(_ item: OnThisDayItem) {
        switch item.type {
        case "episode": self = .episode(ratingKey: item.ratingKey, showRatingKey: item.grandparentRatingKey)
        case "show": self = .show(ratingKey: item.ratingKey)
        default: self = .movie(ratingKey: item.ratingKey)
        }
    }
}

/// A poster tile of the statistics screens: artwork path, two caption lines, the SF Symbol shown while
/// the artwork loads, and where selecting it goes.
package struct StatsPoster: Hashable, Sendable {
    package let posterPath: String?
    package let title: String
    package let subtitle: String?
    package let placeholderSymbol: String
    package let destination: StatsDestination

    /// A Top Movies tile: the title, with "N× watched" when it was played more than once.
    package init(_ movie: MovieStat) {
        posterPath = movie.thumb
        title = movie.title
        subtitle = movie.count > 1 ? "\(movie.count)× watched" : nil
        placeholderSymbol = "film"
        destination = .movie(ratingKey: movie.ratingKey)
    }

    /// An On This Day tile: the show (or movie) title with how many years ago it was watched.
    package init(onThisDay item: OnThisDayItem) {
        posterPath = item.thumb ?? item.grandparentThumb
        title = item.grandparentTitle ?? item.title
        subtitle = item.yearsAgo == 1 ? "1 year ago" : "\(item.yearsAgo) years ago"
        placeholderSymbol = item.type == "episode" ? "tv" : "film"
        destination = StatsDestination(item)
    }

    /// A tile of the day drill-down: episodes show the show title over the episode title.
    package init(playedOnDay item: OnThisDayItem) {
        posterPath = item.thumb ?? item.grandparentThumb
        if item.type == "episode" {
            title = item.grandparentTitle ?? item.title
            subtitle = item.title
            placeholderSymbol = "tv"
        } else {
            title = item.title
            subtitle = nil
            placeholderSymbol = "film"
        }
        destination = StatsDestination(item)
    }
}

extension BingeSession {
    /// The session's last play as a relative date ("3 days ago").
    package var endedCaption: String? {
        Formatters.unixRelativeDate(endViewedAt)
    }
}

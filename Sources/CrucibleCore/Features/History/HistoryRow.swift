import Foundation

package struct HistoryRowPresentation: Hashable, Sendable {
    package let posterPath: String?
    package let title: String
    package let subtitle: String
    package let timeText: String?
}

package enum HistoryDestination: Hashable, Sendable {
    case episode(ratingKey: String, showRatingKey: String?, seasonRatingKey: String?)
    case show(ratingKey: String)
    case movie(ratingKey: String)
}

extension HistoryItem {
    /// Episodes read as the show with an "S2 · E4 · Episode title" line and the show's poster; everything
    /// else reads as its own title with a "Movie" or "Show" line.
    package var row: HistoryRowPresentation {
        let isEpisode = type == "episode"
        var subtitleParts = [String]()
        if isEpisode {
            if let parentIndex { subtitleParts.append("S\(parentIndex)") }
            if let index { subtitleParts.append("E\(index)") }
            subtitleParts.append(title)
        } else {
            subtitleParts.append(type == "show" ? "Show" : "Movie")
        }
        return HistoryRowPresentation(
            posterPath: isEpisode ? (grandparentThumb ?? thumb) : thumb,
            title: isEpisode ? (grandparentTitle ?? title) : title,
            subtitle: subtitleParts.joined(separator: " · "),
            timeText: HistoryDay.timeText(viewedAt)
        )
    }

    /// Where selecting the row leads. Anything that is not an episode or a show opens as a movie.
    package var destination: HistoryDestination {
        switch type {
        case "episode":
            return .episode(ratingKey: ratingKey, showRatingKey: grandparentRatingKey, seasonRatingKey: parentRatingKey)
        case "show":
            return .show(ratingKey: ratingKey)
        default:
            return .movie(ratingKey: ratingKey)
        }
    }
}

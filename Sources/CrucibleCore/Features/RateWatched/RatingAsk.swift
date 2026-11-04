import Foundation

/// One title the viewer is asked to rate because they just watched it: a movie they finished, or a show whose season they
/// finished, caught up with, or kept watching.
package struct RatingAsk: Hashable, Sendable, Identifiable {
    package enum Reason: Hashable, Sendable {
        case finishedMovie
        case finishedSeason(Int?)
        case caughtUp
        case watchedEpisodes(Int)

        /// A stable name for the reason, so a reminder already sent for it is not sent again.
        package var key: String {
            switch self {
            case .finishedMovie: return "movie"
            case .finishedSeason(let season): return "season-\(season ?? 0)"
            case .caughtUp: return "caught-up"
            case .watchedEpisodes: return "episodes"
            }
        }
    }

    package let ratingKey: String
    package let mediaType: String
    package let title: String
    package let posterPath: String?
    package let reason: Reason
    package let finishedAt: Date

    package init(ratingKey: String, mediaType: String, title: String, posterPath: String?, reason: Reason, finishedAt: Date) {
        self.ratingKey = ratingKey
        self.mediaType = mediaType
        self.title = title
        self.posterPath = posterPath
        self.reason = reason
        self.finishedAt = finishedAt
    }

    package var id: String { ratingKey }

    package var isShow: Bool { mediaType == "show" }

    /// The line under the poster: why this title is being asked about.
    package func caption(now: Date) -> String {
        switch reason {
        case .finishedMovie:
            return RatingAskCopy.finished(at: finishedAt, now: now)
        case .finishedSeason(let season?):
            return String(localized: "Season \(season) finished", comment: "Caption under a show the viewer just finished a season of, e.g. Season 2 finished")
        case .finishedSeason(nil):
            return String(localized: "Season finished", comment: "Caption under a show the viewer just finished a season of, when the season number is unknown")
        case .caughtUp:
            return String(localized: "All caught up", comment: "Caption under a show whose every available episode the viewer has now watched")
        case .watchedEpisodes(let count):
            return String(localized: "\(count) episodes watched", comment: "Caption under a show the viewer has been watching, e.g. 4 episodes watched")
        }
    }
}

/// Copy for asking the viewer to rate what they watched.
package enum RatingAskCopy {
    package static let rowTitle = String(localized: "Rate What You Watched", comment: "Title of the row of recently finished titles the viewer has not rated yet")
    package static let notNow = String(localized: "Not Now", comment: "Menu item that hides a title from the Rate What You Watched row")

    package static func question(for ask: RatingAsk) -> String {
        String(localized: "How was \(ask.title)?", comment: "Question asking the viewer to rate a title they just finished, e.g. How was Dune?")
    }

    /// When a movie was finished, short enough for the line under a poster: "Yesterday", "3 days ago".
    package static func finished(at date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Formatters.interfaceLocale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .short
        formatter.formattingContext = .beginningOfSentence
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
}

/// Which finished titles to ask about. A movie is asked about once it is finished. A show is asked about, once, when the
/// viewer closes a season, catches up, or has watched a few episodes, so a binge is one question, not one per episode.
/// A title already rated is never asked about, and one the viewer waved away comes back only for a finish after that.
package enum RatingAskRule {
    package static let window: TimeInterval = 21 * 86_400
    package static let episodesForShow = 3
    package static let maxAsks = 12

    package static func asks(
        from titles: [FinishedTitle],
        rated: Set<String>,
        dismissed: [String: Date],
        posters: [String: String] = [:],
        now: Date
    ) -> [RatingAsk] {
        let recent = titles.filter { $0.finishedAt >= now.addingTimeInterval(-window) && $0.finishedAt <= now.addingTimeInterval(60) }
        let poster = { (key: String, fallback: String?) in posters[key] ?? fallback }
        var asks = [RatingAsk]()
        for movie in recent where movie.kind == .movie {
            guard !rated.contains(movie.ratingKey), isFresh(movie.finishedAt, dismissed: dismissed[movie.ratingKey]),
                  !asks.contains(where: { $0.ratingKey == movie.ratingKey }) else { continue }
            asks.append(RatingAsk(
                ratingKey: movie.ratingKey,
                mediaType: "movie",
                title: movie.title,
                posterPath: poster(movie.ratingKey, movie.posterPath),
                reason: .finishedMovie,
                finishedAt: movie.finishedAt
            ))
        }
        let episodes = recent.filter { $0.kind == .episode && $0.showRatingKey != nil }
        for (show, all) in Dictionary(grouping: episodes, by: { $0.showRatingKey ?? "" }) {
            guard !rated.contains(show) else { continue }
            let fresh = all.filter { isFresh($0.finishedAt, dismissed: dismissed[show]) }
            guard let reason = showReason(fresh), let latest = fresh.max(by: { $0.finishedAt < $1.finishedAt }) else { continue }
            asks.append(RatingAsk(
                ratingKey: show,
                mediaType: "show",
                title: latest.showTitle ?? latest.title,
                posterPath: poster(show, latest.showPosterPath ?? latest.posterPath),
                reason: reason,
                finishedAt: latest.finishedAt
            ))
        }
        return Array(asks.sorted { $0.finishedAt == $1.finishedAt ? $0.ratingKey < $1.ratingKey : $0.finishedAt > $1.finishedAt }.prefix(maxAsks))
    }

    private static func isFresh(_ finishedAt: Date, dismissed: Date?) -> Bool {
        guard let dismissed else { return true }
        return finishedAt > dismissed
    }

    /// Caught up beats a closed season, which beats a run of episodes.
    private static func showReason(_ episodes: [FinishedTitle]) -> RatingAsk.Reason? {
        if episodes.contains(where: \.endedShow) { return .caughtUp }
        if let closing = episodes.filter(\.endedSeason).max(by: { $0.finishedAt < $1.finishedAt }) {
            return .finishedSeason(closing.seasonNumber)
        }
        let count = Set(episodes.map(\.ratingKey)).count
        return count >= episodesForShow ? .watchedEpisodes(count) : nil
    }
}

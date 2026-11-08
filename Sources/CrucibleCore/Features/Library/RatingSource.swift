import Foundation

/// Where a Plex rating comes from, read from the image name Plex's agent attaches to it.
package enum RatingSource: String, Sendable, Equatable {
    case rottenTomatoesCritics
    case rottenTomatoesAudience
    case imdb
    case tmdb

    /// The source behind a `ratingImage` or `audienceRatingImage`, or nil for one Crucible does not know.
    package init?(plexImage: String?) {
        guard let image = plexImage?.lowercased() else { return nil }
        if image.hasPrefix("rottentomatoes://") {
            self = image.contains("upright") || image.contains("spilled") ? .rottenTomatoesAudience : .rottenTomatoesCritics
        } else if image.hasPrefix("imdb://") {
            self = .imdb
        } else if image.hasPrefix("themoviedb://") {
            self = .tmdb
        } else {
            return nil
        }
    }

    /// The sort option's name when a library's ratings come from this source.
    package var sortTitle: String {
        switch self {
        case .rottenTomatoesCritics: return String(localized: "Rotten Tomatoes", comment: "Sort option: by the Rotten Tomatoes critics score")
        case .rottenTomatoesAudience: return String(localized: "Audience Score", comment: "Sort option: by the Rotten Tomatoes audience score")
        case .imdb: return String(localized: "IMDb Rating", comment: "Sort option: by IMDb rating")
        case .tmdb: return String(localized: "TMDB Rating", comment: "Sort option: by TMDB rating")
        }
    }
}

/// The rating sources each library's titles carry, learned from the titles a grid loads, so its sort menu can name them.
@MainActor
package final class LibraryRatingSources {
    package static let shared = LibraryRatingSources()

    package struct Sources: Equatable, Sendable {
        package var critic: RatingSource?
        package var audience: RatingSource?

        package init(critic: RatingSource? = nil, audience: RatingSource? = nil) {
            self.critic = critic
            self.audience = audience
        }
    }

    private var bySection: [String: Sources] = [:]

    package func sources(for section: String) -> Sources {
        bySection[section] ?? Sources()
    }

    /// Learns `section`'s sources from loaded titles; returns whether anything new was learned.
    @discardableResult
    package func note(_ items: [PlexMetadata], section: String) -> Bool {
        var sources = bySection[section] ?? Sources()
        let before = sources
        if sources.critic == nil { sources.critic = items.lazy.compactMap { RatingSource(plexImage: $0.ratingImage) }.first }
        if sources.audience == nil { sources.audience = items.lazy.compactMap { RatingSource(plexImage: $0.audienceRatingImage) }.first }
        bySection[section] = sources
        return sources != before
    }
}

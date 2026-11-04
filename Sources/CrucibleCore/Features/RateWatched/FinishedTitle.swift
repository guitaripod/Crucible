import Foundation

/// A movie or episode the viewer watched to its end on this device, as the player saw it finish. It is the raw material for
/// asking the viewer to rate what they watched; nothing here is sent anywhere.
package struct FinishedTitle: Codable, Hashable, Sendable, Identifiable {
    package enum Kind: String, Codable, Sendable {
        case movie
        case episode
    }

    package let ratingKey: String
    package let kind: Kind
    package let title: String
    package let showTitle: String?
    package let showRatingKey: String?
    package let seasonNumber: Int?
    package let episodeNumber: Int?
    package let posterPath: String?
    package let showPosterPath: String?
    package let finishedAt: Date
    /// No episode came after this one: the viewer has caught up with everything the server has.
    package let endedShow: Bool
    /// The next episode belongs to another season, so this one closed a season.
    package let endedSeason: Bool

    package init(
        ratingKey: String,
        kind: Kind,
        title: String,
        showTitle: String? = nil,
        showRatingKey: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        posterPath: String? = nil,
        showPosterPath: String? = nil,
        finishedAt: Date,
        endedShow: Bool = false,
        endedSeason: Bool = false
    ) {
        self.ratingKey = ratingKey
        self.kind = kind
        self.title = title
        self.showTitle = showTitle
        self.showRatingKey = showRatingKey
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.posterPath = posterPath
        self.showPosterPath = showPosterPath
        self.finishedAt = finishedAt
        self.endedShow = endedShow
        self.endedSeason = endedSeason
    }

    package var id: String { ratingKey }

    /// The title a rating of this finish is about: the movie itself, or the show an episode belongs to.
    package var ratedKey: String? {
        switch kind {
        case .movie: return ratingKey
        case .episode: return showRatingKey
        }
    }
}

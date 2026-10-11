import Foundation

/// Where a tap on a detail screen leads, independent of how the platform presents it.
package enum DetailRoute: Hashable, Sendable {
    case show(ratingKey: String, initialSeasonKey: String?)
    case item(ratingKey: String, mediaType: String, showRatingKey: String?, seasonRatingKey: String?)

    /// A poster in a "More Like This" shelf: shows open the show screen, everything else the item screen.
    package static func related(_ related: PlexMetadata) -> DetailRoute {
        if related.mediaType == "show" {
            return .show(ratingKey: related.id, initialSeasonKey: nil)
        }
        return .item(
            ratingKey: related.id,
            mediaType: related.mediaType,
            showRatingKey: related.grandparentRatingKey,
            seasonRatingKey: related.parentRatingKey
        )
    }

    /// An episode picked from a show's episode shelf, or the next episode after the one on screen.
    package static func episode(_ episode: PlexMetadata, showRatingKey: String?, seasonRatingKey: String?) -> DetailRoute {
        .item(ratingKey: episode.id, mediaType: "episode", showRatingKey: showRatingKey, seasonRatingKey: seasonRatingKey)
    }
}

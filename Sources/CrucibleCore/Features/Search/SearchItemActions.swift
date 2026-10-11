package enum SearchDestination: Equatable, Sendable {
    case movie(ratingKey: String)
    case show(ratingKey: String, initialSeasonKey: String?)
    case episode(ratingKey: String, showRatingKey: String?, seasonRatingKey: String?)

    /// The detail screen that opening a library item leads to. Seasons open their show on that season.
    package init(item: PlexMetadata) {
        switch item.mediaType {
        case "show":
            self = .show(ratingKey: item.id, initialSeasonKey: nil)
        case "season":
            self = .show(ratingKey: item.parentRatingKey ?? item.id, initialSeasonKey: item.id)
        case "episode":
            self = .episode(ratingKey: item.id, showRatingKey: item.grandparentRatingKey, seasonRatingKey: item.parentRatingKey)
        default:
            self = .movie(ratingKey: item.id)
        }
    }
}

package enum SearchItemActions {
    package static func isPlayable(_ item: PlexMetadata) -> Bool {
        item.mediaType == "movie" || item.mediaType == "episode"
    }

    package static func playTitle(for item: PlexMetadata) -> String {
        item.positionSecs > 0 ? "Resume" : "Play"
    }

    /// The show an episode or season belongs to, for the Go to Show action.
    package static func showKey(for item: PlexMetadata) -> String? {
        switch item.mediaType {
        case "episode": return item.grandparentRatingKey
        case "season": return item.parentRatingKey
        default: return nil
        }
    }

    package static func watchedTitle(for item: PlexMetadata) -> String {
        item.isWatched ? "Mark Unwatched" : "Mark Watched"
    }

    /// Flips the item's watched state on the server and drops the API cache so lists refetch it.
    package static func toggleWatched(_ item: PlexMetadata, api: APIClient) async {
        if item.isWatched {
            try? await api.requestVoid(.unscrobble(ratingKey: item.id))
        } else {
            try? await api.requestVoid(.scrobble(ratingKey: item.id))
        }
        await api.invalidateCache()
    }
}

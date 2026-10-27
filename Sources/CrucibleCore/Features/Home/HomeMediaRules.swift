import Foundation

/// Where a Home card's detail screen lives.
package enum HomeDetailRoute: Hashable, Sendable {
    case show(ratingKey: String, initialSeasonKey: String?)
    case media(ratingKey: String, mediaType: String, showRatingKey: String?, seasonRatingKey: String?)
}

/// The watched/unwatched change a long-press menu offers for a card.
package struct HomeWatchedToggle: Hashable, Sendable {
    package let ratingKey: String
    package let isWatched: Bool

    package var title: String { WatchedService.title(isWatched: isWatched) }

    /// The state the toggle moves the title to.
    package var targetWatched: Bool { !isWatched }

    package func perform(using api: APIClient) async throws {
        try await WatchedService.setWatched(targetWatched, ratingKey: ratingKey, api: api)
    }
}

/// Pure decisions about a Home card that both platforms share.
package enum HomeMediaRules {
    package static func isUnwatched(_ item: PlexMetadata) -> Bool {
        switch item.mediaType {
        case "show", "season":
            guard let leaves = item.leafCount, leaves > 0 else { return false }
            return (item.viewedLeafCount ?? 0) < leaves
        default:
            return !item.isWatched && item.resumeSecs == 0
        }
    }

    package static func isPlayable(_ item: PlexMetadata) -> Bool {
        item.mediaType == "movie" || item.mediaType == "episode" || item.mediaType == "clip"
    }

    /// Episodes still to watch in a show or season; nil for anything else or when nothing is left.
    package static func unwatchedCount(_ item: PlexMetadata) -> Int? {
        guard item.mediaType == "show" || item.mediaType == "season",
              let leaves = item.leafCount, leaves > 0 else { return nil }
        let remaining = leaves - (item.viewedLeafCount ?? 0)
        return remaining > 0 ? remaining : nil
    }

    /// Shows and seasons count as watched once no episode is left; everything else follows its view count.
    package static func isWatched(_ item: PlexMetadata) -> Bool {
        item.mediaType == "show" || item.mediaType == "season" ? !isUnwatched(item) : item.isWatched
    }

    package static func watchedToggle(for item: PlexMetadata) -> HomeWatchedToggle {
        HomeWatchedToggle(ratingKey: item.id, isWatched: isWatched(item))
    }

    package static func isResuming(_ item: PlexMetadata) -> Bool {
        item.resumeSecs > 0
    }

    /// "Resume" once playback has started, "Play" otherwise.
    package static func playTitle(for item: PlexMetadata) -> String {
        isResuming(item) ? "Resume" : "Play"
    }

    /// Shows and seasons have no file to download.
    package static func isDownloadable(_ item: PlexMetadata) -> Bool {
        item.mediaType != "show" && item.mediaType != "season"
    }

    /// The show an episode or season belongs to, for a "Go to Show" action.
    package static func showRatingKey(for item: PlexMetadata) -> String? {
        switch item.mediaType {
        case "episode": return item.grandparentRatingKey
        case "season": return item.parentRatingKey
        default: return nil
        }
    }

    package static func detailRoute(for item: PlexMetadata) -> HomeDetailRoute {
        switch item.mediaType {
        case "show":
            return .show(ratingKey: item.id, initialSeasonKey: nil)
        case "season":
            return .show(ratingKey: item.parentRatingKey ?? item.id, initialSeasonKey: item.id)
        default:
            return .media(
                ratingKey: item.id,
                mediaType: item.mediaType,
                showRatingKey: item.grandparentRatingKey,
                seasonRatingKey: item.parentRatingKey
            )
        }
    }
}

/// What selecting a Home card does.
package enum HomeTapAction: Sendable {
    case play
    case openDetail
}

package enum HomeTapPolicy {
    /// Continue Watching plays if playable; Up Next plays only if playable and already started;
    /// the hero and Recently Added open the detail screen.
    package static func action(for item: PlexMetadata, in bucket: HomeBucket) -> HomeTapAction {
        switch bucket {
        case .hero, .recentlyAdded:
            return .openDetail
        case .continueWatching:
            return HomeMediaRules.isPlayable(item) ? .play : .openDetail
        case .upNext:
            return HomeMediaRules.isPlayable(item) && HomeMediaRules.isResuming(item) ? .play : .openDetail
        }
    }

    /// Explicit play requests (hero button, menu) fall back to the detail screen for things that cannot play.
    package static func playOrDetail(for item: PlexMetadata) -> HomeTapAction {
        HomeMediaRules.isPlayable(item) ? .play : .openDetail
    }

    /// The Play/Pause remote button plays any playable card and ignores the rest.
    package static func playPauseAction(for item: PlexMetadata) -> HomeTapAction? {
        HomeMediaRules.isPlayable(item) ? .play : nil
    }
}

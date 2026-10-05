@preconcurrency import UIKit

/// Which Home rail a card belongs to; decides its caption copy and tap behaviour.
enum HomeBucket: String, Hashable, Sendable {
    case hero
    case continueWatching
    case upNext
    case recentlyAdded
}

/// Card configuration, navigation and context-menu building shared by Home and its See All grids.
@MainActor
enum HomeMediaActions {
    static func posterConfiguration(for item: PlexMetadata, bucket: HomeBucket) -> PosterContentConfiguration {
        var config = PosterContentConfiguration()
        config.title = HomeFormat.title(for: item)
        switch item.mediaType {
        case "episode":
            config.posterPath = item.grandparentThumb ?? item.thumb
            config.placeholderIcon = "tv"
        case "season", "show":
            config.posterPath = item.thumb ?? item.parentThumb ?? item.grandparentThumb
            config.placeholderIcon = "tv"
        default:
            config.posterPath = item.thumb ?? item.grandparentThumb
        }
        switch bucket {
        case .upNext, .hero, .continueWatching:
            config.subtitle = HomeFormat.upNextSubtitle(for: item)
        case .recentlyAdded:
            config.subtitle = HomeFormat.recentSubtitle(for: item)
        }
        if item.positionSecs > 0, item.duration != nil {
            config.progress = item.progressPercent
        }
        config.isUnwatched = isUnwatched(item)
        config.isDownloaded = DownloadManager.shared.isDownloaded(item.id)
        return config
    }

    static func landscapeConfiguration(for item: PlexMetadata) -> LandscapeContentConfiguration {
        var config = LandscapeContentConfiguration()
        config.title = HomeFormat.title(for: item)
        config.subtitle = HomeFormat.continueSubtitle(for: item)
        config.imagePath = item.mediaType == "episode"
            ? (item.thumb ?? item.grandparentArt ?? item.art)
            : (item.art ?? item.thumb)
        config.placeholderIcon = item.mediaType == "episode" ? "tv" : "film"
        if item.positionSecs > 0, item.duration != nil {
            config.progress = item.progressPercent
        }
        config.trailingText = HomeFormat.remaining(item) ?? HomeFormat.runtime(item.durationSecs)
        config.showsPlayChip = item.mediaType != "show"
        return config
    }

    static func isUnwatched(_ item: PlexMetadata) -> Bool {
        switch item.mediaType {
        case "show", "season":
            guard let leaves = item.leafCount, leaves > 0 else { return false }
            return (item.viewedLeafCount ?? 0) < leaves
        default:
            return !item.isWatched && item.positionSecs == 0
        }
    }

    static func isPlayable(_ item: PlexMetadata) -> Bool {
        item.mediaType == "movie" || item.mediaType == "episode" || item.mediaType == "clip"
    }

    static func openDetail(_ item: PlexMetadata, api: APIClient, from navigation: UINavigationController?) {
        switch item.mediaType {
        case "show":
            navigation?.pushViewController(ShowDetailViewController(api: api, showRatingKey: item.id), animated: true)
        case "season":
            let showKey = item.parentRatingKey ?? item.id
            navigation?.pushViewController(ShowDetailViewController(api: api, showRatingKey: showKey, initialSeasonKey: item.id), animated: true)
        default:
            let detail = MediaDetailViewController(
                api: api,
                ratingKey: item.id,
                mediaType: item.mediaType,
                showRatingKey: item.grandparentRatingKey,
                seasonRatingKey: item.parentRatingKey
            )
            navigation?.pushViewController(detail, animated: true)
        }
    }

    /// The long-press menu every Home card shares. Items that do not apply are omitted.
    static func contextMenu(
        for item: PlexMetadata,
        api: APIClient,
        navigation: @escaping @MainActor () -> UINavigationController?,
        play: @escaping @MainActor (PlexMetadata) -> Void,
        didChange: @escaping @MainActor () -> Void
    ) -> UIMenu {
        var actions = [UIMenuElement]()
        if isPlayable(item) {
            actions.append(UIAction(title: item.positionSecs > 0 ? "Resume" : "Play", image: UIImage(systemName: "play.fill")) { _ in
                play(item)
            })
        }
        actions.append(UIAction(title: "View Details", image: UIImage(systemName: "info.circle")) { _ in
            openDetail(item, api: api, from: navigation())
        })
        let watched = item.mediaType == "show" || item.mediaType == "season" ? !isUnwatched(item) : item.isWatched
        actions.append(UIAction(title: watched ? "Mark Unwatched" : "Mark Watched", image: UIImage(systemName: watched ? "eye.slash" : "eye")) { _ in
            Haptics.light()
            Task { @MainActor in
                do {
                    if watched {
                        try await api.requestVoid(.unscrobble(ratingKey: item.id))
                    } else {
                        try await api.requestVoid(.scrobble(ratingKey: item.id))
                    }
                } catch {
                    AppLogger.error("Home mark watched failed ratingKey=\(item.id): \(error.localizedDescription)", .networking)
                }
                didChange()
            }
        })
        if item.mediaType != "show" && item.mediaType != "season" {
            actions.append(DownloadMenu.action(for: item))
        }
        if item.mediaType == "episode", let showKey = item.grandparentRatingKey {
            actions.append(UIAction(title: "Go to Show", image: UIImage(systemName: "tv")) { _ in
                navigation()?.pushViewController(ShowDetailViewController(api: api, showRatingKey: showKey), animated: true)
            })
        } else if item.mediaType == "season", let showKey = item.parentRatingKey {
            actions.append(UIAction(title: "Go to Show", image: UIImage(systemName: "tv")) { _ in
                navigation()?.pushViewController(ShowDetailViewController(api: api, showRatingKey: showKey), animated: true)
            })
        }
        return UIMenu(children: actions)
    }
}

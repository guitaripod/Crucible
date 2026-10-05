import UIKit

/// What a Recently Watched card shows and does, shared by the rail in the library grid and its
/// "See All" grid. A show library's cards stand for the series but carry the episode last played.
@MainActor
enum RecentlyWatchedActions {
    static func posterConfiguration(for item: PlexMetadata, kind: LibraryGridKind) -> PosterContentConfiguration {
        var config = PosterContentConfiguration()
        config.placeholderIcon = kind.placeholderIcon
        let when = Formatters.unixRelativeDate(item.viewedAt)
        switch kind {
        case .movie:
            config.posterPath = item.thumb ?? item.grandparentThumb
            config.title = item.title
            config.subtitle = when
        case .show:
            config.posterPath = item.grandparentThumb ?? item.thumb
            config.title = item.grandparentTitle ?? item.title
            let detail = [Formatters.episodeCode(item.parentIndex, item.index), when].compactMap { $0 }.joined(separator: " · ")
            config.subtitle = detail.isEmpty ? nil : detail
        }
        return config
    }

    /// A tapped card opens the show for a show library, and the film for a movie library.
    static func destination(for item: PlexMetadata, kind: LibraryGridKind, api: APIClient) -> UIViewController {
        switch kind {
        case .movie:
            return mediaDetail(for: item, api: api)
        case .show:
            return ShowDetailViewController(api: api, showRatingKey: item.grandparentRatingKey ?? item.id)
        }
    }

    static func contextMenu(
        for item: PlexMetadata,
        kind: LibraryGridKind,
        api: APIClient,
        open: @escaping (UIViewController) -> Void,
        play: @escaping (PlexMetadata) -> Void
    ) -> UIMenu {
        var actions = [UIMenuElement]()
        if kind == .show, let showKey = item.grandparentRatingKey {
            actions.append(UIAction(title: "Go to Show", image: UIImage(systemName: "tv")) { _ in
                open(ShowDetailViewController(api: api, showRatingKey: showKey))
            })
        }
        actions.append(UIAction(title: "Play Again", image: UIImage(systemName: "play.fill")) { _ in
            play(item)
        })
        actions.append(UIAction(title: kind == .show ? "Episode Details" : "View Details", image: UIImage(systemName: "info.circle")) { _ in
            open(mediaDetail(for: item, api: api))
        })
        return UIMenu(children: actions)
    }

    private static func mediaDetail(for item: PlexMetadata, api: APIClient) -> UIViewController {
        MediaDetailViewController(
            api: api,
            ratingKey: item.id,
            mediaType: item.mediaType,
            showRatingKey: item.grandparentRatingKey,
            seasonRatingKey: item.parentRatingKey
        )
    }
}

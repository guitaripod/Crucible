import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// Card configuration, navigation and context-menu building shared by Home and its See All grids.
@MainActor
enum HomeMediaActions {
    static func posterConfiguration(for item: PlexMetadata, bucket: HomeBucket) -> PosterContentConfiguration {
        let card = HomeCardModel(item: item, bucket: bucket, layout: .poster)
        var config = PosterContentConfiguration()
        config.title = card.title
        config.posterPath = card.imagePath
        if card.usesSeriesPlaceholder { config.placeholderIcon = "tv" }
        config.subtitle = card.subtitle
        config.progress = card.progress
        config.isUnwatched = card.isUnwatched
        config.isDownloaded = DownloadManager.shared.isDownloaded(item.id)
        return config
    }

    static func landscapeConfiguration(for item: PlexMetadata) -> LandscapeContentConfiguration {
        let card = HomeCardModel(item: item, bucket: .continueWatching, layout: .landscape)
        var config = LandscapeContentConfiguration()
        config.title = card.title
        config.subtitle = card.subtitle
        config.imagePath = card.imagePath
        config.placeholderIcon = card.usesSeriesPlaceholder ? "tv" : "film"
        config.progress = card.progress
        config.trailingText = card.trailingText
        config.showsPlayChip = card.showsPlayChip
        return config
    }

    static func openDetail(_ item: PlexMetadata, api: APIClient, from navigation: UINavigationController?) {
        switch HomeMediaRules.detailRoute(for: item) {
        case .show(let ratingKey, let initialSeasonKey):
            let show = ShowDetailViewController(api: api, showRatingKey: ratingKey, initialSeasonKey: initialSeasonKey)
            navigation?.pushViewController(show, animated: true)
        case .media(let ratingKey, let mediaType, let showRatingKey, let seasonRatingKey):
            let detail = MediaDetailViewController(
                api: api,
                ratingKey: ratingKey,
                mediaType: mediaType,
                showRatingKey: showRatingKey,
                seasonRatingKey: seasonRatingKey
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
        if HomeMediaRules.isPlayable(item) {
            actions.append(UIAction(title: HomeMediaRules.playTitle(for: item), image: UIImage(systemName: "play.fill")) { _ in
                play(item)
            })
        }
        actions.append(UIAction(title: "View Details", image: UIImage(systemName: "info.circle")) { _ in
            openDetail(item, api: api, from: navigation())
        })
        let toggle = HomeMediaRules.watchedToggle(for: item)
        actions.append(UIAction(title: toggle.title, image: UIImage(systemName: toggle.isWatched ? "eye.slash" : "eye")) { _ in
            Haptics.light()
            Task { @MainActor in
                do {
                    try await toggle.perform(using: api)
                } catch {
                    AppLogger.error("Home mark watched failed ratingKey=\(item.id): \(error.localizedDescription)", .networking)
                }
                didChange()
            }
        })
        if HomeMediaRules.isDownloadable(item) {
            actions.append(DownloadMenu.action(for: item))
        }
        if let showKey = HomeMediaRules.showRatingKey(for: item) {
            actions.append(UIAction(title: "Go to Show", image: UIImage(systemName: "tv")) { _ in
                navigation()?.pushViewController(ShowDetailViewController(api: api, showRatingKey: showKey), animated: true)
            })
        }
        return UIMenu(children: actions)
    }
}

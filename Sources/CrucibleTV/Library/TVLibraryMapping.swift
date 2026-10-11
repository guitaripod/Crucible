import CrucibleCore
import UIKit

extension TVCardItem {
    /// A poster of the library grid. Movies carry progress, the unwatched dot or the watched check;
    /// shows carry the count of unwatched episodes.
    init(gridItem item: PlexMetadata, kind: LibraryGridKind) {
        let poster = LibraryPoster(grid: item, kind: kind)
        self.init(
            id: item.id,
            artworkPath: poster.posterPath,
            title: poster.title,
            subtitle: poster.subtitle,
            progress: poster.progress,
            isUnwatched: poster.isUnwatched,
            isWatched: kind == .movie && item.isWatched,
            badgeText: poster.unwatchedCount.map { "\($0) unwatched" },
            placeholderSymbol: poster.placeholderIcon
        )
    }

    init(recentItem item: PlexMetadata, kind: LibraryGridKind) {
        let poster = LibraryPoster(recent: item, kind: kind)
        self.init(
            id: item.id,
            artworkPath: poster.posterPath,
            title: poster.title,
            subtitle: poster.subtitle,
            placeholderSymbol: poster.placeholderIcon
        )
    }

    init(folderItem item: PlexMetadata) {
        let poster = LibraryPoster(folderItem: item)
        self.init(
            id: item.id,
            artworkPath: poster.posterPath,
            title: poster.title,
            subtitle: poster.subtitle,
            placeholderSymbol: poster.placeholderIcon
        )
    }
}

extension UIMenu {
    /// The long-press menu of a library card; `perform` receives the chosen action.
    @MainActor
    convenience init(libraryActions actions: [LibraryItemAction], perform: @escaping @MainActor (LibraryItemAction) -> Void) {
        self.init(children: actions.map { action in
            UIAction(title: action.title, image: UIImage(systemName: action.symbol)) { _ in
                perform(action)
            }
        })
    }
}

extension TVScreens {
    /// Opens where `destination` leads on `navigation`.
    static func open(_ destination: LibraryDestination, env: TVAppEnvironment, on navigation: UINavigationController?) {
        let screen: UIViewController
        switch destination {
        case .show(let ratingKey):
            screen = showDetail(env, ratingKey: ratingKey, initialSeasonKey: nil)
        case .media(let item):
            screen = detail(env, ratingKey: item.id, mediaType: item.mediaType)
        }
        navigation?.pushViewController(screen, animated: true)
    }
}

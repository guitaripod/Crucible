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

    /// A folder entry. Movies and episodes carry progress, the unwatched dot or the watched check.
    init(folderItem item: PlexMetadata) {
        let poster = LibraryPoster(folderItem: item)
        let tracksWatched = HomeMediaRules.isPlayable(item)
        let progress = item.progressFraction
        self.init(
            id: item.id,
            artworkPath: poster.posterPath,
            title: poster.title,
            subtitle: poster.subtitle,
            progress: tracksWatched && progress > 0 ? progress : nil,
            isUnwatched: tracksWatched && !item.isWatched && progress <= 0,
            isWatched: tracksWatched && item.isWatched,
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

/// What a library card does when chosen, played or long-pressed, shared by every screen that shows
/// library cards so Select, Play/Pause and the menu agree. A Recently Watched card always restarts.
@MainActor
final class TVLibraryItemActions {
    private let env: TVAppEnvironment
    private let kind: LibraryGridKind
    private weak var presenter: UIViewController?
    private let setWatched: (@MainActor (PlexMetadata, Bool) -> Void)?

    init(
        env: TVAppEnvironment,
        kind: LibraryGridKind,
        presenter: UIViewController,
        setWatched: (@MainActor (PlexMetadata, Bool) -> Void)? = nil
    ) {
        self.env = env
        self.kind = kind
        self.presenter = presenter
        self.setWatched = setWatched
    }

    /// Starts playback of a playable item; returns false for anything else (a show), so Play/Pause can pass the press on.
    @discardableResult
    func play(_ item: PlexMetadata, isRecent: Bool) -> Bool {
        guard HomeMediaRules.isPlayable(item), let presenter else { return false }
        TVScreens.play(env, request: TVPlaybackRequest(item: item, resumeSeconds: isRecent ? 0 : nil), from: presenter)
        return true
    }

    func select(_ item: PlexMetadata, isRecent: Bool) {
        open(isRecent ? LibraryDestination(recent: item, kind: kind) : LibraryDestination(browsing: item))
    }

    func menu(for item: PlexMetadata, isRecent: Bool) -> UIMenu {
        let actions = isRecent ? LibraryItemAction.recent(for: item, kind: kind) : LibraryItemAction.grid(for: item, kind: kind)
        return UIMenu(libraryActions: actions) { [weak self] action in
            self?.perform(action, on: item, isRecent: isRecent)
        }
    }

    private func perform(_ action: LibraryItemAction, on item: PlexMetadata, isRecent: Bool) {
        switch action.kind {
        case .play:
            play(item, isRecent: isRecent)
        case .setWatched(let watched):
            setWatched?(item, watched)
        case .goToShow(let showKey):
            open(.show(ratingKey: showKey))
        case .viewDetails:
            open(isRecent ? .media(item) : LibraryDestination(browsing: item))
        }
    }

    private func open(_ destination: LibraryDestination?) {
        guard let destination, let presenter else { return }
        TVScreens.open(destination, env: env, from: presenter)
    }
}

extension TVScreens {
    /// Opens where `destination` leads, pushed on `presenter`'s navigation stack.
    static func open(_ destination: LibraryDestination, env: TVAppEnvironment, from presenter: UIViewController) {
        let screen: UIViewController
        switch destination {
        case .show(let ratingKey):
            screen = showDetail(env, ratingKey: ratingKey, initialSeasonKey: nil)
        case .media(let item):
            screen = detail(env, ratingKey: item.id, mediaType: item.mediaType)
        }
        TVNavigation.push(screen, from: presenter)
    }
}

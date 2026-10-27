import CrucibleCore
import UIKit

/// What a Recently Watched card shows and does, shared by the rail in the library grid and its
/// "See All" grid. A show library's cards stand for the series but carry the episode last played.
@MainActor
enum RecentlyWatchedActions {
    static func posterConfiguration(for item: PlexMetadata, kind: LibraryGridKind) -> PosterContentConfiguration {
        LibraryPoster(recent: item, kind: kind).configuration
    }

    static func destination(for item: PlexMetadata, kind: LibraryGridKind, api: APIClient) -> UIViewController {
        LibraryDestination(recent: item, kind: kind).viewController(api: api)
    }

    static func contextMenu(
        for item: PlexMetadata,
        kind: LibraryGridKind,
        api: APIClient,
        open: @escaping (UIViewController) -> Void,
        play: @escaping (PlexMetadata) -> Void
    ) -> UIMenu {
        UIMenu(children: LibraryItemAction.recent(for: item, kind: kind).map { action in
            action.menuAction {
                switch action.kind {
                case .goToShow(let showKey):
                    open(LibraryDestination.show(ratingKey: showKey).viewController(api: api))
                case .play, .playFromBeginning:
                    play(item)
                case .viewDetails:
                    open(LibraryDestination.media(item).viewController(api: api))
                case .setWatched:
                    return
                }
            }
        })
    }
}

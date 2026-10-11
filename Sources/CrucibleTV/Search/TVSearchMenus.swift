import CrucibleCore
import UIKit

/// The long-press menus of search results: Play or Resume, Go to Show and Mark Watched or Unwatched.
@MainActor
enum TVSearchMenus {
    static func menu(
        for item: PlexMetadata,
        watched: Bool,
        play: @escaping @MainActor () -> Void,
        goToShow: @escaping @MainActor (String) -> Void,
        toggleWatched: @escaping @MainActor () -> Void
    ) -> UIMenu? {
        var actions = [UIMenuElement]()
        let isPlayable = SearchItemActions.isPlayable(item)
        if isPlayable {
            actions.append(UIAction(title: SearchItemActions.playTitle(for: item), image: UIImage(systemName: "play.fill")) { _ in play() })
        }
        if let showKey = SearchItemActions.showKey(for: item) {
            actions.append(UIAction(title: "Go to Show", image: UIImage(systemName: "tv")) { _ in goToShow(showKey) })
        }
        if isPlayable {
            actions.append(UIAction(
                title: WatchedService.title(isWatched: watched),
                image: UIImage(systemName: watched ? "eye.slash" : "eye")
            ) { _ in toggleWatched() })
        }
        return actions.isEmpty ? nil : UIMenu(children: actions)
    }
}

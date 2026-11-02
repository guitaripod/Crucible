import CrucibleCore
import UIKit

/// The long-press menu of a search result: playback, the ways to find the title and both watched
/// directions.
@MainActor
enum TVSearchMenus {
    static func menu(
        for item: PlexMetadata,
        watched: Bool,
        play: @escaping @MainActor () -> Void,
        playFromBeginning: @escaping @MainActor () -> Void,
        openDetails: @escaping @MainActor () -> Void,
        goToShow: @escaping @MainActor (String) -> Void,
        setWatched: @escaping @MainActor (Bool) -> Void
    ) -> UIMenu? {
        var groups = [UIMenuElement]()
        if SearchItemActions.isPlayable(item) {
            var playback = [
                UIAction(title: item.isResumable ? String(localized: "Resume") : String(localized: "Play"), image: UIImage(systemName: "play.fill")) { _ in play() },
            ]
            if item.isResumable {
                playback.append(UIAction(title: String(localized: "Play from Beginning"), image: UIImage(systemName: "gobackward")) { _ in
                    playFromBeginning()
                })
            }
            groups.append(UIMenu(title: "", options: .displayInline, children: playback))
        }
        var details = [
            UIAction(title: String(localized: "View Details"), image: UIImage(systemName: "info.circle")) { _ in openDetails() },
        ]
        if let showKey = SearchItemActions.showKey(for: item) {
            details.append(UIAction(title: String(localized: "Go to Show"), image: UIImage(systemName: "tv")) { _ in goToShow(showKey) })
        }
        groups.append(UIMenu(title: "", options: .displayInline, children: details))
        groups.append(UIMenu(title: String(localized: "Watched"), image: UIImage(systemName: "eye"), children: [
            UIAction(title: String(localized: "Mark Watched"), image: UIImage(systemName: "checkmark.circle"), state: watched ? .on : .off) { _ in
                setWatched(true)
            },
            UIAction(title: String(localized: "Mark Unwatched"), image: UIImage(systemName: "eye.slash"), state: watched ? .off : .on) { _ in
                setWatched(false)
            },
        ]))
        return UIMenu(children: groups)
    }
}

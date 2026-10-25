import CrucibleCore
@preconcurrency import UIKit

/// Windows on iPad: what a window was showing when iPadOS brings it back, and opening a title in a window of its own from a context
/// menu, the keyboard or a drag to the edge of the screen.
@MainActor
enum WindowActivity {
    static let type = "com.guitaripod.crucible.window"
    private static let tabKey = "tab"

    struct State {
        let tab: String
        let media: (ratingKey: String, mediaType: String)?
    }

    static func make(tab: String, media: (ratingKey: String, mediaType: String)?) -> NSUserActivity {
        let activity = NSUserActivity(activityType: type)
        var info: [String: Any] = [tabKey: tab]
        if let media {
            info[MediaActivity.ratingKeyKey] = media.ratingKey
            info[MediaActivity.typeKey] = media.mediaType
        }
        activity.userInfo = info
        return activity
    }

    static func state(from activity: NSUserActivity) -> State? {
        guard activity.activityType == type, let tab = activity.userInfo?[tabKey] as? String else { return nil }
        let ratingKey = activity.userInfo?[MediaActivity.ratingKeyKey] as? String
        let mediaType = activity.userInfo?[MediaActivity.typeKey] as? String ?? "movie"
        return State(tab: tab, media: ratingKey.map { ($0, mediaType) })
    }

    /// Opens a window on `activity`'s title, or on Home when there is none.
    static func openWindow(for activity: NSUserActivity?, from scene: UIWindowScene?) {
        guard UIApplication.shared.supportsMultipleScenes else { return }
        var request = UISceneSessionActivationRequest()
        request.userActivity = activity
        if let scene {
            let options = UIScene.ActivationRequestOptions()
            options.requestingScene = scene
            request.options = options
        }
        UIApplication.shared.activateSceneSession(for: request) { error in
            AppLogger.error("New window refused: \(error.localizedDescription)", .ui)
        }
    }

    /// "Open in New Window" for a title's context menu; nil where the app has a single window.
    static func openInNewWindowAction(for item: PlexMetadata) -> UIMenuElement? {
        guard UIApplication.shared.supportsMultipleScenes else { return nil }
        let activity = mediaActivity(for: item)
        return UIWindowScene.ActivationAction { _ in
            UIWindowScene.ActivationConfiguration(userActivity: activity)
        }
    }

    /// A drag item for `item`: dropped at the edge of the screen it opens the title in a new window.
    static func dragItem(for item: PlexMetadata) -> UIDragItem {
        let provider = NSItemProvider()
        provider.registerObject(mediaActivity(for: item), visibility: .all)
        provider.suggestedName = item.title
        let dragItem = UIDragItem(itemProvider: provider)
        dragItem.localObject = item.id
        return dragItem
    }

    /// Episodes open on their own page; a show opens on the show.
    private static func mediaActivity(for item: PlexMetadata) -> NSUserActivity {
        let activity = NSUserActivity(activityType: MediaActivity.type)
        activity.title = item.title
        activity.userInfo = [MediaActivity.ratingKeyKey: item.id, MediaActivity.typeKey: item.mediaType]
        activity.targetContentIdentifier = "\(item.mediaType):\(item.id)"
        return activity
    }
}

extension UIMenu {
    /// The same menu with "Open in New Window" for `item` after its own actions, where the app can show more than one window.
    func addingNewWindow(for item: PlexMetadata) -> UIMenu {
        guard let action = WindowActivity.openInNewWindowAction(for: item) else { return self }
        return replacingChildren(children + [UIMenu(options: .displayInline, children: [action])])
    }
}

/// Lets a title be dragged out of a collection view on iPad: dropped at the edge of the screen it opens in a window of its own.
@MainActor
final class MediaDragSource: NSObject, UICollectionViewDragDelegate {
    private let media: (IndexPath) -> PlexMetadata?

    init(media: @escaping (IndexPath) -> PlexMetadata?) {
        self.media = media
    }

    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard UIApplication.shared.supportsMultipleScenes, let item = media(indexPath) else { return [] }
        return [WindowActivity.dragItem(for: item)]
    }
}

import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// The menu a title's card opens on right click or the Menu key (the tvOS long press): play or resume it, mark it watched
/// or unwatched, or open its page.
@MainActor
enum ItemActions {
    static func present(for media: PlexMetadata, api: APIClient, at point: Point?, in view: View, afterChange: @escaping () -> Void) {
        guard let window = view.window, let root = view.rootView else { return }
        let playable = HomeMediaRules.isPlayable(media)
        var items: [MenuView.Item] = []
        if playable {
            let resumes = media.resumeSecs > 0
            items.append(.init(id: "play", title: resumes ? String(localized: "Resume") : String(localized: "Play"), symbol: "play.fill"))
            if resumes { items.append(.init(id: "restart", title: String(localized: "Play from the Beginning"), symbol: "arrow.counterclockwise")) }
        }
        items.append(.init(id: "watched", title: WatchedService.title(isWatched: media.isWatched), symbol: "checkmark"))
        items.append(.init(id: "details", title: String(localized: "Go to Details"), symbol: "info.circle"))
        let anchor = Rect(x: point?.x ?? view.frameInWindow.minX, y: point?.y ?? view.frameInWindow.maxY, width: 1, height: 1)
        let menu = MenuView(title: media.title, items: items, anchor: anchor)
        menu.onSelect = { item in
            switch item.id {
            case "play": root.play(item: media, api: api)
            case "restart": root.play(item: media, api: api, from: 0)
            case "details": root.push(DetailScreen.make(api: api, item: media))
            case "watched":
                Task {
                    do {
                        try await WatchedService.setWatched(!media.isWatched, ratingKey: media.id, api: api)
                        afterChange()
                    } catch {
                        MidgarLog.error("Watched toggle failed: \(error)", category: .networking)
                    }
                }
            default: break
            }
        }
        menu.present(in: window)
    }
}

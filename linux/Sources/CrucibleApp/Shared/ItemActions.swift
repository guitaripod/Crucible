import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// What a title's card can do, shared by Home, its See All grids, libraries, Search and every list of titles
/// (`TVHomeActions`): open its page, play it as Home's tap policy says, and the menu a right click or the Menu key opens.
@MainActor
enum ItemActions {
    /// Selecting a card: Continue Watching plays, Up Next plays what was started, everything else opens the page.
    static func select(_ media: PlexMetadata, in bucket: HomeBucket, api: APIClient, from view: View) {
        switch HomeTapPolicy.action(for: media, in: bucket) {
        case .play: play(media, api: api, from: view)
        case .openDetail: openDetail(media, api: api, from: view)
        }
    }

    /// The Play/Pause key on a card: starts what Home's tap policy lets it start; false for anything else (a show), so the
    /// key passes on.
    @discardableResult
    static func playPause(_ media: PlexMetadata, api: APIClient, from view: View) -> Bool {
        guard HomeTapPolicy.playPauseAction(for: media) == .play else { return false }
        play(media, api: api, from: view)
        return true
    }

    /// Plays `media`, or opens its page when it cannot play.
    static func play(_ media: PlexMetadata, restarting: Bool = false, api: APIClient, from view: View) {
        guard HomeTapPolicy.playOrDetail(for: media) == .play else {
            openDetail(media, api: api, from: view)
            return
        }
        view.rootView?.play(item: media, api: api, from: restarting ? 0 : nil)
    }

    static func openDetail(_ media: PlexMetadata, api: APIClient, from view: View) {
        let route: DetailRoute
        switch HomeMediaRules.detailRoute(for: media) {
        case .show(let ratingKey, let initialSeasonKey): route = .show(ratingKey: ratingKey, initialSeasonKey: initialSeasonKey)
        case .media(let ratingKey, let mediaType, let showKey, let seasonKey):
            route = .item(ratingKey: ratingKey, mediaType: mediaType, showRatingKey: showKey, seasonRatingKey: seasonKey)
        }
        view.rootView?.push(DetailScreen.make(api: api, route: route, placeholder: media))
    }

    /// Play or Resume, Play from Beginning, View Details, Go to Show, Mark Watched or Unwatched (a whole show by its
    /// unwatched episodes), Remove from Continue Watching or Up Next on those rows, and Add to Playlist; what does not apply
    /// is left out. `afterChange` runs once the server has the change.
    /// `extras` adds a screen's own items after the shared ones, each with what it does.
    static func present(for media: PlexMetadata, bucket: HomeBucket? = nil, api: APIClient, at point: Point?, in view: View,
                        extras: [(item: MenuView.Item, run: () -> Void)] = [], afterChange: @escaping () -> Void) {
        guard let window = view.window else { return }
        var items: [MenuView.Item] = []
        if HomeMediaRules.isPlayable(media) {
            items.append(.init(id: "play", title: HomeMediaRules.playTitle(for: media), symbol: "play.fill"))
            if HomeMediaRules.isResuming(media) {
                items.append(.init(id: "restart", title: String(localized: "Play from Beginning"), symbol: "gobackward"))
            }
        }
        items.append(.init(id: "details", title: String(localized: "View Details"), symbol: "info.circle"))
        let showKey = HomeMediaRules.showRatingKey(for: media)
        if showKey != nil { items.append(.init(id: "show", title: String(localized: "Go to Show"), symbol: "tv")) }
        let toggle = HomeMediaRules.watchedToggle(for: media)
        items.append(.init(id: "watched", title: toggle.title, symbol: toggle.isWatched ? "eye.slash" : "eye"))
        if let bucket, ContinueWatchingRemoval.applies(to: media, in: bucket) {
            items.append(.init(id: "remove", title: ContinueWatchingRemoval.title(for: bucket), symbol: Symbol(ContinueWatchingRemoval.symbol)))
        }
        if media.isPlaylistable {
            items.append(.init(id: "playlist", title: PlaylistFormat.addToPlaylist, symbol: "text.badge.plus"))
        }
        if ManageTools.offers(media) {
            items.append(.init(id: "manage", title: ManageCopy.menuTitle, symbol: "wrench.and.screwdriver"))
        }
        items.append(.init(id: "copy", title: String(localized: "Copy Title"), symbol: "doc.on.doc"))
        items += extras.map(\.item)
        let frame = window.focusedView?.frameInWindow ?? view.frameInWindow
        let anchor = Rect(x: point.map { $0.x } ?? frame.minX, y: point.map { $0.y } ?? frame.maxY, width: 1, height: 1)
        let menu = MenuView(title: media.title, items: items, anchor: anchor)
        menu.onSelect = { [weak view] item in
            guard let view else { return }
            switch item.id {
            case "play": play(media, api: api, from: view)
            case "restart": play(media, restarting: true, api: api, from: view)
            case "details": openDetail(media, api: api, from: view)
            case "show":
                if let showKey { view.rootView?.push(DetailScreen.make(api: api, route: .show(ratingKey: showKey, initialSeasonKey: nil))) }
            case "watched":
                Task {
                    do {
                        try await toggle.perform(using: api)
                    } catch {
                        MidgarLog.error("Mark watched failed ratingKey=\(media.id): \(error)", category: .networking)
                    }
                    afterChange()
                }
            case "remove":
                Task {
                    do {
                        try await ContinueWatchingRemoval.remove(ratingKey: media.id, api: api)
                    } catch {
                        AlertView.notice(title: ContinueWatchingRemoval.failureTitle, message: ContinueWatchingRemoval.failureMessage, in: window)
                    }
                    afterChange()
                }
            case "playlist":
                PlaylistPicker.present(adding: [media], api: api, in: window)
            case "manage":
                ManageTools.presentItemMenu(for: media, api: api, host: view, anchor: anchor, reload: afterChange)
            case "copy":
                window.copy(media.title)
            default:
                extras.first { $0.item.id == item.id }?.run()
            }
        }
        menu.present(in: window)
    }
}

import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// The viewer's Plex watchlist (`TVScreens.watchlist`): a grid of what they saved, each card saying what Seerr knows of it
/// and what came out that the server lacks. A title the server has opens its page, one it does not opens the request
/// sheet, and the menu takes it off the watchlist.
@MainActor
enum WatchlistScreens {
    static func watchlist(api: APIClient) -> TitleGridScreen {
        let token = api.token
        let book = SeerrStateBook()
        let releases = WatchlistReleaseWatcher()
        let grid = TitleGridScreen(api: api, title: WatchlistService.title,
                                   empty: .init(symbol: "bookmark", title: WatchlistService.emptyTitle, message: WatchlistService.emptyText)) {
            try await WatchlistService.items(token: token)
        }
        grid.card = { item in
            var card = TitleCards.card(item)
            let news = releases.card(for: item, seerr: book.states[item.entryID], seerrLabel: book.cardSubtitle(for: item, fallback: nil),
                                     fallback: card.subtitle)
            card.subtitle = news.subtitle
            card.badgeText = news.badge?.localizedUppercase
            return card
        }
        releases.changed = { [weak grid] _ in grid?.refreshCards() }
        grid.onLoaded = { [weak grid] items in
            book.load(items) { [weak grid] _ in grid?.refreshCards() }
            releases.loaded(items, api: api)
        }
        grid.onSelect = { [weak grid] entry in
            guard let grid else { return }
            open(entry, api: api, from: grid)
        }
        grid.onMenu = { [weak grid] entry, point in
            guard let grid, let window = grid.window, let guid = entry.guid else { return }
            let frame = window.focusedView?.frameInWindow ?? grid.frameInWindow
            let menu = MenuView(title: entry.title, items: [MenuView.Item(id: "remove", title: WatchlistService.remove, symbol: "bookmark.slash", isDestructive: true,
                                                                          shortcut: String(localized: "Delete"))],
                                anchor: Rect(x: point?.x ?? frame.minX, y: point?.y ?? frame.maxY, width: 1, height: 1))
            menu.onSelect = { [weak grid] _ in
                if let grid { remove(guid: guid, token: token, from: grid) }
            }
            menu.present(in: window)
        }
        grid.onKey = { [weak grid] entry, event in
            guard let grid, let window = grid.window, event.key == .delete, event.modifiers.isEmpty, let guid = entry.guid else { return false }
            AlertView.confirm(title: WatchlistService.remove, message: entry.title, confirm: String(localized: "Remove", comment: "Button that confirms removing something"),
                              in: window) { [weak grid] in
                if let grid { remove(guid: guid, token: token, from: grid) }
            }
            return true
        }
        return grid
    }

    /// Takes a title off the watchlist and loads the grid again, or says what went wrong.
    private static func remove(guid: String, token: String, from grid: TitleGridScreen) {
        Task { @MainActor [weak grid] in
            do {
                try await WatchlistService.remove(guid: guid, token: token)
                grid?.reload()
            } catch {
                guard let window = grid?.window else { return }
                AlertView.notice(title: String(localized: "Couldn’t Update"), message: error.localizedDescription, in: window)
            }
        }
    }

    /// Opens the server's copy of a watchlist title, or the request sheet when the server has none.
    private static func open(_ entry: PlexMetadata, api: APIClient, from screen: TitleGridScreen) {
        Task { @MainActor [weak screen] in
            do {
                let local = try await WatchlistService.localMatch(for: entry, api: api)
                guard let screen else { return }
                guard let local else {
                    SeerrRequestScreen.open(entry, api: api, isOnServer: false, from: screen)
                    return
                }
                screen.rootView?.push(DetailScreen.make(api: api, item: local))
            } catch {
                guard let window = screen?.window else { return }
                AlertView.notice(title: String(localized: "Couldn’t Load"), message: ConnectionError.message(for: error), in: window)
            }
        }
    }
}

import CrucibleCore
import UIKit

extension TVScreens {
    /// The viewer's Plex watchlist: a title the server has opens, one it does not says so.
    static func watchlist(_ env: TVAppEnvironment) -> UIViewController {
        let token = env.api.token
        let book = SeerrStateBook()
        let grid = TVMediaGridViewController(
            title: WatchlistService.title,
            empty: .init(symbol: "bookmark", title: WatchlistService.emptyTitle, message: WatchlistService.emptyText),
            card: { item in
                var card = titleCard(item)
                card.subtitle = book.cardSubtitle(for: item, fallback: card.subtitle)
                return card
            },
            load: { try await WatchlistService.items(token: token) }
        )
        grid.onLoaded = { [weak grid] items in
            book.load(items) { ids in grid?.reconfigure(ids) }
        }
        grid.onSelect = { [weak grid] entry in
            guard let grid else { return }
            open(entry, env: env, from: grid)
        }
        grid.contextMenu = { [weak grid] entry in
            guard let guid = entry.guid, let grid else { return nil }
            return UIMenu(children: [
                UIAction(title: WatchlistService.remove, image: UIImage(systemName: "bookmark.slash"), attributes: .destructive) { _ in
                    Task { @MainActor in
                        do {
                            try await WatchlistService.remove(guid: guid, token: token)
                            grid.reload()
                        } catch {
                            grid.presentAlert(title: String(localized: "Couldn\u{2019}t Update"), message: error.localizedDescription)
                        }
                    }
                },
            ])
        }
        return grid
    }

    private static func open(_ entry: PlexMetadata, env: TVAppEnvironment, from screen: UIViewController) {
        Task { @MainActor [weak screen] in
            do {
                guard let local = try await WatchlistService.localMatch(for: entry, api: env.api) else {
                    guard let screen else { return }
                    TVSeerrRequestViewController.open(entry, env: env, isOnServer: false, from: screen)
                    return
                }
                guard let screen else { return }
                TVHomeActions(env: env, onChange: {}).openDetail(local, from: screen)
            } catch {
                screen?.presentAlert(title: String(localized: "Couldn\u{2019}t Load"), message: error.localizedDescription)
            }
        }
    }
}

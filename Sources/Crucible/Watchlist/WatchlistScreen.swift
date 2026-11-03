import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

/// The viewer's Plex watchlist: a title the server has opens, one it does not says so.
@MainActor
enum WatchlistScreen {
    static func watchlist(api: APIClient) -> MediaGridViewController {
        let token = api.token
        let grid = MediaGridViewController(
            title: WatchlistService.title,
            empty: .init(symbol: "bookmark", title: WatchlistService.emptyTitle, text: WatchlistService.emptyText)
        ) {
            try await WatchlistService.items(token: token)
        }
        grid.onSelect = { [weak grid] entry in
            open(entry, api: api, from: grid)
        }
        grid.contextMenu = { [weak grid] entry in
            guard let guid = entry.guid else { return nil }
            return UIMenu(children: [
                UIAction(title: WatchlistService.remove, image: UIImage(systemName: "bookmark.slash"), attributes: .destructive) { _ in
                    Task { @MainActor in
                        do {
                            try await WatchlistService.remove(guid: guid, token: token)
                            Haptics.light()
                            grid?.reload()
                        } catch {
                            Haptics.error()
                            grid?.presentSimpleAlert(title: String(localized: "Couldn\u{2019}t Update"), message: error.localizedDescription)
                        }
                    }
                },
            ])
        }
        return grid
    }

    private static func open(_ entry: PlexMetadata, api: APIClient, from grid: MediaGridViewController?) {
        Task { @MainActor in
            do {
                guard let local = try await WatchlistService.localMatch(for: entry, api: api) else {
                    grid?.presentSimpleAlert(title: WatchlistService.notInLibraryTitle, message: WatchlistService.notInLibraryText)
                    return
                }
                HomeMediaActions.openDetail(local, api: api, from: grid?.navigationController)
            } catch {
                grid?.presentSimpleAlert(title: String(localized: "Couldn\u{2019}t Load"), message: error.localizedDescription)
            }
        }
    }

    /// Add to Watchlist or Remove from Watchlist for a title, whichever it is not yet; nil when the title has no guid to save it by or
    /// the account cannot be reached.
    static func toggleAction(for item: PlexMetadata, api: APIClient, host: UIViewController?) async -> UIAction? {
        guard let guid = item.guid, ["movie", "show"].contains(item.mediaType) else { return nil }
        let token = api.token
        guard let watchlist = try? await WatchlistService.items(token: token) else { return nil }
        let isListed = WatchlistService.contains(guid: guid, in: watchlist)
        return UIAction(
            title: isListed ? WatchlistService.remove : WatchlistService.add,
            image: UIImage(systemName: isListed ? "bookmark.slash" : "bookmark")
        ) { _ in
            Task { @MainActor in
                do {
                    if isListed {
                        try await WatchlistService.remove(guid: guid, token: token)
                    } else {
                        try await WatchlistService.add(guid: guid, token: token)
                    }
                    Haptics.success()
                } catch {
                    Haptics.error()
                    host?.presentSimpleAlert(title: String(localized: "Couldn\u{2019}t Update"), message: error.localizedDescription)
                }
            }
        }
    }
}

import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

/// The viewer's playlists and what is in one.
@MainActor
enum PlaylistScreens {
    static func playlists(api: APIClient) -> MediaGridViewController {
        let grid = MediaGridViewController(
            title: String(localized: "Playlists"),
            empty: .init(
                symbol: "list.bullet.rectangle",
                title: String(localized: "No Playlists"),
                text: String(localized: "Add a title to a playlist from its menu and it appears here.")
            )
        ) {
            try await PlaylistsFeed.playlists(api: api)
        }
        grid.configuration = { playlist in
            PosterContentConfiguration(
                posterPath: playlist.posterPath,
                title: playlist.title,
                subtitle: PlaylistFormat.subtitle(playlist),
                placeholderIcon: "list.bullet.rectangle"
            )
        }
        grid.onSelect = { [weak grid] playlist in
            grid?.navigationController?.pushViewController(entries(api: api, playlist: playlist), animated: true)
        }
        grid.contextMenu = { [weak grid] playlist in
            UIMenu(children: [deleteAction(playlist, api: api, host: grid, onDeleted: { grid?.reload() })])
        }
        return grid
    }

    static func entries(api: APIClient, playlist: PlexMetadata) -> MediaGridViewController {
        let load: () async throws -> [PlexMetadata] = { try await PlaylistsFeed.items(inPlaylist: playlist.id, api: api) }
        let grid = MediaGridViewController(
            title: playlist.title,
            empty: .init(symbol: "list.bullet.rectangle", title: String(localized: "Empty Playlist"), text: String(localized: "Add titles to this playlist from their menus."))
        ) { try await load() }
        var latest: [PlexMetadata] = []
        grid.onLoaded = { latest = $0 }
        MediaGridActions.install(on: grid, api: api, extra: { [weak grid] entry in
            guard !playlist.isSmart, let itemID = entry.playlistItemID, let index = latest.firstIndex(where: { $0.playlistItemID == itemID }) else { return [] }
            var actions: [UIMenuElement] = []
            if index > 0 {
                actions.append(moveAction(String(localized: "Move to Top"), symbol: "arrow.up.to.line", from: index, to: 0, entries: latest, playlist: playlist, api: api, grid: grid))
            }
            if index < latest.count - 1 {
                actions.append(moveAction(String(localized: "Move to End"), symbol: "arrow.down.to.line", from: index, to: latest.count - 1, entries: latest, playlist: playlist, api: api, grid: grid))
            }
            actions.append(UIAction(title: String(localized: "Remove from Playlist"), image: UIImage(systemName: "minus.circle"), attributes: .destructive) { _ in
                run(grid) { try await PlaylistService.remove(playlistItemID: itemID, fromPlaylist: playlist.id, api: api) }
            })
            return [UIMenu(options: .displayInline, children: actions)]
        })
        grid.navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: [deleteAction(playlist, api: api, host: grid, onDeleted: { [weak grid] in
                grid?.navigationController?.popViewController(animated: true)
            })])
        )
        grid.navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "Playlist Options")
        return grid
    }

    private static func moveAction(
        _ title: String, symbol: String, from: Int, to: Int, entries: [PlexMetadata],
        playlist: PlexMetadata, api: APIClient, grid: MediaGridViewController?
    ) -> UIAction {
        UIAction(title: title, image: UIImage(systemName: symbol)) { _ in
            guard let itemID = entries[from].playlistItemID else { return }
            let anchor = PlaylistService.anchor(movingFrom: from, to: to, in: entries)
            run(grid) { try await PlaylistService.move(playlistItemID: itemID, after: anchor, inPlaylist: playlist.id, api: api) }
        }
    }

    private static func deleteAction(_ playlist: PlexMetadata, api: APIClient, host: UIViewController?, onDeleted: @escaping @MainActor () -> Void) -> UIAction {
        UIAction(title: String(localized: "Delete Playlist"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
            let sheet = UIAlertController(
                title: String(localized: "Delete \u{201C}\(playlist.title)\u{201D}?"),
                message: String(localized: "The titles stay in your library."),
                preferredStyle: .actionSheet
            )
            sheet.addAction(UIAlertAction(title: String(localized: "Delete Playlist"), style: .destructive) { _ in
                Task { @MainActor in
                    do {
                        try await PlaylistService.delete(playlist: playlist.id, api: api)
                        Haptics.medium()
                        onDeleted()
                    } catch {
                        Haptics.error()
                        host?.presentSimpleAlert(title: String(localized: "Couldn\u{2019}t Delete"), message: error.localizedDescription)
                    }
                }
            })
            sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
            sheet.popoverPresentationController?.sourceView = host?.view
            sheet.popoverPresentationController?.sourceRect = CGRect(x: host?.view.bounds.midX ?? 0, y: host?.view.bounds.midY ?? 0, width: 0, height: 0)
            host?.present(sheet, animated: true)
        }
    }

    private static func run(_ grid: MediaGridViewController?, _ edit: @escaping () async throws -> Void) {
        Task { @MainActor in
            do {
                try await edit()
                Haptics.light()
                grid?.reload()
            } catch {
                Haptics.error()
                grid?.presentSimpleAlert(title: String(localized: "Couldn\u{2019}t Update"), message: error.localizedDescription)
            }
        }
    }
}

import CrucibleCore
import UIKit

extension TVScreens {
    static func playlists(_ env: TVAppEnvironment) -> UIViewController {
        let grid = TVMediaGridViewController(
            title: String(localized: "Playlists"),
            empty: .init(
                symbol: "list.bullet.rectangle",
                title: String(localized: "No Playlists"),
                message: String(localized: "Add a title to a playlist from its menu and it appears here.")
            ),
            card: { playlist in
                TVCardItem(
                    id: playlist.entryID,
                    artworkPath: playlist.posterPath,
                    title: playlist.title,
                    subtitle: PlaylistFormat.subtitle(playlist),
                    placeholderSymbol: "list.bullet.rectangle"
                )
            },
            load: { try await PlaylistsFeed.playlists(api: env.api) }
        )
        grid.summary = { items in items.count == 1 ? String(localized: "1 playlist") : String(localized: "\(items.count) playlists") }
        grid.onSelect = { [weak grid] playlist in
            guard let grid else { return }
            TVNavigation.push(playlistEntries(env, playlist: playlist), from: grid)
        }
        grid.contextMenu = { [weak grid] playlist in
            UIMenu(children: [deleteAction(playlist, env: env, from: grid) { grid?.reload() }])
        }
        return grid
    }

    static func playlistEntries(_ env: TVAppEnvironment, playlist: PlexMetadata) -> UIViewController {
        let grid = TVMediaGridViewController(
            title: playlist.title,
            empty: .init(
                symbol: "list.bullet.rectangle",
                title: String(localized: "Empty Playlist"),
                message: String(localized: "Add titles to this playlist from their menus.")
            ),
            card: titleCard,
            load: { try await PlaylistsFeed.items(inPlaylist: playlist.id, api: env.api) }
        )
        var latest: [PlexMetadata] = []
        grid.onLoaded = { latest = $0 }
        installTitleActions(on: grid, env: env, extra: { [weak grid] entry in
            guard !playlist.isSmart, let itemID = entry.playlistItemID,
                  let index = latest.firstIndex(where: { $0.playlistItemID == itemID }) else { return [] }
            var actions: [UIMenuElement] = []
            if index > 0 {
                actions.append(moveAction(String(localized: "Move to Top"), symbol: "arrow.up.to.line", from: index, to: 0, entries: latest, playlist: playlist, env: env, grid: grid))
            }
            if index < latest.count - 1 {
                actions.append(moveAction(String(localized: "Move to End"), symbol: "arrow.down.to.line", from: index, to: latest.count - 1, entries: latest, playlist: playlist, env: env, grid: grid))
            }
            actions.append(UIAction(title: String(localized: "Remove from Playlist"), image: UIImage(systemName: "minus.circle"), attributes: .destructive) { _ in
                run(grid) { try await PlaylistService.remove(playlistItemID: itemID, fromPlaylist: playlist.id, api: env.api) }
            })
            return actions
        })
        let base = grid.contextMenu
        grid.contextMenu = { [weak grid] entry in
            guard let menu = base?(entry), let grid else { return base?(entry) }
            let delete = deleteAction(playlist, env: env, from: grid) { TVNavigation.pop(from: grid) }
            return menu.replacingChildren(menu.children + [UIMenu(options: .displayInline, children: [delete])])
        }
        return grid
    }

    private static func moveAction(
        _ title: String, symbol: String, from: Int, to: Int, entries: [PlexMetadata],
        playlist: PlexMetadata, env: TVAppEnvironment, grid: TVMediaGridViewController?
    ) -> UIAction {
        UIAction(title: title, image: UIImage(systemName: symbol)) { _ in
            guard let itemID = entries[from].playlistItemID else { return }
            let anchor = PlaylistService.anchor(movingFrom: from, to: to, in: entries)
            run(grid) { try await PlaylistService.move(playlistItemID: itemID, after: anchor, inPlaylist: playlist.id, api: env.api) }
        }
    }

    private static func deleteAction(
        _ playlist: PlexMetadata, env: TVAppEnvironment, from screen: UIViewController?, onDeleted: @escaping @MainActor () -> Void
    ) -> UIAction {
        UIAction(title: String(localized: "Delete Playlist"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
            screen?.presentConfirmation(
                title: String(localized: "Delete \u{201C}\(playlist.title)\u{201D}?"),
                message: String(localized: "The titles stay in your library."),
                confirmTitle: String(localized: "Delete Playlist")
            ) {
                Task { @MainActor in
                    do {
                        try await PlaylistService.delete(playlist: playlist.id, api: env.api)
                        onDeleted()
                    } catch {
                        screen?.presentAlert(title: String(localized: "Couldn\u{2019}t Delete"), message: error.localizedDescription)
                    }
                }
            }
        }
    }

    private static func run(_ grid: TVMediaGridViewController?, _ edit: @escaping () async throws -> Void) {
        Task { @MainActor in
            do {
                try await edit()
                grid?.reload()
            } catch {
                grid?.presentAlert(title: String(localized: "Couldn\u{2019}t Update"), message: error.localizedDescription)
            }
        }
    }
}

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
            UIMenu(children: [
                UIMenu(options: .displayInline, children: playActions(for: playlist, api: api, grid: grid)),
                deleteAction(playlist, api: api, host: grid, onDeleted: { grid?.reload() }),
            ])
        }
        return grid
    }

    /// Play and Shuffle for a whole playlist, whose entries are fetched when one is chosen.
    private static func playActions(for playlist: PlexMetadata, api: APIClient, grid: MediaGridViewController?) -> [UIAction] {
        [(PlaylistFormat.play, "play.fill", false), (PlaylistFormat.shuffle, "shuffle", true)].map { title, symbol, shuffled in
            UIAction(title: title, image: UIImage(systemName: symbol)) { _ in
                Task { @MainActor in
                    do {
                        let entries = try await PlaylistsFeed.items(inPlaylist: playlist.id, api: api)
                        guard let queue = shuffled ? PlaybackQueue.shuffled(entries) : PlaybackQueue.starting(in: entries) else {
                            grid?.presentSimpleAlert(title: playlist.title, message: String(localized: "This playlist has nothing to play."))
                            return
                        }
                        play(queue, api: api, grid: grid)
                    } catch {
                        grid?.presentSimpleAlert(title: String(localized: "Couldn\u{2019}t Load"), message: error.localizedDescription)
                    }
                }
            }
        }
    }

    private static func play(_ queue: PlaybackQueue, api: APIClient, grid: MediaGridViewController?) {
        guard let grid else { return }
        Haptics.light()
        grid.retainedPlayer = Theme.quickPlay(api: api, item: queue.current, from: grid, queue: queue)
    }

    static func entries(api: APIClient, playlist: PlexMetadata) -> MediaGridViewController {
        let load: () async throws -> [PlexMetadata] = { try await PlaylistsFeed.items(inPlaylist: playlist.id, api: api) }
        let grid = MediaGridViewController(
            title: playlist.title,
            empty: .init(symbol: "list.bullet.rectangle", title: String(localized: "Empty Playlist"), text: String(localized: "Add titles to this playlist from their menus."))
        ) { try await load() }
        var latest: [PlexMetadata] = []
        let playItem = UIBarButtonItem(image: UIImage(systemName: "play.fill"), primaryAction: UIAction { [weak grid] _ in
            guard let queue = PlaybackQueue.starting(in: latest) else { return }
            play(queue, api: api, grid: grid)
        })
        playItem.accessibilityLabel = PlaylistFormat.play
        playItem.isEnabled = false
        grid.onLoaded = { entries in
            latest = entries
            playItem.isEnabled = PlaybackQueue.starting(in: entries) != nil
        }
        MediaGridActions.install(on: grid, api: api, extra: { [weak grid] entry in
            var actions: [UIMenuElement] = []
            if PlaybackQueue.isPlayable(entry), let queue = PlaybackQueue.starting(at: entry, in: latest) {
                actions.append(UIAction(title: PlaylistFormat.playFromHere, image: UIImage(systemName: "play.fill")) { _ in
                    play(queue, api: api, grid: grid)
                })
            }
            guard !playlist.isSmart, let itemID = entry.playlistItemID, let index = latest.firstIndex(where: { $0.playlistItemID == itemID }) else {
                return actions.isEmpty ? [] : [UIMenu(options: .displayInline, children: actions)]
            }
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
        let shuffle = UIAction(title: PlaylistFormat.shuffle, image: UIImage(systemName: "shuffle")) { [weak grid] _ in
            guard let queue = PlaybackQueue.shuffled(latest) else { return }
            play(queue, api: api, grid: grid)
        }
        let options = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: [
                shuffle,
                deleteAction(playlist, api: api, host: grid, onDeleted: { [weak grid] in
                    grid?.navigationController?.popViewController(animated: true)
                }),
            ])
        )
        options.accessibilityLabel = String(localized: "Playlist Options")
        grid.navigationItem.rightBarButtonItems = [options, playItem]
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

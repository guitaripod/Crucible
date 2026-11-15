import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// Playlists (`TVScreens.playlists`, `TVScreens.playlistEntries`): the viewer's playlists as covers, each opening its
/// entries. A playlist plays as a queue in one player, each entry following the last until the playlist ends.
@MainActor
enum PlaylistScreens {
    private static let deleteTitle = String(localized: "Delete Playlist")

    /// Every playlist: Select opens it, Play/Pause plays it from the top, and its menu plays, shuffles or deletes it.
    static func playlists(api: APIClient) -> TitleGridScreen {
        let grid = TitleGridScreen(api: api, title: String(localized: "Playlists"), empty: .init(
            symbol: "list.bullet.rectangle",
            title: String(localized: "No Playlists"),
            message: String(localized: "Add a title to a playlist from its menu and it appears here.")
        )) { try await PlaylistsFeed.playlists(api: api) }
        grid.card = { playlist in
            CardItem(id: playlist.entryID, artwork: playlist.posterPath.map { .path($0, .poster) }, title: playlist.title,
                     subtitle: PlaylistFormat.subtitle(playlist), placeholderSymbol: "list.bullet.rectangle")
        }
        grid.summary = { items in items.count == 1 ? String(localized: "1 playlist") : String(localized: "\(items.count) playlists") }
        grid.onSelect = { [weak grid] playlist in grid?.rootView?.push(entries(api: api, playlist: playlist)) }
        grid.onPlay = { [weak grid] playlist in
            guard let grid else { return false }
            playWhole(playlist, shuffled: false, api: api, from: grid)
            return true
        }
        grid.onMenu = { [weak grid] playlist, point in
            guard let grid, let window = grid.window else { return }
            let menu = MenuView(title: playlist.title, items: [
                MenuView.Item(id: "play", title: PlaylistFormat.play, symbol: "play.fill"),
                MenuView.Item(id: "shuffle", title: PlaylistFormat.shuffle, symbol: "shuffle"),
                MenuView.Item(id: "delete", title: deleteTitle, symbol: "trash", isDestructive: true),
            ], anchor: anchor(at: point, in: grid))
            menu.onSelect = { [weak grid] chosen in
                guard let grid else { return }
                switch chosen.id {
                case "play": playWhole(playlist, shuffled: false, api: api, from: grid)
                case "shuffle": playWhole(playlist, shuffled: true, api: api, from: grid)
                default: confirmDelete(playlist, api: api, from: grid) { [weak grid] in grid?.reload() }
                }
            }
            menu.present(in: window)
        }
        return grid
    }

    /// A playlist's entries: Play/Pause plays from the entry on, and an entry's menu adds Play from Here, Shuffle, and for a
    /// playlist the viewer made, Move to Top, Move to End and Remove from Playlist; Delete Playlist ends every menu.
    static func entries(api: APIClient, playlist: PlexMetadata) -> TitleGridScreen {
        let grid = TitleGridScreen(api: api, title: playlist.title, empty: .init(
            symbol: "list.bullet.rectangle",
            title: String(localized: "Empty Playlist"),
            message: String(localized: "Add titles to this playlist from their menus.")
        )) { try await PlaylistsFeed.items(inPlaylist: playlist.id, api: api) }
        let loaded = LoadedEntries()
        grid.onLoaded = { loaded.entries = $0 }
        grid.onPlay = { [weak grid] entry in
            guard let grid, PlaybackQueue.isPlayable(entry), let queue = PlaybackQueue.starting(at: entry, in: loaded.entries) else { return false }
            play(queue, api: api, from: grid)
            return true
        }
        grid.onMenu = { [weak grid] entry, point in
            guard let grid else { return }
            let extras = entryActions(for: entry, in: loaded.entries, playlist: playlist, api: api, grid: grid)
            ItemActions.present(for: entry, api: api, at: point, in: grid, extras: extras) { [weak grid] in grid?.reload() }
        }
        return grid
    }

    /// The entries a playlist screen last loaded, in order, shared by its actions.
    private final class LoadedEntries {
        var entries: [PlexMetadata] = []
    }

    private static func entryActions(for entry: PlexMetadata, in entries: [PlexMetadata], playlist: PlexMetadata, api: APIClient,
                                     grid: TitleGridScreen) -> [(item: MenuView.Item, run: () -> Void)] {
        var actions: [(item: MenuView.Item, run: () -> Void)] = []
        if PlaybackQueue.isPlayable(entry), let queue = PlaybackQueue.starting(at: entry, in: entries) {
            actions.append((MenuView.Item(id: "playFromHere", title: PlaylistFormat.playFromHere, symbol: "play.fill"), { [weak grid] in
                if let grid { play(queue, api: api, from: grid) }
            }))
            actions.append((MenuView.Item(id: "shuffle", title: PlaylistFormat.shuffle, symbol: "shuffle"), { [weak grid] in
                if let grid, let shuffled = PlaybackQueue.shuffled(entries) { play(shuffled, api: api, from: grid) }
            }))
        }
        if !playlist.isSmart, let itemID = entry.playlistItemID, let index = entries.firstIndex(where: { $0.playlistItemID == itemID }) {
            if index > 0 {
                actions.append((MenuView.Item(id: "moveTop", title: String(localized: "Move to Top"), symbol: "arrow.up.to.line"), { [weak grid] in
                    if let grid { move(itemID, from: index, to: 0, in: entries, playlist: playlist, api: api, grid: grid) }
                }))
            }
            if index < entries.count - 1 {
                actions.append((MenuView.Item(id: "moveEnd", title: String(localized: "Move to End"), symbol: "arrow.down.to.line"), { [weak grid] in
                    if let grid { move(itemID, from: index, to: entries.count - 1, in: entries, playlist: playlist, api: api, grid: grid) }
                }))
            }
            actions.append((MenuView.Item(id: "removeEntry", title: String(localized: "Remove from Playlist"), symbol: "minus.circle", isDestructive: true), { [weak grid] in
                if let grid { update(grid) { try await PlaylistService.remove(playlistItemID: itemID, fromPlaylist: playlist.id, api: api) } }
            }))
        }
        actions.append((MenuView.Item(id: "deletePlaylist", title: deleteTitle, symbol: "trash", isDestructive: true), { [weak grid] in
            guard let grid else { return }
            confirmDelete(playlist, api: api, from: grid) { [weak grid] in _ = grid?.navigation?.pop() }
        }))
        return actions
    }

    /// Plays a playlist from its first entry, or in a random order, fetching the entries when it is chosen.
    private static func playWhole(_ playlist: PlexMetadata, shuffled: Bool, api: APIClient, from view: View) {
        Task { [weak view] in
            do {
                let entries = try await PlaylistsFeed.items(inPlaylist: playlist.id, api: api)
                guard let view else { return }
                guard let queue = shuffled ? PlaybackQueue.shuffled(entries) : PlaybackQueue.starting(in: entries) else {
                    if let window = view.window {
                        AlertView.notice(title: playlist.title, message: String(localized: "This playlist has nothing to play."), in: window)
                    }
                    return
                }
                play(queue, api: api, from: view)
            } catch {
                MidgarLog.error("Playlist \(playlist.id) failed to load for playback: \(error)", category: .networking)
                if let window = view?.window {
                    AlertView.notice(title: String(localized: "Couldn’t Load"), message: ConnectionError.message(for: error), in: window)
                }
            }
        }
    }

    private static func play(_ queue: PlaybackQueue, api: APIClient, from view: View) {
        view.rootView?.play(item: queue.current, api: api, run: PlayerRun(queue: queue))
    }

    private static func move(_ itemID: Int, from source: Int, to target: Int, in entries: [PlexMetadata], playlist: PlexMetadata, api: APIClient,
                             grid: TitleGridScreen) {
        let after = PlaylistService.anchor(movingFrom: source, to: target, in: entries)
        update(grid) { try await PlaylistService.move(playlistItemID: itemID, after: after, inPlaylist: playlist.id, api: api) }
    }

    /// Runs an edit of the playlist and reloads the grid, or says what the server refused.
    private static func update(_ grid: TitleGridScreen, _ edit: @escaping () async throws -> Void) {
        Task { [weak grid] in
            do {
                try await edit()
                grid?.reload()
            } catch {
                if let window = grid?.window {
                    AlertView.notice(title: String(localized: "Couldn’t Update"), message: ConnectionError.message(for: error), in: window)
                }
            }
        }
    }

    private static func confirmDelete(_ playlist: PlexMetadata, api: APIClient, from view: View, onDeleted: @escaping () -> Void) {
        guard let window = view.window else { return }
        AlertView.confirm(title: String(localized: "Delete “\(playlist.title)”?"), message: String(localized: "The titles stay in your library."),
                          confirm: deleteTitle, in: window) {
            Task {
                do {
                    try await PlaylistService.delete(playlist: playlist.id, api: api)
                    onDeleted()
                } catch {
                    AlertView.notice(title: String(localized: "Couldn’t Delete"), message: ConnectionError.message(for: error), in: window)
                }
            }
        }
    }

    /// Where a menu opens: at the pointer, or below the focused card.
    private static func anchor(at point: Point?, in view: View) -> Rect {
        let frame = view.window?.focusedView?.frameInWindow ?? view.frameInWindow
        return Rect(x: point?.x ?? frame.minX, y: point?.y ?? frame.maxY, width: 1, height: 1)
    }
}

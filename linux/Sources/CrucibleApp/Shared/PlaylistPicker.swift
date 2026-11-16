import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// Add to Playlist (`TVPlaylistPicker`): the viewer's own playlists as the buttons of an alert, with New Playlist beside
/// them, which asks for a name; each ends in an alert saying where the titles went.
@MainActor
enum PlaylistPicker {
    static func present(adding items: [PlexMetadata], api: APIClient, in window: Window) {
        let keys = items.filter(\.isPlaylistable).map(\.id)
        guard !keys.isEmpty else { return }
        Task { @MainActor in
            let playlists: [PlexMetadata]
            do {
                playlists = PlaylistService.editable(try await PlaylistsFeed.playlists(api: api))
            } catch {
                MidgarLog.error("Playlists load failed: \(error)", category: .networking)
                AlertView.notice(title: String(localized: "Couldn’t Load"), message: ConnectionError.message(for: error), in: window)
                return
            }
            var actions = playlists.map { playlist in
                AlertView.Action(playlist.title) { add(keys, to: playlist, api: api, in: window) }
            }
            actions.append(AlertView.Action(PlaylistFormat.newPlaylist) { promptForName(adding: keys, api: api, in: window) })
            actions.append(AlertView.Action(String(localized: "Cancel"), role: .cancel))
            AlertView(title: PlaylistFormat.addToPlaylist, actions: actions).present(in: window)
        }
    }

    private static func add(_ keys: [String], to playlist: PlexMetadata, api: APIClient, in window: Window) {
        Task { @MainActor in
            do {
                try await PlaylistService.add(keys, toPlaylist: playlist.id, api: api)
                AlertView.notice(title: String(localized: "Added to “\(playlist.title)”"), in: window)
            } catch {
                AlertView.notice(title: String(localized: "Couldn’t Add"), message: ConnectionError.message(for: error), in: window)
            }
        }
    }

    private static func promptForName(adding keys: [String], api: APIClient, in window: Window) {
        weak var prompt: AlertView?
        let alert = AlertView(title: PlaylistFormat.namePrompt, actions: [
            AlertView.Action(PlaylistFormat.create) {
                let name = prompt?.text ?? ""
                Task { @MainActor in
                    do {
                        guard let made = try await PlaylistService.create(title: name, adding: keys, api: api) else { return }
                        AlertView.notice(title: String(localized: "Added to “\(made.title)”"), in: window)
                    } catch {
                        AlertView.notice(title: String(localized: "Couldn’t Create"), message: ConnectionError.message(for: error), in: window)
                    }
                }
            },
            AlertView.Action(String(localized: "Cancel"), role: .cancel),
        ], fieldPlaceholder: PlaylistFormat.namePlaceholder)
        prompt = alert
        alert.present(in: window)
    }
}

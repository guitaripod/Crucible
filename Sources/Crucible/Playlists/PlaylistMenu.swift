import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

/// "Add to Playlist" for a title or several: the viewer's playlists are fetched when the menu opens, with New Playlist at the end.
@MainActor
enum PlaylistMenu {
    static func addMenu(for items: [PlexMetadata], api: APIClient, host: UIViewController) -> UIMenu {
        let keys = items.filter(\.isPlaylistable).map(\.id)
        let deferred = UIDeferredMenuElement.uncached { [weak host] completion in
            Task { @MainActor in
                let playlists = (try? await PlaylistsFeed.playlists(api: api)).map(PlaylistService.editable) ?? []
                var actions = playlists.map { playlist in
                    UIAction(title: playlist.title, image: UIImage(systemName: "list.bullet")) { _ in
                        add(keys, to: playlist, api: api, host: host)
                    }
                }
                actions.append(UIAction(title: PlaylistFormat.newPlaylist, image: UIImage(systemName: "plus")) { _ in
                    promptForNewPlaylist(adding: keys, api: api, host: host)
                })
                completion(actions)
            }
        }
        return UIMenu(title: PlaylistFormat.addToPlaylist, image: UIImage(systemName: "text.badge.plus"), children: [deferred])
    }

    private static func add(_ keys: [String], to playlist: PlexMetadata, api: APIClient, host: UIViewController?) {
        Task { @MainActor in
            do {
                try await PlaylistService.add(keys, toPlaylist: playlist.id, api: api)
                Haptics.success()
            } catch {
                Haptics.error()
                host?.presentSimpleAlert(title: String(localized: "Couldn\u{2019}t Add"), message: error.localizedDescription)
            }
        }
    }

    private static func promptForNewPlaylist(adding keys: [String], api: APIClient, host: UIViewController?) {
        let alert = UIAlertController(title: PlaylistFormat.namePrompt, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = PlaylistFormat.namePlaceholder
            field.autocapitalizationType = .words
            field.returnKeyType = .done
            field.accessibilityIdentifier = "playlist.name"
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        let create = UIAlertAction(title: PlaylistFormat.create, style: .default) { [weak alert] _ in
            let name = alert?.textFields?.first?.text ?? ""
            Task { @MainActor in
                do {
                    _ = try await PlaylistService.create(title: name, adding: keys, api: api)
                    Haptics.success()
                } catch {
                    Haptics.error()
                    host?.presentSimpleAlert(title: String(localized: "Couldn\u{2019}t Create"), message: error.localizedDescription)
                }
            }
        }
        alert.addAction(create)
        alert.preferredAction = create
        host?.present(alert, animated: true)
    }
}

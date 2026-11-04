import CrucibleCore
import MidgarCore
import UIKit

/// "Add to Playlist" on Apple TV: the viewer's playlists as the buttons of an alert, with New Playlist beside them and Menu to cancel.
@MainActor
enum TVPlaylistPicker {
    static func present(adding items: [PlexMetadata], env: TVAppEnvironment, from screen: UIViewController) {
        let keys = items.filter(\.isPlaylistable).map(\.id)
        guard !keys.isEmpty, screen.presentedViewController == nil else { return }
        Task { @MainActor [weak screen] in
            guard let screen else { return }
            let playlists: [PlexMetadata]
            do {
                playlists = PlaylistService.editable(try await PlaylistsFeed.playlists(api: env.api))
            } catch {
                MidgarLog.error("Playlists load failed: \(error.localizedDescription)", category: .networking)
                screen.presentAlert(title: String(localized: "Couldn\u{2019}t Load"), message: error.localizedDescription)
                return
            }
            guard screen.presentedViewController == nil else { return }
            let alert = UIAlertController(title: PlaylistFormat.addToPlaylist, message: nil, preferredStyle: .alert)
            for playlist in playlists {
                alert.addAction(UIAlertAction(title: playlist.title, style: .default) { _ in
                    add(keys, to: playlist, env: env, from: screen)
                })
            }
            alert.addAction(UIAlertAction(title: PlaylistFormat.newPlaylist, style: .default) { _ in
                promptForName(adding: keys, env: env, from: screen)
            })
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
            screen.present(alert, animated: TVMotion.animationsEnabled)
        }
    }

    private static func add(_ keys: [String], to playlist: PlexMetadata, env: TVAppEnvironment, from screen: UIViewController) {
        Task { @MainActor [weak screen] in
            do {
                try await PlaylistService.add(keys, toPlaylist: playlist.id, api: env.api)
                screen?.presentAlert(title: String(localized: "Added to \u{201C}\(playlist.title)\u{201D}"))
            } catch {
                screen?.presentAlert(title: String(localized: "Couldn\u{2019}t Add"), message: error.localizedDescription)
            }
        }
    }

    private static func promptForName(adding keys: [String], env: TVAppEnvironment, from screen: UIViewController) {
        let alert = UIAlertController(title: PlaylistFormat.namePrompt, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = PlaylistFormat.namePlaceholder
            field.accessibilityIdentifier = "playlist.name"
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: PlaylistFormat.create, style: .default) { [weak alert] _ in
            let name = alert?.textFields?.first?.text ?? ""
            Task { @MainActor [weak screen] in
                do {
                    guard let made = try await PlaylistService.create(title: name, adding: keys, api: env.api) else { return }
                    screen?.presentAlert(title: String(localized: "Added to \u{201C}\(made.title)\u{201D}"))
                } catch {
                    screen?.presentAlert(title: String(localized: "Couldn\u{2019}t Create"), message: error.localizedDescription)
                }
            }
        })
        screen.present(alert, animated: TVMotion.animationsEnabled)
    }
}

import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// The screens of a library's collections: the list of them and what is inside one.
@MainActor
enum CollectionScreens {
    static func collections(api: APIClient, sectionId: String, title: String) -> MediaGridViewController {
        let grid = MediaGridViewController(
            title: String(localized: "Collections"),
            empty: .init(
                symbol: "rectangle.stack",
                title: String(localized: "No Collections"),
                text: String(localized: "Collections you make in Plex appear here.")
            )
        ) {
            try await CollectionsFeed.collections(inSection: sectionId, api: api)
        }
        grid.configuration = { collection in
            PosterContentConfiguration(
                posterPath: collection.posterPath,
                title: collection.title,
                subtitle: CollectionFormat.countText(collection),
                placeholderIcon: "rectangle.stack"
            )
        }
        grid.onSelect = { [weak grid] collection in
            grid?.navigationController?.pushViewController(items(api: api, collection: collection), animated: true)
        }
        return grid
    }

    static func items(api: APIClient, collection: PlexMetadata) -> MediaGridViewController {
        let grid = MediaGridViewController(
            title: collection.title,
            empty: .init(symbol: "rectangle.stack", title: String(localized: "Empty Collection"), text: String(localized: "This collection has no titles."))
        ) {
            try await CollectionsFeed.items(inCollection: collection.id, api: api)
        }
        MediaGridActions.install(on: grid, api: api)
        return grid
    }

    /// Opens the collection a title's tag names, found by name in the title's library; says so when it cannot be found.
    static func open(named name: String, sectionId: String?, api: APIClient, from host: UIViewController) {
        guard let sectionId else { return }
        Task { @MainActor [weak host] in
            do {
                guard let collection = try await CollectionsFeed.collection(named: name, inSection: sectionId, api: api) else {
                    host?.presentSimpleAlert(title: name, message: String(localized: "This collection is no longer on the server."))
                    return
                }
                host?.navigationController?.pushViewController(items(api: api, collection: collection), animated: true)
            } catch {
                host?.presentSimpleAlert(title: String(localized: "Couldn\u{2019}t Load"), message: error.localizedDescription)
            }
        }
    }
}

extension UIViewController {
    func presentSimpleAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }
}

/// What a tap and a long press do on a grid of titles: open the detail, and the menu every poster shares.
@MainActor
enum MediaGridActions {
    static func install(on grid: MediaGridViewController, api: APIClient, extra: ((PlexMetadata) -> [UIMenuElement])? = nil) {
        grid.onSelect = { [weak grid] item in
            HomeMediaActions.openDetail(item, api: api, from: grid?.navigationController)
        }
        grid.contextMenu = { [weak grid] item in
            var children: [UIMenuElement] = [
                UIAction(title: String(localized: "View Details"), image: UIImage(systemName: "info.circle")) { _ in
                    HomeMediaActions.openDetail(item, api: api, from: grid?.navigationController)
                },
            ]
            if item.isPlaylistable, let grid {
                children.append(PlaylistMenu.addMenu(for: [item], api: api, host: grid))
            }
            children.append(contentsOf: extra?(item) ?? [])
            return UIMenu(children: children).addingNewWindow(for: item)
        }
    }
}

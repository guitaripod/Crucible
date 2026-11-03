import CrucibleCore
import UIKit

extension TVScreens {
    static func collections(_ env: TVAppEnvironment, sectionId: String) -> UIViewController {
        let grid = TVMediaGridViewController(
            title: String(localized: "Collections"),
            empty: .init(
                symbol: "rectangle.stack",
                title: String(localized: "No Collections"),
                message: String(localized: "Collections you make in Plex appear here.")
            ),
            card: { collection in
                TVCardItem(
                    id: collection.entryID,
                    artworkPath: collection.posterPath,
                    title: collection.title,
                    subtitle: CollectionFormat.countText(collection),
                    placeholderSymbol: "rectangle.stack"
                )
            },
            load: { try await CollectionsFeed.collections(inSection: sectionId, api: env.api) }
        )
        grid.summary = { items in items.count == 1 ? String(localized: "1 collection") : String(localized: "\(items.count) collections") }
        grid.onSelect = { [weak grid] collection in
            guard let grid else { return }
            TVNavigation.push(collectionItems(env, collection: collection), from: grid)
        }
        return grid
    }

    static func collectionItems(_ env: TVAppEnvironment, collection: PlexMetadata) -> UIViewController {
        let grid = TVMediaGridViewController(
            title: collection.title,
            empty: .init(symbol: "rectangle.stack", title: String(localized: "Empty Collection"), message: String(localized: "This collection has no titles.")),
            card: titleCard,
            load: { try await CollectionsFeed.items(inCollection: collection.id, api: env.api) }
        )
        installTitleActions(on: grid, env: env)
        return grid
    }

    /// Opens the collection a title's tag names, found by name in the title's library.
    static func openCollection(named name: String, sectionId: String?, env: TVAppEnvironment, from screen: UIViewController) {
        guard let sectionId else { return }
        Task { @MainActor [weak screen] in
            do {
                guard let collection = try await CollectionsFeed.collection(named: name, inSection: sectionId, api: env.api) else {
                    screen?.presentAlert(title: name, message: String(localized: "This collection is no longer on the server."))
                    return
                }
                guard let screen else { return }
                TVNavigation.push(collectionItems(env, collection: collection), from: screen)
            } catch {
                screen?.presentAlert(title: String(localized: "Couldn\u{2019}t Load"), message: error.localizedDescription)
            }
        }
    }

    static func titleCard(_ item: PlexMetadata) -> TVCardItem {
        let card = DetailRelatedCard(item: item)
        return TVCardItem(
            id: item.entryID,
            artworkPath: card.posterPath,
            title: card.title,
            subtitle: card.subtitle,
            progress: card.progress,
            isUnwatched: card.isUnwatched,
            placeholderSymbol: card.isShow ? "tv" : "film"
        )
    }

    /// Select opens a title's detail and a long press offers what every poster offers, plus `extra`.
    static func installTitleActions(on grid: TVMediaGridViewController, env: TVAppEnvironment, extra: ((PlexMetadata) -> [UIMenuElement])? = nil) {
        let actions = TVHomeActions(env: env, onChange: { [weak grid] in grid?.reload() })
        grid.onSelect = { [weak grid] item in
            guard let grid else { return }
            actions.openDetail(item, from: grid)
        }
        grid.contextMenu = { [weak grid] item in
            guard let grid else { return nil }
            let base = actions.menu(for: item, from: grid)
            guard let extra = extra?(item), !extra.isEmpty else { return base }
            return base.replacingChildren(base.children + [UIMenu(options: .displayInline, children: extra)])
        }
    }
}

import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// The grids a library opens from its header and shelves (`TVScreens.collections`, `TVRecentlyWatchedViewController`).
@MainActor
enum LibraryScreens {
    /// A library's collections; selecting one opens its titles.
    static func collections(api: APIClient, sectionId: String) -> TitleGridScreen {
        let grid = TitleGridScreen(api: api, title: String(localized: "Collections"), empty: .init(
            symbol: "rectangle.stack",
            title: String(localized: "No Collections"),
            message: String(localized: "Collections you make in Plex appear here.")
        )) { try await CollectionsFeed.collections(inSection: sectionId, api: api) }
        grid.card = { collection in
            CardItem(id: collection.entryID, artwork: collection.posterPath.map { .path($0, .poster) }, title: collection.title,
                     subtitle: CollectionFormat.countText(collection), placeholderSymbol: "rectangle.stack")
        }
        grid.summary = { items in items.count == 1 ? String(localized: "1 collection") : String(localized: "\(items.count) collections") }
        grid.onSelect = { [weak grid] collection in
            grid?.rootView?.push(collectionItems(api: api, collection: collection))
        }
        grid.onMenu = { _, _ in }
        return grid
    }

    static func collectionItems(api: APIClient, collection: PlexMetadata) -> TitleGridScreen {
        TitleGridScreen(api: api, title: collection.title, empty: .init(
            symbol: "rectangle.stack", title: String(localized: "Empty Collection"), message: String(localized: "This collection has no titles.")
        )) { try await CollectionsFeed.items(inCollection: collection.id, api: api) }
    }

    /// See All for a library's Recently Watched shelf: the play history as a grid of up to 120 titles, opening on the shelf's
    /// items and filling in once the longer history arrives, in the library grid's artwork shape.
    static func recentlyWatched(api: APIClient, sectionId: String, kind: LibraryGridKind, items: [PlexMetadata], aspect: Float) -> TitleGridScreen {
        let grid = TitleGridScreen(api: api, title: String(localized: "Recently Watched"), empty: .init(
            symbol: "clock", title: String(localized: "Nothing Watched Yet"), message: String(localized: "What you watch in this library appears here.")
        ), initial: items) {
            let loaded = await RecentlyWatched.load(api: api, sectionId: sectionId, groupingByShow: kind.groupsHistoryByShow, limit: RecentlyWatched.gridLimit)
            return loaded.isEmpty ? items : loaded
        }
        grid.aspect = aspect
        grid.summary = { _ in nil }
        grid.card = { LibraryCards.recent($0, kind: kind) }
        let actions = LibraryActions(api: api, kind: kind, host: grid) { [weak grid] item, watched in
            guard let grid else { return }
            Task { @MainActor [weak grid] in
                try? await WatchedService.setWatched(watched, ratingKey: item.id, api: api)
                grid?.reload()
            }
        }
        grid.onSelect = { actions.select($0, isRecent: true) }
        grid.onPlay = { actions.play($0, isRecent: true) }
        grid.onMenu = { actions.presentMenu(for: $0, isRecent: true, at: $1) }
        return grid
    }
}

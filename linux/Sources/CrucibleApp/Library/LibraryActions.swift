import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// What a library card does when chosen, played or right-clicked (`TVLibraryItemActions`), shared by the library grid, its
/// Recently Watched shelf and See All, and the folder browser, so Select, Play and the menu agree. A Recently Watched card
/// opens its film or series and always plays from the start.
@MainActor
final class LibraryActions {
    private let api: APIClient
    private let kind: LibraryGridKind
    private weak var host: View?
    private let setWatched: (PlexMetadata, Bool) -> Void

    init(api: APIClient, kind: LibraryGridKind, host: View, setWatched: @escaping (PlexMetadata, Bool) -> Void) {
        self.api = api
        self.kind = kind
        self.host = host
        self.setWatched = setWatched
    }

    /// Starts a playable item; false for anything else (a show), so the Play key can pass the press on.
    @discardableResult
    func play(_ item: PlexMetadata, isRecent: Bool) -> Bool {
        guard HomeMediaRules.isPlayable(item), let host else { return false }
        host.rootView?.play(item: item, api: api, from: isRecent ? 0 : nil)
        return true
    }

    /// The card's hover watched toggle: watched when the card is not, unwatched when it is.
    func toggleWatched(_ item: PlexMetadata, card: CardItem) {
        setWatched(item, !card.isWatched)
    }

    func select(_ item: PlexMetadata, isRecent: Bool) {
        open(isRecent ? LibraryDestination(recent: item, kind: kind) : LibraryDestination(browsing: item))
    }

    /// The card's menu: Core's library actions for a grid poster or a Recently Watched card.
    func presentMenu(for item: PlexMetadata, isRecent: Bool, at point: Point?) {
        guard let host, let window = host.window else { return }
        let actions = isRecent ? LibraryItemAction.recent(for: item, kind: kind) : LibraryItemAction.grid(for: item, kind: kind)
        let items = actions.enumerated().map { index, action in
            MenuView.Item(id: String(index), title: action.title, symbol: Symbol(action.symbol))
        }
        let frame = window.focusedView?.frameInWindow ?? host.frameInWindow
        let anchor = Rect(x: point.map { $0.x } ?? frame.minX, y: point.map { $0.y } ?? frame.maxY, width: 1, height: 1)
        let menu = MenuView(title: isRecent ? (LibraryPoster(recent: item, kind: kind).title) : item.title, items: items, anchor: anchor)
        menu.onSelect = { [weak self] chosen in
            guard let self, let index = Int(chosen.id), actions.indices.contains(index) else { return }
            self.perform(actions[index], on: item, isRecent: isRecent)
        }
        menu.present(in: window)
    }

    private func perform(_ action: LibraryItemAction, on item: PlexMetadata, isRecent: Bool) {
        switch action.kind {
        case .play:
            play(item, isRecent: isRecent)
        case .playFromBeginning:
            guard HomeMediaRules.isPlayable(item) else { return }
            host?.rootView?.play(item: item, api: api, from: 0)
        case .setWatched(let watched):
            setWatched(item, watched)
        case .goToShow(let showKey):
            open(.show(ratingKey: showKey))
        case .viewDetails:
            open(isRecent ? .media(item) : LibraryDestination(browsing: item))
        }
    }

    private func open(_ destination: LibraryDestination?) {
        guard let destination, let host else { return }
        switch destination {
        case .show(let ratingKey):
            host.rootView?.push(DetailScreen.make(api: api, route: .show(ratingKey: ratingKey, initialSeasonKey: nil)))
        case .media(let item):
            host.rootView?.push(DetailScreen.make(api: api, item: item))
        }
    }
}

/// The cards library screens draw (`TVLibraryMapping`).
@MainActor
enum LibraryCards {
    /// A poster of the library grid. Movies carry progress, the unwatched dot or the watched check; shows the count of
    /// unwatched episodes.
    static func grid(_ item: PlexMetadata, kind: LibraryGridKind) -> CardItem {
        let poster = LibraryPoster(grid: item, kind: kind)
        return CardItem(id: item.id, artwork: poster.posterPath.map { .path($0, .poster) }, title: poster.title, subtitle: poster.subtitle,
                        progress: poster.progress, isUnwatched: poster.isUnwatched, isWatched: kind == .movie && item.isWatched,
                        badgeText: poster.unwatchedCount.map { String(localized: "\($0) unwatched") }, placeholderSymbol: Symbol(poster.placeholderIcon))
            .linked(to: item)
    }

    static func recent(_ item: PlexMetadata, kind: LibraryGridKind) -> CardItem {
        let poster = LibraryPoster(recent: item, kind: kind)
        return CardItem(id: item.id, artwork: poster.posterPath.map { .path($0, .poster) }, title: poster.title, subtitle: poster.subtitle,
                        placeholderSymbol: Symbol(poster.placeholderIcon)).linked(to: item)
    }

    /// A folder entry. Movies and episodes carry progress, the unwatched dot or the watched check.
    static func folder(_ item: PlexMetadata) -> CardItem {
        let poster = LibraryPoster(folderItem: item)
        let tracksWatched = HomeMediaRules.isPlayable(item)
        let progress = item.progressFraction
        return CardItem(id: item.id, artwork: poster.posterPath.map { .path($0, .poster) }, title: poster.title, subtitle: poster.subtitle,
                        progress: tracksWatched && progress > 0 ? progress : nil, isUnwatched: tracksWatched && !item.isWatched && progress <= 0,
                        isWatched: tracksWatched && item.isWatched, placeholderSymbol: Symbol(poster.placeholderIcon)).linked(to: item)
    }

    /// The samples a grid's shape is read from: each card's image and the shape its kind of item has.
    static func samples(_ posters: [LibraryPoster]) -> [ArtworkAspect.Sample] {
        posters.map { ArtworkAspect.Sample(path: $0.posterPath, guess: $0.aspect) }
    }
}

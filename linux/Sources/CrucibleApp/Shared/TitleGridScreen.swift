import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// A screen of titles in a poster grid (`TVMediaGridViewController`): a collection, a person's films, a playlist. It
/// loads every time it appears, keeps what it showed while a reload runs, and opens a title's page on select; a right
/// click offers what every poster offers.
@MainActor
final class TitleGridScreen: ScreenView {
    struct Empty {
        var symbol: Symbol = "rectangle.stack"
        var title = String(localized: "Nothing Here")
        var message = String(localized: "This list is empty right now.")
    }

    var summary: ([PlexMetadata]) -> String? = { items in
        items.count == 1 ? String(localized: "1 title") : String(localized: "\(items.count) titles")
    }

    private let api: APIClient
    private let empty: Empty
    private let load: () async throws -> [PlexMetadata]
    private let page = PageView()
    private let heading: ScreenTitleView
    private let grid = CardGridView()
    private let state = StateView()
    private var items: [String: PlexMetadata] = [:]
    private var hasLoaded = false
    private var loadTask: Task<Void, Never>?

    init(api: APIClient, title: String, empty: Empty = Empty(), load: @escaping () async throws -> [PlexMetadata]) {
        self.api = api
        self.empty = empty
        self.load = load
        heading = ScreenTitleView(title: title)
        super.init()
        [page, state].forEach(addSubview)
        page.setSections([heading, grid])
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        grid.onActivate = { [weak self] card in
            guard let self, let item = self.items[card.id] else { return }
            self.rootView?.push(DetailScreen.make(api: self.api, item: item))
        }
        grid.onContextMenu = { [weak self] card, point in
            guard let self, let item = self.items[card.id] else { return }
            ItemActions.present(for: item, api: self.api, at: point, in: self) { [weak self] in self?.reload() }
        }
        state.show(.loading(title: nil))
    }

    override var preferredFocusView: View? { state.isHidden ? grid : state }

    override func screenDidAppear() {
        reload()
    }

    override func screenWillDisappear() {
        loadTask?.cancel()
    }

    func reload() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.load()
                guard !Task.isCancelled else { return }
                self.hasLoaded = true
                self.display(loaded)
            } catch {
                guard !Task.isCancelled, !self.hasLoaded else { return }
                MidgarLog.error("Grid load failed: \(error)", category: .networking)
                self.state.isHidden = false
                self.state.show(.error(title: String(localized: "Couldn’t Load"), message: ConnectionError.message(for: error),
                                       retryTitle: String(localized: "Retry"), retry: { [weak self] in
                                           self?.state.show(.loading(title: nil))
                                           self?.reload()
                                       }))
            }
        }
    }

    private func display(_ loaded: [PlexMetadata]) {
        items = Dictionary(loaded.map { ($0.entryID, $0) }, uniquingKeysWith: { first, _ in first })
        grid.setItems(loaded.map(TitleCards.card))
        heading.summary = summary(loaded)
        if loaded.isEmpty {
            state.isHidden = false
            state.show(.empty(title: empty.title, message: empty.message, symbol: empty.symbol, action: nil))
        } else {
            state.isHidden = true
        }
        page.setNeedsLayout()
    }

    override func layoutSubviews() {
        page.topInset = Theme.current.metrics.tabBarClearance
        page.frame = bounds
        state.frame = bounds
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

/// The card every list of titles draws for a movie, show or episode (`TVScreens.titleCard`).
@MainActor
enum TitleCards {
    static func card(_ item: PlexMetadata) -> CardItem {
        let card = DetailRelatedCard(item: item)
        return CardItem(id: item.entryID, artwork: card.posterPath.map { .path($0, .poster) }, title: card.title, subtitle: card.subtitle,
                        progress: card.progress, isUnwatched: card.isUnwatched, placeholderSymbol: card.isShow ? "tv" : "film")
    }
}

extension TitleGridScreen: Reloadable {}

import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// Home (`TVHomeViewController`): the backdrop follows the focused card, the hero tells what it is, and the shelves are
/// the shared Home arrangement: Continue Watching, Up Next and Recently Added, in the order the viewer keeps them.
@MainActor
final class HomeScreen: ScreenView {
    private let payload: LaunchPayload
    private let feed: HomeFeed
    private let backdrop = BackdropView()
    private let hero = HeroInfoView()
    private let page = PageView()
    private let heroRoom = SpacerView(height: 0)
    private let state = StateView()
    private var shelves: [HomeBucket: ShelfView] = [:]
    private var refreshTask: Task<Void, Never>?
    private var lastRefresh = Date()

    init(payload: LaunchPayload) {
        self.payload = payload
        feed = HomeFeed(api: payload.api)
        super.init()
        [backdrop, hero, page, state].forEach(addSubview)
        state.isHidden = true
        page.onScroll = { [weak self] offset in self?.scrolled(offset) }
        feed.apply(container: payload.hubs)
        render()
    }

    override var preferredFocusView: View? {
        state.isHidden ? page.sections.first { $0 is ShelfView } : state
    }

    override func screenDidAppear() {
        guard Date().timeIntervalSince(lastRefresh) > 60 else { return }
        refresh()
    }

    private func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await feed.refresh()
                lastRefresh = Date()
                render()
            } catch {
                MidgarLog.error("Home refresh failed: \(error)", category: .networking)
                if feed.isEmpty { showFailure(error) }
            }
        }
    }

    private func showFailure(_ error: Error) {
        state.isHidden = false
        page.isHidden = true
        state.show(.error(title: String(localized: "Couldn’t Load Home"), message: ConnectionError.message(for: error),
                          retryTitle: String(localized: "Try Again"), retry: { [weak self] in self?.refresh() }))
    }

    /// Paints the arrangement: the hero item at the head of its rail, then the rails the viewer keeps on Home.
    private func render() {
        let arrangement = feed.arrangement
        guard !arrangement.isEmpty else {
            let copy = HomeStateCopy.empty(librariesAreFiltered: LibraryVisibility.isCustomized, rowsAreHidden: HomeLayout.contentRowsAreOff)
            state.isHidden = false
            page.isHidden = true
            state.show(.empty(title: copy.title, message: copy.message, symbol: "house", action: nil))
            return
        }
        state.isHidden = true
        page.isHidden = false
        var sections: [View] = [heroRoom]
        var used = Set<HomeBucket>()
        for row in HomeLayout.visibleRows() {
            let bucket: HomeBucket
            switch row {
            case .continueWatching: bucket = .continueWatching
            case .upNext: bucket = .upNext
            case .recentlyAdded: bucket = .recentlyAdded
            default: continue
            }
            let items = arrangement.shelf(for: bucket)
            guard !items.isEmpty else { continue }
            let shelf = shelves[bucket] ?? makeShelf(bucket)
            shelf.header = SectionHeader(title: arrangement.title(for: bucket))
            shelf.setItems(items.map { card(for: $0, bucket: bucket) })
            sections.append(shelf)
            used.insert(bucket)
        }
        for (bucket, shelf) in shelves where !used.contains(bucket) {
            shelf.removeFromSuperview()
            shelves[bucket] = nil
        }
        page.setSections(sections)
        if let first = arrangement.hero { feature(first, bucket: .hero, animated: false) }
        setNeedsLayout()
    }

    private func makeShelf(_ bucket: HomeBucket) -> ShelfView {
        let shelf = ShelfView(header: nil, style: bucket == .recentlyAdded ? .poster : .landscape)
        shelf.onFocus = { [weak self] item in
            guard let self, let media = self.feed.item(id: item.id) else { return }
            self.feature(media, bucket: bucket, animated: true)
        }
        shelf.onActivate = { [weak self] item in
            guard let self, let media = self.feed.item(id: item.id) else { return }
            self.open(media)
        }
        shelf.onContextMenu = { [weak self] item, point in
            guard let self, let media = self.feed.item(id: item.id) else { return }
            ItemActions.present(for: media, api: self.payload.api, at: point, in: self) { [weak self] in self?.refresh() }
        }
        shelves[bucket] = shelf
        return shelf
    }

    private func card(for media: PlexMetadata, bucket: HomeBucket) -> CardItem {
        let layout: HomeCardModel.Layout = bucket == .recentlyAdded ? .poster : .landscape
        let model = HomeCardModel(item: media, bucket: bucket, layout: layout)
        return CardItem(
            id: model.id,
            artwork: model.imagePath.map { .path($0, layout == .poster ? .poster : .backdrop) },
            title: model.title,
            subtitle: model.subtitle,
            detail: model.trailingText,
            eyebrow: model.news?.eyebrow,
            progress: model.progress,
            isUnwatched: model.isUnwatched,
            badgeText: model.news?.badge.uppercased(),
            placeholderSymbol: model.usesSeriesPlaceholder ? "tv" : "film"
        )
    }

    /// The hero and backdrop show the focused item.
    private func feature(_ media: PlexMetadata, bucket: HomeBucket, animated: Bool) {
        let continuing = bucket == .continueWatching || (bucket == .hero && feed.arrangement.heroIsContinue)
        let model = feed.heroModel(for: media, bucket: bucket, continuing: continuing)
        hero.configure(HeroInfo(eyebrow: model.eyebrow, title: model.title, metaParts: model.metaParts, badges: model.badges,
                                synopsis: media.summary, progress: model.progress), animated: animated)
        let path = HomeHeroModel.backdropPath(for: media, cachedArt: feed.cachedArt)
        backdrop.show(path.map { .path($0, .backdrop) }, immediate: !animated)
    }

    private func open(_ media: PlexMetadata) {
        rootView?.push(DetailScreen.make(api: payload.api, item: media))
    }

    private func scrolled(_ offset: Float) {
        hero.translation = Point(x: 0, y: -offset)
        backdrop.dimming = min(max(offset / max(heroRoom.height * 0.8, 1), 0), 1)
        rootView?.contentScrolled(offset: offset)
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        backdrop.frame = bounds
        page.frame = bounds
        state.frame = bounds
        let heroHeight = max(metrics.heroHeight, min(frame.height * 0.52, frame.width * 0.3))
        heroRoom.height = heroHeight
        hero.frame = Rect(x: metrics.sideMargin, y: metrics.heroTopClearance, width: frame.width - metrics.sideMargin * 2,
                          height: heroHeight - metrics.heroTopClearance - metrics.heroBottomClearance)
        page.setNeedsLayout()
    }
}

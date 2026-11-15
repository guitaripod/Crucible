import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// Home (`TVHomeViewController`): the backdrop and hero follow the focused card over the rows the viewer keeps on Home, in
/// their order: Continue Watching, Up Next, Recently Added with Surprise Me, Out Now on Your Watchlist and Rate What You
/// Watched. The launch payload paints the first frame; every later appearance reloads, the server's change events reload
/// within seconds, and a reload that fails keeps what is on screen.
@MainActor
final class HomeScreen: ScreenView {
    private enum Row: String {
        case continueWatching, upNext, recentlyAdded, releases, rate
    }

    private let payload: LaunchPayload
    private let feed: HomeFeed
    private let backdrop = BackdropView()
    private let hero = HeroInfoView()
    private let page = PageView()
    private let heroRoom = SpacerView(height: 0)
    private let state = StateView()
    private let skeleton = [SkeletonShelfView(style: .landscape), SkeletonShelfView(style: .landscape)]
    private var shelves: [Row: ShelfView] = [:]
    private var refreshTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var asksTask: Task<Void, Never>?
    private var releasesTask: Task<Void, Never>?
    private var skipNextAppearanceLoad = true
    private lazy var rateFeed = RatingAsksFeed(api: payload.api)
    private var asks: [RatingAsk] = []
    private var pendingRated = Set<String>()
    private var releases: [WatchlistRelease] = []
    /// The next episodes the server lacks of shows the viewer is caught up on, at the end of Up Next.
    private var missingNext: [MissingNext] = []
    private var missingNextTask: Task<Void, Never>?
    private var observers: [() -> Void] = []
    private static let surpriseID = "home.surprise"
    private static let watchID = "home.watch"

    init(payload: LaunchPayload) {
        self.payload = payload
        feed = HomeFeed(api: payload.api)
        super.init()
        [backdrop, hero, page, state].forEach(addSubview)
        for shelf in skeleton { shelf.count = 4 }
        state.isHidden = true
        page.onScroll = { [weak self] offset in self?.scrolled(offset) }
        feed.apply(container: payload.hubs)
        asks = rateFeed.current()
        releases = WatchlistReleases.shared.releases()
        missingNext = UpNextGaps.shared.entries(nextUp: feed.nextUpItems)
        observe()
        render()
    }

    isolated deinit {
        observers.forEach { $0() }
        liveTask?.cancel()
    }

    /// Keeps the rows in step with what the rest of the app changes: libraries shown on Home, the rows themselves,
    /// titles finished or rated, and new releases of watchlisted shows.
    private func observe() {
        let visibility = LibraryVisibility.addObserver { [weak self] in self?.homeSettingsChanged() }
        let layout = HomeLayout.addObserver { [weak self] in self?.homeSettingsChanged() }
        let ledger = FinishedTitlesLedger.shared.addObserver { [weak self] in
            guard let self else { return }
            self.adoptAsks(self.rateFeed.current())
        }
        let watchlist = WatchlistReleases.shared.addObserver { [weak self] in self?.releasesChanged() }
        let gaps = UpNextGaps.shared.addObserver { [weak self] in self?.missingNextChanged() }
        observers = [
            { LibraryVisibility.removeObserver(visibility) },
            { HomeLayout.removeObserver(layout) },
            { FinishedTitlesLedger.shared.removeObserver(ledger) },
            { WatchlistReleases.shared.removeObserver(watchlist) },
            { UpNextGaps.shared.removeObserver(gaps) },
        ]
    }

    /// The first card of the first row in a fixed order, whatever order the rows are in.
    override var preferredFocusView: View? {
        guard state.isHidden else { return state }
        for row in [Row.continueWatching, .upNext, .recentlyAdded, .releases, .rate] {
            if let shelf = shelves[row], shelf.superview != nil { return shelf }
        }
        return nil
    }

    override func screenDidAppear() {
        loadAsks()
        loadReleases()
        loadMissingNext()
        if skipNextAppearanceLoad {
            skipNextAppearanceLoad = false
        } else {
            reload()
        }
        let api = payload.api
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            await ServerEventHub.shared.listen(api: api, every: .seconds(3), matching: \.changesHome) { self?.reload() }.hold()
        }
    }

    override func screenWillDisappear() {
        liveTask?.cancel()
        liveTask = nil
    }

    /// Ctrl+R and the server's change events.
    func reload() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.feed.refresh()
                WatchlistReleases.shared.noteOnServer(self.feed.fetchedItems)
                self.missingNext = UpNextGaps.shared.entries(nextUp: self.feed.nextUpItems)
                self.render()
                self.loadMissingNext()
            } catch {
                guard !Task.isCancelled else { return }
                MidgarLog.error("Home refresh failed: \(error)", category: .networking)
                if self.feed.isEmpty { self.showLoadError(error) } else { self.render() }
            }
        }
    }

    private func retry() {
        state.isHidden = true
        page.isHidden = false
        page.setSections([heroRoom] + skeleton)
        reload()
    }

    private func showLoadError(_ error: Error) {
        let copy = HomeStateCopy.loadFailed(error)
        backdrop.show(nil, immediate: true)
        hero.configure(nil, animated: false)
        state.isHidden = false
        page.isHidden = true
        state.show(.error(title: copy.title, message: copy.message, retryTitle: String(localized: "Retry"), retry: { [weak self] in self?.retry() }))
    }

    private func homeSettingsChanged() {
        feed.reapplyLibraryVisibility()
        asks = rateFeed.current()
        render()
        loadReleases()
    }

    /// Paints the rows the viewer keeps on Home, or why Home is empty.
    private func render() {
        let arrangement = feed.arrangement
        guard !feed.isEmpty else {
            let copy = HomeStateCopy.empty(librariesAreFiltered: LibraryVisibility.isCustomized, rowsAreHidden: HomeLayout.contentRowsAreOff)
            backdrop.show(nil, immediate: true)
            hero.configure(nil, animated: false)
            state.isHidden = false
            page.isHidden = true
            state.show(.empty(title: copy.title, message: copy.message, symbol: "play.rectangle",
                              action: StateView.Action(title: String(localized: "Refresh", comment: "Button that retries loading the home screen")) { [weak self] in
                                  self?.retry()
                              }))
            return
        }
        let hadFocus = !state.isHidden
        if hadFocus { page.fadeIn() }
        state.isHidden = true
        page.isHidden = false
        var sections: [View] = [heroRoom]
        var used = Set<Row>()
        func add(_ row: Row, title: String, seeAll: HomeBucket?, items: [CardItem]) {
            guard !items.isEmpty else { return }
            let shelf = shelves[row] ?? makeShelf(row)
            shelf.header = SectionHeader(title: title, hasSeeAll: seeAll != nil)
            shelf.onSeeAll = seeAll.map { bucket in { [weak self] in self?.showAll(bucket) } }
            shelf.setItems(items)
            sections.append(shelf)
            used.insert(row)
        }
        for row in HomeLayout.visibleRows() {
            switch row {
            case .continueWatching:
                add(.continueWatching, title: arrangement.title(for: .continueWatching), seeAll: nil,
                    items: arrangement.shelf(for: .continueWatching).map { card(for: $0, bucket: .continueWatching) })
            case .upNext:
                let missing = arrangement.isEmpty ? [] : missingNext.map(card(for:))
                add(.upNext, title: arrangement.title(for: .upNext), seeAll: .upNext,
                    items: arrangement.shelf(for: .upNext).map { card(for: $0, bucket: .upNext) } + missing)
            case .recentlyAdded where !arrangement.recent.isEmpty:
                let surprise = CardItem(id: Self.surpriseID, title: String(localized: "Surprise Me"), subtitle: String(localized: "A random pick"),
                                        placeholderSymbol: "shuffle")
                var tiles = [surprise]
                if HostedBrain.isAvailable {
                    tiles.append(CardItem(id: Self.watchID, title: WatchCopy.title, subtitle: WatchCopy.tileSubtitle, placeholderSymbol: "wand.and.stars"))
                }
                add(.recentlyAdded, title: arrangement.title(for: .recentlyAdded), seeAll: .recentlyAdded,
                    items: arrangement.recent.map { card(for: $0, bucket: .recentlyAdded) } + tiles)
            case .watchlistReleases where !arrangement.isEmpty:
                add(.releases, title: WatchlistReleaseCopy.rowTitle, seeAll: nil, items: releases.map(card(for:)))
            case .rateWatched where !arrangement.isEmpty:
                add(.rate, title: RatingAskCopy.rowTitle, seeAll: nil, items: visibleAsks.map(card(for:)))
            default:
                break
            }
        }
        for (row, shelf) in shelves where !used.contains(row) {
            shelf.removeFromSuperview()
            shelves[row] = nil
        }
        page.setSections(sections)
        if let first = arrangement.hero, window?.focusedView?.isDescendant(of: page) != true { feature(first, bucket: .hero, animated: false) }
        if hadFocus, let target = preferredFocusView { window?.focus.focus(target, animated: false) }
        setNeedsLayout()
    }

    private func makeShelf(_ row: Row) -> ShelfView {
        let style: CardStyle = row == .continueWatching || row == .upNext ? .landscape : .poster
        let shelf = ShelfView(header: nil, style: style)
        shelf.onFocus = { [weak self] item in
            guard let self, let bucket = Self.bucket(row), let media = self.feed.item(id: item.id) else { return }
            self.feature(media, bucket: bucket, animated: true)
        }
        shelf.onActivate = { [weak self] item in self?.activate(item.id, in: row) }
        shelf.onPlay = { [weak self] item in
            guard let self, Self.bucket(row) != nil, let media = self.feed.item(id: item.id) else { return false }
            return ItemActions.playPause(media, api: self.payload.api, from: self)
        }
        shelf.onContextMenu = { [weak self] item, point in self?.presentMenu(for: item.id, in: row, at: point) }
        shelves[row] = shelf
        return shelf
    }

    private static func bucket(_ row: Row) -> HomeBucket? {
        switch row {
        case .continueWatching: .continueWatching
        case .upNext: .upNext
        case .recentlyAdded: .recentlyAdded
        case .releases, .rate: nil
        }
    }

    private func activate(_ id: String, in row: Row) {
        let api = payload.api
        switch row {
        case .rate:
            if let ask = asks.first(where: { $0.id == id }) { rate(ask) }
        case .releases:
            if let release = releases.first(where: { $0.id == id }) { SeerrRequestScreen.open(release.asMetadata, api: api, isOnServer: false, from: self) }
        default:
            if let entry = missingNext.first(where: { $0.id == id }) {
                rootView?.push(DetailScreen.make(api: api, route: .show(ratingKey: entry.showRatingKey, initialSeasonKey: entry.initialSeasonKey)))
            } else if id == Self.watchID {
                rootView?.push(WhatToWatchAskScreen(api: api))
            } else if id == Self.surpriseID {
                presentSurpriseMenu()
            } else if let bucket = Self.bucket(row), let media = feed.item(id: id) {
                ItemActions.select(media, in: bucket, api: api, from: self)
            }
        }
    }

    private func presentMenu(for id: String, in row: Row, at point: Point?) {
        switch row {
        case .rate:
            if let ask = asks.first(where: { $0.id == id }) { presentAskMenu(ask, at: point) }
        case .releases:
            if let release = releases.first(where: { $0.id == id }) { presentReleaseMenu(release, at: point) }
        default:
            if let entry = missingNext.first(where: { $0.id == id }) { return presentMissingNextMenu(entry, at: point) }
            guard let media = feed.item(id: id) else { return }
            ItemActions.present(for: media, bucket: Self.bucket(row), api: payload.api, at: point, in: self) { [weak self] in self?.reload() }
        }
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

    private func card(for ask: RatingAsk) -> CardItem {
        CardItem(id: ask.id, artwork: ask.posterPath.map { .path($0, .poster) }, title: ask.title, subtitle: ask.caption(now: Date()),
                 placeholderSymbol: ask.isShow ? "tv" : "film")
    }

    /// The next episode of a show the viewer is caught up on that aired and the server lacks: dimmed, "S3 · E5 · Not on your
    /// server"; it opens the show on that season.
    private func card(for entry: MissingNext) -> CardItem {
        CardItem(id: entry.id, artwork: (entry.artPath ?? entry.posterPath).map { .path($0, .backdrop) }, title: entry.showTitle, subtitle: entry.caption,
                 isDimmed: true, placeholderSymbol: "tv")
    }

    private func card(for release: WatchlistRelease) -> CardItem {
        CardItem(id: release.id, artwork: release.posterPath.map { .path($0, .poster) }, title: release.title, subtitle: release.caption(now: Date()),
                 badgeText: release.news.badge.uppercased(), placeholderSymbol: "tv")
    }

    /// The hero and backdrop show the focused card.
    private func feature(_ media: PlexMetadata, bucket: HomeBucket, animated: Bool) {
        let continuing = bucket == .continueWatching || (bucket == .hero && feed.arrangement.heroIsContinue)
        let model = feed.heroModel(for: media, bucket: bucket, continuing: continuing)
        hero.configure(HeroInfo(eyebrow: model.eyebrow, title: model.title, metaParts: model.metaParts, badges: model.badges,
                                synopsis: media.summary, progress: model.progress), animated: animated)
        backdrop.show(model.backdropPath.map { .path($0, .backdrop) }, immediate: !animated)
    }

    // MARK: See All

    private func showAll(_ bucket: HomeBucket) {
        let screen = HomeSeeAllScreen(api: payload.api, bucket: bucket, title: feed.arrangement.title(for: bucket),
                                      items: { [weak self] in self?.feed.arrangement.shelf(for: bucket) ?? [] }) { [weak self] in self?.reload() }
        rootView?.push(screen)
    }

    // MARK: Surprise Me

    private func presentSurpriseMenu() {
        guard let window else { return }
        var actions = [SurpriseMe.Kind.any, .movie, .show].map { kind in
            AlertView.Action(kind.menuTitle) { [weak self] in self?.surprise(kind) }
        }
        actions.append(AlertView.Action(String(localized: "Cancel"), role: .cancel))
        AlertView(title: String(localized: "Surprise Me"), actions: actions).present(in: window)
    }

    private func surprise(_ kind: SurpriseMe.Kind) {
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let pick = try await self.feed.surprise(kind) else {
                    self.notice(SurpriseMe.nothingToPickTitle, message: SurpriseMe.nothingToPickMessage(for: kind))
                    return
                }
                switch pick {
                case .movie(let key): self.rootView?.push(DetailScreen.make(api: self.payload.api, route: .item(ratingKey: key, mediaType: "movie",
                                                                                                               showRatingKey: nil, seasonRatingKey: nil)))
                case .show(let key): self.rootView?.push(DetailScreen.make(api: self.payload.api, route: .show(ratingKey: key, initialSeasonKey: nil)))
                }
            } catch let failure as SurpriseMe.LookupFailure {
                self.notice(SurpriseMe.lookupFailedTitle, message: failure.message)
            } catch {
                return
            }
        }
    }

    private func notice(_ title: String, message: String?) {
        guard let window else { return }
        AlertView.notice(title: title, message: message, in: window)
    }

    // MARK: Rate What You Watched

    private var visibleAsks: [RatingAsk] { asks.filter { !pendingRated.contains($0.id) } }

    private func loadAsks() {
        asksTask?.cancel()
        asksTask = Task { [weak self] in
            guard let self else { return }
            let loaded = await self.rateFeed.load()
            guard !Task.isCancelled else { return }
            self.adoptAsks(loaded)
        }
    }

    private func adoptAsks(_ loaded: [RatingAsk]) {
        pendingRated = pendingRated.filter { key in loaded.contains { $0.id == key } }
        guard loaded != asks else { return }
        asks = loaded
        render()
    }

    /// The half-star panel for a title the viewer finished; its card leaves at once, and comes back if the server refuses.
    private func rate(_ ask: RatingAsk) {
        guard let window else { return }
        let api = payload.api
        let panel = RatingPanelView(title: RatingAskCopy.question(for: ask), halfStars: nil, clearTitle: String(localized: "Clear Rating"))
        panel.onCommit = { [weak self] halfStars in
            guard let rating = halfStars.flatMap(UserRating.init(halfStars:)) else { return }
            self?.pendingRated.insert(ask.id)
            self?.render()
            Task { [weak self] in
                do {
                    try await RatingService.setRating(rating, ratingKey: ask.ratingKey, api: api)
                } catch {
                    self?.pendingRated.remove(ask.id)
                    self?.render()
                    self?.notice(String(localized: "Couldn’t Save Rating", comment: "Alert title when the server refused a star rating"), message: nil)
                }
            }
        }
        panel.present(in: window)
    }

    private func presentAskMenu(_ ask: RatingAsk, at point: Point?) {
        guard let window else { return }
        let menu = MenuView(title: ask.title, items: [
            .init(id: "rate", title: UserRatingCopy.rate, symbol: "star"),
            .init(id: "details", title: String(localized: "View Details"), symbol: "info.circle"),
            .init(id: "notNow", title: RatingAskCopy.notNow, symbol: "xmark.circle"),
        ], anchor: menuAnchor(point))
        menu.onSelect = { [weak self] item in
            guard let self else { return }
            switch item.id {
            case "rate": self.rate(ask)
            case "details":
                let route: DetailRoute = ask.isShow ? .show(ratingKey: ask.ratingKey, initialSeasonKey: nil)
                    : .item(ratingKey: ask.ratingKey, mediaType: ask.mediaType, showRatingKey: nil, seasonRatingKey: nil)
                self.rootView?.push(DetailScreen.make(api: self.payload.api, route: route))
            case "notNow": FinishedTitlesLedger.shared.dismiss(ask.ratingKey)
            default: break
            }
        }
        menu.present(in: window)
    }

    // MARK: Out Now on Your Watchlist

    /// Looks for new seasons and episodes of watchlisted shows while their row is on Home; a look under six hours old stands.
    private func loadReleases() {
        guard HomeLayout.isOn(.watchlistReleases) else { return }
        let api = payload.api
        releasesTask?.cancel()
        releasesTask = Task { await WatchlistReleases.shared.refresh(api: api) }
    }

    private func releasesChanged() {
        let current = WatchlistReleases.shared.releases()
        guard current != releases else { return }
        releases = current
        render()
    }

    /// Request (with Seerr connected) and Remove from Watchlist.
    private func presentReleaseMenu(_ release: WatchlistRelease, at point: Point?) {
        guard let window else { return }
        let api = payload.api, token = payload.api.token
        var items: [MenuView.Item] = []
        if SeerrAccount.shared.isConnected { items.append(.init(id: "request", title: SeerrCopy.request, symbol: "plus.circle")) }
        items.append(.init(id: "remove", title: WatchlistService.remove, symbol: "bookmark.slash", isDestructive: true))
        let menu = MenuView(title: release.title, items: items, anchor: menuAnchor(point))
        menu.onSelect = { [weak self] chosen in
            guard let self else { return }
            guard chosen.id == "remove" else {
                SeerrRequestScreen.open(release.asMetadata, api: api, isOnServer: false, from: self)
                return
            }
            Task { [weak self] in
                do {
                    try await WatchlistService.remove(guid: release.guid, token: token)
                } catch {
                    self?.notice(String(localized: "Couldn’t Update"), message: ConnectionError.message(for: error))
                }
            }
        }
        menu.present(in: window)
    }

    // MARK: Missing next episodes

    /// Looks for the next episode, aired but not on the server, of the shows the viewer is caught up on, once Home's own
    /// rows have said which shows the server has a next episode for.
    private func loadMissingNext() {
        guard HomeLayout.isOn(.upNext) else { return }
        let api = payload.api
        let candidates = UpNextGaps.candidates(followed: FollowedShows.recentlyFinished(), nextUp: feed.nextUpItems)
        missingNextTask?.cancel()
        missingNextTask = Task { await UpNextGaps.shared.refresh(api: api, candidates: candidates) }
    }

    private func missingNextChanged() {
        let current = UpNextGaps.shared.entries(nextUp: feed.nextUpItems)
        guard current != missingNext else { return }
        missingNext = current
        render()
    }

    /// Request through Seerr, when it is connected.
    private func presentMissingNextMenu(_ entry: MissingNext, at point: Point?) {
        guard SeerrAccount.shared.isConnected, let window else { return }
        let api = payload.api
        let menu = MenuView(title: entry.showTitle, items: [.init(id: "request", title: SeerrCopy.request, symbol: "plus.circle")], anchor: menuAnchor(point))
        menu.onSelect = { [weak self] _ in
            guard let self else { return }
            SeerrRequestScreen.open(entry.showMetadata, api: api, isOnServer: true, from: self)
        }
        menu.present(in: window)
    }

    private func menuAnchor(_ point: Point?) -> Rect {
        let frame = window?.focusedView?.frameInWindow ?? frameInWindow
        return Rect(x: point?.x ?? frame.minX, y: point?.y ?? frame.maxY, width: 1, height: 1)
    }

    // MARK: Layout

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

/// See All for a Home row (`TVHomeSeeAllViewController`): every card of the row in a grid, posters for Recently Added and
/// landscape cards for the others, with the row's card actions; it follows Home's refreshes while it is open.
@MainActor
final class HomeSeeAllScreen: ScreenView {
    private let api: APIClient
    private let bucket: HomeBucket
    private let items: () -> [PlexMetadata]
    private let onChange: () -> Void
    private let page = PageView()
    private let heading: ScreenTitleView
    private let grid = CardGridView()
    private let state = StateView()
    private var byID: [String: PlexMetadata] = [:]
    private var shown: [PlexMetadata] = []
    private lazy var artworkShape = ArtworkShapeTracker { [weak self] in
        self?.artworkSamples() ?? []
    } onChange: { [weak self] in
        self?.applyArtworkShape()
    }

    init(api: APIClient, bucket: HomeBucket, title: String, items: @escaping () -> [PlexMetadata], onChange: @escaping () -> Void) {
        self.api = api
        self.bucket = bucket
        self.items = items
        self.onChange = onChange
        heading = ScreenTitleView(title: title)
        super.init()
        grid.aspect = bucket == .recentlyAdded ? 1.5 : 9.0 / 16.0
        [page, state].forEach(addSubview)
        page.setSections([heading, grid])
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        grid.onActivate = { [weak self] card in
            guard let self, let media = self.byID[card.id] else { return }
            ItemActions.select(media, in: self.bucket, api: self.api, from: self)
        }
        grid.onPlay = { [weak self] card in
            guard let self, let media = self.byID[card.id] else { return false }
            return ItemActions.playPause(media, api: self.api, from: self)
        }
        grid.onContextMenu = { [weak self] card, point in
            guard let self, let media = self.byID[card.id] else { return }
            ItemActions.present(for: media, bucket: self.bucket, api: self.api, at: point, in: self) { [weak self] in
                self?.onChange()
                self?.refresh()
            }
        }
        refresh()
    }

    override var preferredFocusView: View? { state.isHidden ? grid : state }

    override func screenDidAppear() {
        refresh()
    }

    /// Recently Added takes the shape most of its artwork has (posters, or the frames of videos without one); the other rows
    /// stay landscape stills.
    private func artworkSamples() -> [ArtworkAspect.Sample] {
        shown.map { item in
            let path = HomeCardModel(item: item, bucket: bucket, layout: .poster).imagePath
            return ArtworkAspect.Sample(path: path, guess: ArtworkAspect.of(item, path: path))
        }
    }

    private func applyArtworkShape() {
        guard bucket == .recentlyAdded else { return }
        grid.aspect = Float(artworkShape.aspect)
        page.setNeedsLayout()
    }

    private func refresh() {
        let current = items()
        shown = current
        byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        if bucket == .recentlyAdded {
            artworkShape.update()
            grid.aspect = Float(artworkShape.aspect)
        }
        let layout: HomeCardModel.Layout = bucket == .recentlyAdded ? .poster : .landscape
        grid.setItems(current.map { media in
            let model = HomeCardModel(item: media, bucket: bucket, layout: layout)
            return CardItem(id: media.id, artwork: model.imagePath.map { .path($0, layout == .poster ? .poster : .backdrop) }, title: model.title,
                            subtitle: model.subtitle, detail: model.trailingText, progress: model.progress, isUnwatched: model.isUnwatched,
                            placeholderSymbol: model.usesSeriesPlaceholder ? "tv" : "film")
        })
        heading.summary = current.count == 1 ? String(localized: "1 title") : String(localized: "\(current.count) titles")
        state.isHidden = !current.isEmpty
        if current.isEmpty {
            state.show(.empty(title: String(localized: "Nothing Here"), message: String(localized: "This list is empty right now."),
                              symbol: "rectangle.stack", action: nil))
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

extension HomeScreen: Reloadable {}

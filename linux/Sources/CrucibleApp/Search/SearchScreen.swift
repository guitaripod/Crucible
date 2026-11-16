import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// Search (`TVSearchResultsViewController`): a real text field (typing anywhere outside one starts here with that letter);
/// while it is empty, recent searches with Clear, genres to browse and Recently Added; once there is a query, the scope
/// chips, the best match as a hero with Play and Open, and the matches grouped as movies, shows and episodes, as shelves
/// for All and as grids for one kind. The shared search session decides what to show.
@MainActor
final class SearchScreen: ScreenView {
    private enum ChipID {
        static let clear = "recent.clear"
        static let recentPrefix = "recent."
        static let scopePrefix = "scope."
    }

    private let api: APIClient
    private let session: SearchSession
    private let field = TextFieldView(placeholder: SearchCopy.placeholder)
    private let letters = LetterGridView()
    private let page = PageView()
    private let recentsTitle = SectionTitleView(title: SearchSection.recent.title ?? "")
    private let recents = ChipRowView()
    private let genresTitle = SectionTitleView(title: SearchSection.browse.title ?? "")
    private let genres = GradientTileRowView()
    private let scopes = ChipRowView()
    private let top = TopResultView()
    private let state = StateView()
    private var shelves: [String: ShelfView] = [:]
    private var grids: [String: (title: SectionTitleView, grid: CardGridView)] = [:]
    private var items: [String: PlexMetadata] = [:]
    /// Titles the server does not have that Seerr found, by card id.
    private var hits: [String: SeerrSearchHit] = [:]
    private var genreList: [String: SearchGenre] = [:]
    private var scope: SearchScope = .all
    private var query: String?
    private var renderedKey: String?
    private var watchedOverrides: [String: Bool] = [:]
    private var pendingWatched = Set<String>()
    private var lastState: SearchState?
    private var tourSearchTask: Task<Void, Never>?
    private var isTourSearchPending = false
    private static let tourSearchSettle: Duration = .seconds(2)

    init(api: APIClient) {
        self.api = api
        session = SearchSession(loader: SearchLoader(api: api))
        super.init()
        [page, state, field, letters].forEach(addSubview)
        letters.onPress = { [weak self] press in self?.typed(press) }
        state.isHidden = true
        field.onChange = { [weak self] text in
            guard let self else { return }
            self.session.update(query: text, scope: self.scope)
        }
        field.onSubmit = { [weak self] _ in
            guard let self else { return }
            self.session.rememberCurrentQuery()
            if Theme.current.density == .desk { _ = self.window?.focus.move(.down) }
        }
        recents.onContextMenu = { [weak self] chip, point in self?.presentRecentMenu(chip, at: point) }
        recents.onSelect = { [weak self] chip in self?.recentChosen(chip) }
        scopes.onSelect = { [weak self] chip in
            guard let raw = Int(chip.id.dropFirst(ChipID.scopePrefix.count)), let chosen = SearchScope(rawValue: raw) else { return }
            self?.select(scope: chosen)
        }
        genres.onActivate = { [weak self] tile in
            guard let self, let genre = self.genreList[tile.id] else { return }
            self.rootView?.push(GenreScreen(api: self.api, genre: genre))
        }
        top.onPlay = { [weak self] item in
            self?.session.rememberCurrentQuery()
            self?.play(item)
        }
        top.onOpen = { [weak self] item in
            self?.session.rememberCurrentQuery()
            self?.open(item)
        }
        session.onChange = { [weak self] state in self?.render(state) }
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        session.start()
    }

    override var preferredFocusView: View? { isCouch ? letters : field }

    /// On a couch the letter grid shows under the field, for typing with a gamepad.
    private var isCouch: Bool { Theme.current.density == .couch }

    /// A key of the letter grid: it types into the field as the keyboard would.
    private func typed(_ press: LetterGridView.Press) {
        switch press {
        case .text(let text): field.insert(text)
        case .delete: field.deleteBackward()
        case .clear: field.setText("")
        }
    }

    override func screenDidAppear() { session.resume() }
    override func screenWillDisappear() {
        recordTourSearchIfPending()
        session.suspend()
    }

    /// Starts a search with `text` typed somewhere else.
    func begin(with text: String) {
        window?.focus.focus(field, animated: false)
        field.setText(field.text + text)
    }

    override func handleBack() -> Bool {
        guard !field.text.isEmpty else { return false }
        field.setText("")
        window?.focus.focus(field, animated: false)
        return true
    }

    // MARK: Rendering

    private func render(_ searchState: SearchState) {
        lastState = searchState
        if case .results = searchState { scheduleTourSearch() } else { cancelTourSearch() }
        switch searchState {
        case .idle(let content):
            discardOverrides(for: "idle")
            query = nil
            renderIdle(content)
        case .loading:
            showState(.loading(title: nil))
        case .results(let resultQuery, let parts):
            discardOverrides(for: resultQuery)
            query = resultQuery
            renderResults(parts)
        case .empty(let emptyQuery, let emptyScope):
            discardOverrides(for: emptyQuery)
            query = emptyQuery
            let action = emptyScope == .all ? nil : StateView.Action(title: String(localized: "Search All")) { [weak self] in self?.select(scope: .all) }
            showState(.empty(title: SearchCopy.noResultsTitle(query: emptyQuery), message: SearchCopy.noResultsHint(scope: emptyScope),
                             symbol: "magnifyingglass", action: action), keepsScopes: emptyScope != .all)
        case .failed(let failedQuery, let message):
            showState(.error(title: SearchCopy.failureTitle, message: message, retryTitle: SearchCopy.retry,
                             retry: { [weak self] in self?.session.retry(failedQuery) }))
        }
    }

    /// Ticks the demo tour's Search step once results have stayed on screen two seconds without another keystroke, or when
    /// the screen is left with results showing: ticking on the first partial query would earn the finale mid-word.
    private func scheduleTourSearch() {
        isTourSearchPending = true
        tourSearchTask?.cancel()
        tourSearchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.tourSearchSettle)
            guard !Task.isCancelled else { return }
            self?.recordTourSearchIfPending()
        }
    }

    private func cancelTourSearch() {
        isTourSearchPending = false
        tourSearchTask?.cancel()
    }

    private func recordTourSearchIfPending() {
        guard isTourSearchPending else { return }
        isTourSearchPending = false
        tourSearchTask?.cancel()
        DemoTour.shared.record(.search)
    }

    /// A watched mark just made stands in for the server's answer until the next query brings fresh data.
    private func discardOverrides(for key: String) {
        if renderedKey != key { watchedOverrides = [:] }
        renderedKey = key
    }

    private func renderIdle(_ content: SearchIdleContent) {
        guard !content.isEmpty else {
            showState(.empty(title: SearchCopy.idleTitle, message: SearchCopy.idleMessage, symbol: "magnifyingglass", action: nil))
            return
        }
        var sections: [View] = []
        if !content.recents.isEmpty {
            recents.setChips(content.recents.map { ChipRowView.Chip(id: ChipID.recentPrefix + $0, title: $0, symbol: "clock.arrow.circlepath") }
                             + [ChipRowView.Chip(id: ChipID.clear, title: SearchCopy.clearRecents, symbol: "xmark")])
            sections += [recentsTitle, recents]
        }
        if !content.genres.isEmpty {
            genreList = Dictionary(content.genres.map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })
            genres.setTiles(content.genres.map { genre in
                let pair = GenrePalette.pair(for: genre.title)
                return GradientTileRowView.Tile(id: genre.title, title: genre.title, top: Color(hex: pair.end), bottom: Color(hex: pair.start))
            })
            sections += [genresTitle, genres]
        }
        if !content.recentlyAdded.isEmpty {
            let recent = shelf("recent", title: SearchSection.recentlyAdded.title ?? "", style: .poster)
            recent.setItems(content.recentlyAdded.map { posterCard($0) })
            sections.append(recent)
        }
        showSections(sections)
    }

    private func updateScopeChips() {
        scopes.setChips(SearchScope.allCases.map { ChipRowView.Chip(id: ChipID.scopePrefix + String($0.rawValue), title: $0.title, isSelected: $0 == scope) })
    }

    private func renderResults(_ parts: SearchResults.Parts) {
        updateScopeChips()
        var sections: [View] = [scopes]
        if let best = parts.top {
            items[best.id] = best
            top.show(best, query: query)
            sections.append(top)
        }
        let filtered = scope != .all
        if !parts.movies.isEmpty {
            sections += group("movies", title: SearchSection.movies.title ?? "", cards: parts.movies.map { posterCard($0) }, filtered: filtered, landscape: false)
        }
        if !parts.shows.isEmpty {
            sections += group("shows", title: SearchSection.shows.title ?? "", cards: parts.shows.map { posterCard($0) }, filtered: filtered, landscape: false)
        }
        if !parts.episodes.isEmpty {
            sections += group("episodes", title: SearchSection.episodes.title ?? "", cards: parts.episodes.map { episodeCard($0) }, filtered: filtered,
                              landscape: true)
        }
        if !parts.elsewhere.isEmpty {
            sections += group("elsewhere", title: SearchSection.elsewhere.title ?? "", cards: parts.elsewhere.map { hitCard($0) }, filtered: filtered,
                              landscape: false)
        }
        showSections(sections)
    }

    /// A kind of result: a shelf for All, a grid of six posters or four episodes for one kind.
    private func group(_ id: String, title: String, cards: [CardItem], filtered: Bool, landscape: Bool) -> [View] {
        guard filtered else {
            let shelf = shelf(id, title: title, style: landscape ? .landscape : .poster)
            shelf.setItems(cards)
            return [shelf]
        }
        let entry = grids[id] ?? (SectionTitleView(title: title), makeGrid())
        entry.title.title = title
        entry.grid.columns = landscape ? 4 : 6
        entry.grid.aspect = landscape ? 9 / 16 : 1.5
        entry.grid.setItems(cards)
        grids[id] = entry
        return [entry.title, entry.grid]
    }

    private func showSections(_ sections: [View]) {
        let hadFocus = state.containsFocus
        if !state.isHidden { page.fadeIn() }
        state.isHidden = true
        page.isHidden = false
        page.setSections(sections)
        if hadFocus { window?.focus.focus(field, animated: false) }
        setNeedsLayout()
    }

    private func showState(_ newState: StateView.State, keepsScopes: Bool = false) {
        state.show(newState)
        state.isHidden = false
        if keepsScopes {
            updateScopeChips()
            page.isHidden = false
            page.setSections([scopes])
        } else {
            page.isHidden = true
        }
        setNeedsLayout()
    }

    // MARK: Cards

    private func posterCard(_ item: PlexMetadata) -> CardItem {
        items[item.id] = item
        let model = SearchPosterModel(item: item)
        let override = watchedOverrides[item.id]
        let watched = override ?? item.isWatched
        let hasProgress = override != true && (model.progress ?? 0) > 0
        let playable = SearchItemActions.isPlayable(item)
        var card = CardItem(id: item.id, artwork: model.posterPath.map { .path($0, .poster) }, title: model.title, subtitle: model.subtitle,
                            progress: override == true ? nil : model.progress, isUnwatched: playable && !watched && !hasProgress, isWatched: playable && watched,
                            badgeText: model.unwatchedCount.map { String(localized: "\($0) unwatched") }, placeholderSymbol: Symbol(model.placeholderIcon))
        card.canToggleWatched = playable
        return card.linked(to: item)
    }

    private func episodeCard(_ item: PlexMetadata) -> CardItem {
        items[item.id] = item
        let model = SearchEpisodeModel(item: item)
        let override = watchedOverrides[item.id]
        var card = CardItem(id: item.id, artwork: model.thumbPath.map { .path($0, .backdrop) }, title: model.title, subtitle: model.subtitle,
                            progress: override == true ? nil : model.progress, isWatched: override ?? item.isWatched, placeholderSymbol: "tv")
            .linked(to: item)
        card.titleHighlights = Self.highlights(of: query, in: model.title)
        return card
    }

    /// The query's matches in `text` as UTF-16 ranges.
    static func highlights(of query: String?, in text: String) -> [Range<Int>] {
        guard let query, !query.isEmpty else { return [] }
        return SearchHighlight.matchRanges(of: query, in: text).map { $0.location..<($0.location + $0.length) }
    }

    private func shelf(_ id: String, title: String, style: CardStyle) -> ShelfView {
        let shelf = shelves[id] ?? ShelfView(header: nil, style: style)
        shelf.header = SectionHeader(title: title)
        shelf.style = style
        shelf.onActivate = { [weak self] card in self?.activate(card.id, rememberingQuery: id != "recent") }
        shelf.onPlay = { [weak self] card in self?.playKey(card.id, rememberingQuery: id != "recent") ?? false }
        shelf.onContextMenu = { [weak self] card, point in self?.presentMenu(for: card.id, at: point) }
        shelf.onToggleWatched = { [weak self] card in self?.toggleWatched(card) }
        shelves[id] = shelf
        return shelf
    }

    private func makeGrid() -> CardGridView {
        let grid = CardGridView()
        grid.onActivate = { [weak self] card in self?.activate(card.id, rememberingQuery: true) }
        grid.onPlay = { [weak self] card in self?.playKey(card.id, rememberingQuery: true) ?? false }
        grid.onContextMenu = { [weak self] card, point in self?.presentMenu(for: card.id, at: point) }
        grid.onToggleWatched = { [weak self] card in self?.toggleWatched(card) }
        return grid
    }

    /// A card's hover watched toggle, for a result that keeps a watched state.
    private func toggleWatched(_ card: CardItem) {
        guard let item = items[card.id] else { return }
        setWatched(!(watchedOverrides[item.id] ?? item.isWatched), item: item)
    }

    // MARK: Actions

    private func recentChosen(_ chip: ChipRowView.Chip) {
        if chip.id == ChipID.clear {
            session.clearRecents()
            return
        }
        scope = .all
        field.setText(chip.title, notify: false)
        session.select(recent: chip.title)
    }

    private func presentRecentMenu(_ chip: ChipRowView.Chip, at point: Point?) {
        guard chip.id != ChipID.clear, let window else { return }
        let anchor = point ?? Point(x: frameInWindow.minX, y: frameInWindow.minY)
        let menu = MenuView(title: chip.title, items: [MenuView.Item(id: "remove", title: SearchCopy.removeRecent, symbol: "trash", isDestructive: true)],
                            anchor: Rect(x: anchor.x, y: anchor.y, width: 1, height: 1))
        menu.onSelect = { [weak self] _ in self?.session.removeRecent(chip.title) }
        menu.present(in: window)
    }

    private func select(scope newScope: SearchScope) {
        guard newScope != scope else { return }
        scope = newScope
        session.update(query: field.text, scope: newScope)
    }

    /// A title Seerr found that the server does not have: Seerr's poster, the year and where it stands when someone asked.
    private func hitCard(_ hit: SeerrSearchHit) -> CardItem {
        let id = "seerr.\(hit.kind.rawValue).\(hit.tmdbID)"
        hits[id] = hit
        let poster = SeerrAccount.shared.connection.flatMap { SeerrImage.poster(hit.posterPath, base: $0.address) }
        let label = hit.availability == .notRequested ? nil : SeerrCopy.cardLabel(hit.availability)
        var card = CardItem(id: id, artwork: poster.map { .url($0) }, title: hit.title,
                            subtitle: [hit.year.map(String.init), label].compactMap { $0 }.joined(separator: " · "), placeholderSymbol: hit.kind == .tv ? "tv" : "film")
        card.primarySymbol = "plus"
        card.primaryName = SeerrCopy.request
        card.canToggleWatched = false
        return card
    }

    private func activate(_ id: String, rememberingQuery: Bool) {
        if let hit = hits[id] {
            if rememberingQuery { session.rememberCurrentQuery() }
            SeerrRequestScreen.open(hit.asMetadata, api: api, isOnServer: false, from: self)
            return
        }
        guard let item = items[id] else { return }
        if rememberingQuery { session.rememberCurrentQuery() }
        open(item)
    }

    private func playKey(_ id: String, rememberingQuery: Bool) -> Bool {
        guard let item = items[id], SearchItemActions.isPlayable(item) else { return false }
        if rememberingQuery { session.rememberCurrentQuery() }
        play(item)
        return true
    }

    private func open(_ item: PlexMetadata) {
        switch SearchDestination(item: item) {
        case .movie(let ratingKey):
            rootView?.push(DetailScreen.make(api: api, route: .item(ratingKey: ratingKey, mediaType: "movie", showRatingKey: nil, seasonRatingKey: nil),
                                             placeholder: item))
        case .show(let ratingKey, let initialSeasonKey):
            rootView?.push(DetailScreen.make(api: api, route: .show(ratingKey: ratingKey, initialSeasonKey: initialSeasonKey), placeholder: item))
        case .episode(let ratingKey, let showKey, let seasonKey):
            rootView?.push(DetailScreen.make(api: api, route: .item(ratingKey: ratingKey, mediaType: "episode", showRatingKey: showKey,
                                                                    seasonRatingKey: seasonKey), placeholder: item))
        }
    }

    private func play(_ item: PlexMetadata, fromBeginning: Bool = false) {
        rootView?.play(item: item, api: api, from: fromBeginning ? 0 : nil)
    }

    /// The menu of a result (`TVSearchMenus`): Resume or Play and Play from Beginning, View Details and Go to Show, and both
    /// watched directions with the current one checked.
    private func presentMenu(for id: String, at point: Point?) {
        if let hit = hits[id], let window {
            let frame = window.focusedView?.frameInWindow ?? frameInWindow
            let menu = MenuView(title: hit.title, items: [MenuView.Item(id: "request", title: SeerrCopy.request, symbol: "plus.circle")],
                                anchor: Rect(x: point?.x ?? frame.minX, y: point?.y ?? frame.maxY, width: 1, height: 1))
            menu.onSelect = { [weak self] _ in
                guard let self else { return }
                SeerrRequestScreen.open(hit.asMetadata, api: self.api, isOnServer: false, from: self)
            }
            menu.present(in: window)
            return
        }
        guard let item = items[id], let window else { return }
        let watched = watchedOverrides[item.id] ?? item.isWatched
        var entries: [MenuView.Item] = []
        if SearchItemActions.isPlayable(item) {
            entries.append(.init(id: "play", title: item.isResumable ? String(localized: "Resume") : String(localized: "Play"), symbol: "play.fill"))
            if item.isResumable { entries.append(.init(id: "restart", title: String(localized: "Play from Beginning"), symbol: "gobackward")) }
        }
        entries.append(.init(id: "details", title: String(localized: "View Details"), symbol: "info.circle"))
        let showKey = SearchItemActions.showKey(for: item)
        if showKey != nil { entries.append(.init(id: "show", title: String(localized: "Go to Show"), symbol: "tv")) }
        entries.append(.init(id: "watched", title: String(localized: "Mark Watched"), symbol: "checkmark.circle", isChecked: watched))
        entries.append(.init(id: "unwatched", title: String(localized: "Mark Unwatched"), symbol: "eye.slash", isChecked: !watched))
        let frame = window.focusedView?.frameInWindow ?? frameInWindow
        let anchor = Rect(x: point.map { $0.x } ?? frame.minX, y: point.map { $0.y } ?? frame.maxY, width: 1, height: 1)
        let menu = MenuView(title: item.title, items: entries, anchor: anchor)
        menu.onSelect = { [weak self] chosen in
            guard let self else { return }
            switch chosen.id {
            case "play": self.play(item)
            case "restart": self.play(item, fromBeginning: true)
            case "details": self.open(item)
            case "show":
                if let showKey { self.rootView?.push(DetailScreen.make(api: self.api, route: .show(ratingKey: showKey, initialSeasonKey: nil))) }
            case "watched": self.setWatched(true, item: item)
            case "unwatched": self.setWatched(false, item: item)
            default: break
            }
        }
        menu.present(in: window)
    }

    /// Shows the new watched state at once and tells the server; a refusal puts the card back and says so. A second change
    /// of the same title waits for the first.
    private func setWatched(_ watched: Bool, item: PlexMetadata) {
        let ratingKey = item.id
        guard pendingWatched.insert(ratingKey).inserted else { return }
        let previous = watchedOverrides[ratingKey]
        watchedOverrides[ratingKey] = watched
        rerender()
        let api = api
        Task { [weak self] in
            do {
                try await WatchedService.setWatched(watched, ratingKey: ratingKey, api: api)
                self?.pendingWatched.remove(ratingKey)
            } catch {
                guard let self else { return }
                self.pendingWatched.remove(ratingKey)
                self.watchedOverrides[ratingKey] = previous
                self.rerender()
                if let window = self.window {
                    AlertView.notice(title: SearchCopy.watchedFailureTitle(watched: watched), message: ConnectionError.message(for: error), in: window)
                }
            }
        }
    }

    private func rerender() {
        guard let lastState else { return }
        render(lastState)
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let width = min(frame.width - metrics.sideMargin * 2, metrics.tv(1200))
        field.frame = Rect(x: ((frame.width - width) / 2).rounded(), y: metrics.tabBarClearance, width: width, height: metrics.primaryControlHeight)
        letters.isHidden = !isCouch
        let gridWidth = frame.width - metrics.sideMargin * 2
        letters.frame = Rect(x: metrics.sideMargin, y: field.frame.maxY + metrics.tv(28), width: gridWidth,
                             height: isCouch ? letters.sizeThatFits(Size(width: gridWidth, height: 0)).height : 0)
        let headTop = isCouch ? letters.frame.maxY : field.frame.maxY
        page.topInset = headTop + metrics.tv(24)
        page.frame = bounds
        let stateTop = headTop + (page.isHidden ? 0 : scopes.sizeThatFits(bounds.size).height + metrics.tv(24))
        state.frame = Rect(x: 0, y: stateTop, width: frame.width, height: frame.height - stateTop)
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

/// The best match for the query (`TVSearchTopResultView`): its poster, a Top Result eyebrow, the title with the query
/// tinted, what it is, and Play or Resume beside Open. The buttons take the focus; the hero itself does not.
@MainActor
private final class TopResultView: View {
    var onPlay: ((PlexMetadata) -> Void)?
    var onOpen: ((PlexMetadata) -> Void)?

    private let poster = ArtworkView()
    private let play = ButtonView(style: .primary, title: "", symbol: "play.fill")
    private let openButton = ButtonView(style: .glass, title: "")
    private var item: PlexMetadata?
    private var model: SearchTopResultModel?
    private var query: String?

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        poster.cornerRadius = Theme.current.metrics.cardCornerRadius
        play.onPress = { [weak self] in
            guard let self, let item = self.item else { return }
            self.onPlay?(item)
        }
        openButton.onPress = { [weak self] in
            guard let self, let item = self.item else { return }
            self.onOpen?(item)
        }
        [poster, play, openButton].forEach(addSubview)
    }

    override var remembersFocus: Bool { true }
    override var preferredFocusView: View? { play.isHidden ? openButton : play }

    func show(_ newItem: PlexMetadata, query newQuery: String?) {
        item = newItem
        query = newQuery
        let made = SearchTopResultModel(item: newItem)
        model = made
        poster.source = made.posterPath.map { .path($0, .poster) }
        laidOut = nil
        superview?.setNeedsLayout()
        play.isHidden = !made.canPlay
        play.title = SearchItemActions.playTitle(for: newItem)
        switch newItem.mediaType {
        case "show": openButton.title = String(localized: "Open Show")
        case "episode": openButton.title = String(localized: "Open Episode")
        default: openButton.title = String(localized: "Open Movie")
        }
        setNeedsLayout()
        setNeedsDisplay()
    }

    private var posterSize: Size {
        let metrics = Theme.current.metrics
        return Size(width: metrics.tv(200), height: metrics.tv(300))
    }

    /// The eyebrow, the title and the meta line beside the poster, laid out once per title, width and scale.
    @MainActor
    private struct TextBlock {
        let eyebrow: TextLayout
        let title: TextLayout
        let match: TextLayout?
        let meta: TextLayout

        /// From the poster's top to the end of the meta line.
        var height: Float {
            let metrics = Theme.current.metrics
            return metrics.tv(20) + eyebrow.size.height + metrics.tv(8) + title.size.height + metrics.tv(8) + meta.size.height
        }
    }

    private var laidOut: (width: Float, scale: Float, block: TextBlock)?

    private func textBlock(width: Float) -> TextBlock? {
        guard let model else { return nil }
        let scale = window?.scale ?? 1
        if let laidOut, laidOut.width == width, laidOut.scale == scale { return laidOut.block }
        let type = Theme.current.type
        let title = TextLayout(model.title, font: type.screenTitle, maxWidth: width, maxLines: 2, scale: scale)
        let block = TextBlock(
            eyebrow: TextLayout(SearchCopy.topResultEyebrow.uppercased(), font: type.eyebrow, maxWidth: width, scale: scale),
            title: title,
            match: title.showingOnly(utf16: SearchScreen.highlights(of: query, in: model.title).map { (location: $0.lowerBound, length: $0.count) }),
            meta: TextLayout(model.meta, font: type.screenSummary, maxWidth: width, scale: scale))
        laidOut = (width, scale, block)
        return block
    }

    private func textWidth(in width: Float) -> Float { width - textX - Theme.current.metrics.sideMargin }

    /// Where the buttons go: level with the poster's foot, or under the text when larger type pushes the text down that far.
    private func buttonsY(posterTop: Float, block: TextBlock?) -> Float {
        let metrics = Theme.current.metrics
        let resting = posterTop + posterSize.height - metrics.primaryControlHeight - metrics.tv(20)
        return max(resting, posterTop + (block?.height ?? 0) + metrics.tv(24))
    }

    override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        let bottom = buttonsY(posterTop: 0, block: textBlock(width: textWidth(in: size.width))) + metrics.primaryControlHeight + metrics.tv(20)
        return Size(width: size.width, height: max(posterSize.height, bottom) + metrics.shelfTopInset + metrics.shelfBottomInset)
    }

    private var textX: Float { Theme.current.metrics.sideMargin + posterSize.width + Theme.current.metrics.gutter }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        poster.frame = Rect(origin: Point(x: metrics.sideMargin, y: metrics.shelfTopInset), size: posterSize)
        let height = metrics.primaryControlHeight
        let playSize = play.sizeThatFits(Size(width: 600, height: height))
        let openSize = openButton.sizeThatFits(Size(width: 600, height: height))
        let y = buttonsY(posterTop: poster.frame.minY, block: textBlock(width: textWidth(in: bounds.width)))
        var x = textX
        if !play.isHidden {
            play.frame = Rect(x: x, y: y, width: playSize.width, height: playSize.height)
            x += playSize.width + metrics.tv(24)
        }
        openButton.frame = Rect(x: x, y: y, width: openSize.width, height: openSize.height)
    }

    override func draw(_ context: inout DrawContext) {
        guard let block = textBlock(width: textWidth(in: bounds.width)) else { return }
        let theme = Theme.current
        let metrics = theme.metrics
        var y = poster.frame.minY + metrics.tv(20)
        context.text(block.eyebrow, at: Point(x: textX, y: y), color: theme.palette.accentText)
        y += block.eyebrow.size.height + metrics.tv(8)
        context.text(block.title, at: Point(x: textX, y: y), color: theme.palette.label)
        if let match = block.match { context.text(match, at: Point(x: textX, y: y), color: theme.palette.accentText) }
        y += block.title.size.height + metrics.tv(8)
        context.text(block.meta, at: Point(x: textX, y: y), color: theme.palette.labelSecondary)
    }
}

/// Every title of one genre as a six-column poster grid sorted by title (`TVGenreBrowseViewController`), paging in more as
/// the focus nears the end; Select opens a title, Play and the menu play a movie.
@MainActor
final class GenreScreen: ScreenView {
    private let api: APIClient
    private let genre: SearchGenre
    private let model: GenreGridModel
    private let page = PageView()
    private let heading: ScreenTitleView
    private let grid = CardGridView()
    private let state = StateView()

    init(api: APIClient, genre: SearchGenre) {
        self.api = api
        self.genre = genre
        model = GenreGridModel(genre: genre, loader: SearchLoader(api: api))
        heading = ScreenTitleView(title: genre.title)
        super.init()
        [page, state].forEach(addSubview)
        page.setSections([heading, grid])
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        grid.columns = 6
        grid.onActivate = { [weak self] card in self?.open(card.id) }
        grid.onFocus = { [weak self] card in
            guard let self, let index = self.model.items.firstIndex(where: { $0.id == card.id }) else { return }
            self.model.itemFocused(at: index)
        }
        grid.onPlay = { [weak self] card in self?.playMovie(card.id) ?? false }
        grid.onContextMenu = { [weak self] card, point in self?.presentMenu(card.id, at: point) }
        model.onUpdate = { [weak self] update in self?.render(update) }
        showState(.loading(title: nil))
    }

    override var preferredFocusView: View? { state.isHidden ? grid : state }

    override func screenDidAppear() { model.appear() }
    override func screenWillDisappear() { model.disappear() }

    private var countText: String {
        let count = model.pager.totalCount ?? model.items.count
        return count == 1 ? String(localized: "1 title") : String(localized: "\(count) titles")
    }

    private func render(_ update: GenreGridModel.Update) {
        switch update {
        case .contentState: renderState()
        case .pageLoaded: applyItems()
        case .pageFailed: break
        }
    }

    private func renderState() {
        switch model.contentState {
        case .loading:
            showState(.loading(title: nil))
        case .content:
            applyItems()
            let hadFocus = state.containsFocus
            if !state.isHidden { page.fadeIn() }
            state.isHidden = true
            page.isHidden = false
            if hadFocus { window?.focus.focus(grid, animated: false) }
        case .empty:
            showState(.empty(title: SearchCopy.genreEmptyTitle(genre.title), message: SearchCopy.genreEmptyMessage, symbol: "film.stack",
                             action: StateView.Action(title: String(localized: "Back")) { [weak self] in _ = self?.navigation?.pop() }))
        case .failed(let message):
            showState(.error(title: SearchCopy.genreFailureTitle(genre.title), message: message, retryTitle: SearchCopy.retry,
                             retry: { [weak self] in self?.model.appear() }))
        }
    }

    private func applyItems() {
        grid.setItems(model.items.map { item in
            let poster = SearchPosterModel(item: item)
            return CardItem(id: item.id, artwork: poster.posterPath.map { .path($0, .poster) }, title: poster.title, subtitle: poster.subtitle,
                            progress: poster.progress, isUnwatched: poster.isUnwatched, placeholderSymbol: Symbol(poster.placeholderIcon)).linked(to: item)
        })
        heading.summary = countText
        page.setNeedsLayout()
    }

    private func showState(_ newState: StateView.State) {
        let hadFocus = containsFocus
        state.show(newState)
        state.isHidden = false
        page.isHidden = true
        if hadFocus { window?.focus.focus(state, animated: false) }
    }

    private func open(_ id: String) {
        guard let item = model.items.first(where: { $0.id == id }) else { return }
        switch SearchDestination(item: item) {
        case .show(let ratingKey, let initialSeasonKey):
            rootView?.push(DetailScreen.make(api: api, route: .show(ratingKey: ratingKey, initialSeasonKey: initialSeasonKey), placeholder: item))
        case .movie, .episode:
            rootView?.push(DetailScreen.make(api: api, item: item))
        }
    }

    private func playMovie(_ id: String) -> Bool {
        guard let item = model.items.first(where: { $0.id == id }), item.mediaType == "movie" else { return false }
        rootView?.play(item: item, api: api)
        return true
    }

    private func presentMenu(_ id: String, at point: Point?) {
        guard let item = model.items.first(where: { $0.id == id }), item.mediaType == "movie", let window else { return }
        let frame = window.focusedView?.frameInWindow ?? frameInWindow
        let anchor = Rect(x: point.map { $0.x } ?? frame.minX, y: point.map { $0.y } ?? frame.maxY, width: 1, height: 1)
        let menu = MenuView(title: item.title, items: [MenuView.Item(id: "play", title: SearchItemActions.playTitle(for: item), symbol: "play.fill")],
                            anchor: anchor)
        menu.onSelect = { [weak self] _ in
            guard let self else { return }
            self.rootView?.play(item: item, api: self.api)
        }
        menu.present(in: window)
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

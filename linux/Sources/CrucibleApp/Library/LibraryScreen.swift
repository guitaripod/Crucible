import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// A movie or show library (`TVLibraryViewController`): its title and count; the watch filter chips with the Genre, Sort and
/// Filters menus and the Collections and Folders buttons; a Recently Watched shelf; and the poster grid, paged from the server
/// as focus or scrolling nears the end of what is loaded, with an A-Z rail on the trailing edge. Everything that is not drawing
/// lives in `LibraryGridModel`.
@MainActor
final class LibraryScreen: ScreenView {
    /// How long the grid waits for Recently Watched before it is shown without the shelf.
    private static let revealDeadline = Duration.milliseconds(1500)

    private enum Control {
        static let genre = "genre"
        static let sort = "sort"
        static let filters = "filters"
        static let collections = "collections"
        static let folders = "folders"
    }

    private let api: APIClient
    private let directory: PlexDirectory
    private let kind: LibraryGridKind
    private let model: LibraryGridModel
    private let page = PageView()
    private let heading: ScreenTitleView
    private let controls = ChipRowView()
    private let recents = ShelfView(header: SectionHeader(title: String(localized: "Recently Watched"), hasSeeAll: true), style: .poster)
    private let grid = CardGridView()
    private let rail = AlphabetRailView()
    private let state = StateView()
    private var hasRevealedContent = false
    private var hasPassedRevealDeadline = false
    private var shelfInserted = false
    private var shownState: String?
    private var revealTask: Task<Void, Never>?
    private lazy var actions = LibraryActions(api: api, kind: kind, host: self) { [weak self] item, watched in
        self?.model.setWatched(ratingKey: item.id, watched: watched)
    }
    private lazy var artworkShape = ArtworkShapeTracker { [weak self] in
        self?.artworkSamples() ?? []
    } onChange: { [weak self] in
        self?.applyArtworkShape()
    }

    init(api: APIClient, directory: PlexDirectory) {
        self.api = api
        self.directory = directory
        kind = LibraryGridKind(sectionType: directory.type) ?? .movie
        model = LibraryGridModel(api: api, sectionId: directory.key ?? "", kind: kind, offersContinueBanner: false)
        heading = ScreenTitleView(title: directory.title ?? "")
        super.init()
        [page, rail, state].forEach(addSubview)
        page.setSections([heading, controls, grid])
        page.onScroll = { [weak self] offset in
            self?.rootView?.contentScrolled(offset: offset)
            self?.loadMoreIfNeeded()
        }
        state.isHidden = true
        rail.isHidden = true
        rail.onSelect = { [weak self] letter in self?.jump(to: letter) }
        controls.onSelect = { [weak self] chip in self?.controlSelected(chip.id) }
        installGrid()
        installRecents()
        model.onUpdate = { [weak self] update in self?.updated(update) }
        updateControls()
        model.loadGenres()
    }

    override var preferredFocusView: View? {
        guard state.isHidden else { return state }
        return shelfInserted && !recents.isHidden ? recents : grid
    }

    override var remembersFocus: Bool { true }

    override func screenDidAppear() {
        startRevealDeadline()
        model.appear(visibleGridIndex: firstVisibleGridIndex)
    }

    override func screenWillDisappear() {
        model.disappear()
    }

    private func installGrid() {
        grid.onActivate = { [weak self] card in
            guard let self, let item = self.model.item(withId: card.id) else { return }
            self.actions.select(item, isRecent: false)
        }
        grid.onPlay = { [weak self] card in
            guard let self, let item = self.model.item(withId: card.id) else { return false }
            return self.actions.play(item, isRecent: false)
        }
        grid.onFocus = { [weak self] card in
            guard let self, let index = self.grid.index(of: card.id) else { return }
            self.model.loadNextPageIfNeeded(near: index)
            self.rail.currentLetter = self.model.letter(atGridIndex: index)
        }
        grid.onContextMenu = { [weak self] card, point in
            guard let self, let item = self.model.item(withId: card.id) else { return }
            self.actions.presentMenu(for: item, isRecent: false, at: point)
        }
    }

    private func installRecents() {
        recents.isHidden = true
        recents.onActivate = { [weak self] card in
            guard let self, let item = self.model.recentItem(withId: card.id) else { return }
            self.actions.select(item, isRecent: true)
        }
        recents.onPlay = { [weak self] card in
            guard let self, let item = self.model.recentItem(withId: card.id) else { return false }
            return self.actions.play(item, isRecent: true)
        }
        recents.onContextMenu = { [weak self] card, point in
            guard let self, let item = self.model.recentItem(withId: card.id) else { return }
            self.actions.presentMenu(for: item, isRecent: true, at: point)
        }
        recents.onSeeAll = { [weak self] in self?.showAllRecent() }
    }

    // MARK: Model updates

    private func updated(_ update: LibraryGridModel.Update) {
        switch update {
        case .optionsChanged, .genres, .facets:
            updateControls()
            updateRail()
        case .contentState, .pageFailed:
            applyContentState()
        case .pageLoaded:
            revealContentIfReady()
            if hasRevealedContent { applyContent() }
            applyContentState()
        case .recents:
            revealContentIfReady()
            if hasRevealedContent {
                if !shelfInserted, !isFocusInGrid { shelfInserted = true }
                applyContent()
            }
            applyContentState()
        case .continueItem:
            break
        case .alphabet:
            updateRail()
        }
    }

    /// The first page and the Recently Watched shelf are shown together: a shelf that appeared later would push the posters,
    /// and the focus on them, down the screen. A slow history request must not hold the grid back, so after `revealDeadline`
    /// the grid is shown without the shelf, which then joins only while the focus is outside the grid.
    private func revealContentIfReady() {
        guard !hasRevealedContent, model.pager.hasLoaded, model.hasLoadedRecents || hasPassedRevealDeadline else { return }
        hasRevealedContent = true
        shelfInserted = model.hasLoadedRecents
        revealTask?.cancel()
    }

    private func startRevealDeadline() {
        guard !hasRevealedContent, revealTask == nil else { return }
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: Self.revealDeadline)
            guard !Task.isCancelled, let self else { return }
            self.hasPassedRevealDeadline = true
            self.revealContentIfReady()
            if self.hasRevealedContent { self.applyContent() }
            self.applyContentState()
        }
    }

    private var isFocusInGrid: Bool {
        window?.focusedView?.isDescendant(of: grid) ?? false
    }

    /// Adds a shelf that arrived late once the focus has left the grid.
    private func insertDeferredShelfIfSafe() {
        guard hasRevealedContent, !shelfInserted, model.hasLoadedRecents, !model.visibleRecents.isEmpty, !isFocusInGrid else { return }
        shelfInserted = true
        applyContent()
    }

    override func descendantFocusDidChange(to view: View?) {
        insertDeferredShelfIfSafe()
    }

    private func applyContent() {
        artworkShape.update()
        let aspect = Float(artworkShape.aspect)
        grid.aspect = aspect
        grid.setItems(model.gridIds.compactMap { id in model.item(withId: id).map { LibraryCards.grid($0, kind: kind) } })
        let shownRecents = shelfInserted ? model.visibleRecents : []
        recents.setItems(shownRecents.map { LibraryCards.recent($0, kind: kind) })
        recents.isHidden = shownRecents.isEmpty
        page.setSections(recents.isHidden ? [heading, controls, grid] : [heading, controls, recents, grid])
        heading.summary = countText()
        setNeedsLayout()
        updateRail()
    }

    /// Artwork that loaded since showed the grid's real shape: lays the grid and the shelf out in it again.
    private func applyArtworkShape() {
        MidgarLog.info("Library artwork shape section=\(model.sectionId) aspect=\(artworkShape.aspect)", category: .ui)
        grid.aspect = Float(artworkShape.aspect)
        setNeedsLayout()
    }

    private func artworkSamples() -> [ArtworkAspect.Sample] {
        LibraryCards.samples(model.gridIds.compactMap(model.item(withId:)).map { LibraryPoster(grid: $0, kind: kind) })
    }

    /// "1,248 movies", or "12 movies · Filtered" while a filter narrows the grid; empty until the first page arrived.
    private func countText() -> String? {
        guard model.pager.hasLoaded else { return nil }
        let total = model.pager.totalSize
        let count = total.formatted(.number)
        let summary: String
        switch (kind == .movie, total == 1) {
        case (true, true): summary = String(localized: "\(count) movie")
        case (true, false): summary = String(localized: "\(count) movies")
        case (false, true): summary = String(localized: "\(count) show")
        case (false, false): summary = String(localized: "\(count) shows")
        }
        return model.options.isFiltering ? String(localized: "\(summary) · Filtered") : summary
    }

    /// Shows what the model's state calls for, only when the state itself changes, so a page arriving never moves the focus
    /// off the chip that was just pressed.
    private func applyContentState() {
        let current = model.contentState
        let key: String
        switch current {
        case .content: key = hasRevealedContent ? "content" : "loading"
        case .loading: key = "loading"
        case .failed(let message): key = "failed \(message)"
        case .noMatches: key = "noMatches"
        case .empty: key = "empty"
        }
        guard key != shownState else {
            updateRail()
            return
        }
        shownState = key
        switch current {
        case .content where hasRevealedContent:
            showContent()
        case .content, .loading:
            showState(.loading(title: nil))
        case .failed(let message):
            showState(.error(title: String(localized: "Couldn’t Load Library"), message: message, retryTitle: String(localized: "Try Again"),
                             retry: { [weak self] in self?.model.refreshAll() }))
        case .noMatches:
            showState(.empty(title: String(localized: "No Matches"), message: String(localized: "Nothing in this library matches the current filters."),
                             symbol: "line.3.horizontal.decrease.circle",
                             action: StateView.Action(title: String(localized: "Clear Filters")) { [weak self] in self?.model.clearFilters() }))
        case .empty:
            showState(.empty(title: kind.emptyTitle, message: String(localized: "Add media to this library on your Plex server to see it here."),
                             symbol: Symbol(kind.placeholderIcon),
                             action: StateView.Action(title: String(localized: "Check Again")) { [weak self] in self?.model.refreshAll() }))
        }
        updateRail()
    }

    private func showState(_ newState: StateView.State) {
        let hadFocus = containsFocus
        state.show(newState)
        state.isHidden = false
        page.isHidden = true
        if hadFocus { window?.focus.focus(state, animated: false) }
    }

    private func showContent() {
        let hadFocus = state.containsFocus
        state.isHidden = true
        page.isHidden = false
        if hadFocus, let target = preferredFocusView { window?.focus.focus(target, animated: false) }
    }

    // MARK: Header controls

    private func updateControls() {
        let options = model.options
        var chips = LibraryWatchFilter.allCases.map { filter in
            ChipRowView.Chip(id: filter.rawValue, title: filter.title, isSelected: options.isChipSelected(filter))
        }
        if !model.genres.isEmpty {
            chips.append(.init(id: Control.genre, title: options.genre == nil ? String(localized: "Genre") : options.genreTitle(in: model.genres),
                               symbol: "theatermasks", isSelected: options.genre != nil))
        }
        chips.append(.init(id: Control.sort, title: String(localized: "Sort", comment: "Button that opens the sort menu, not the verb"),
                           symbol: "arrow.up.arrow.down"))
        if !model.availableFacets.isEmpty {
            chips.append(.init(id: Control.filters, title: String(localized: "Filters", comment: "Button that opens the menu of extra library filters"),
                               symbol: "line.3.horizontal.decrease", isSelected: !options.facets.isEmpty))
        }
        chips.append(.init(id: Control.collections, title: String(localized: "Collections"), symbol: "rectangle.stack"))
        chips.append(.init(id: Control.folders, title: String(localized: "Folders", comment: "Short name of the button that browses a library by its folders"),
                           symbol: "folder"))
        controls.setChips(chips)
        heading.summary = countText()
    }

    private func controlSelected(_ id: String) {
        if let filter = LibraryWatchFilter(rawValue: id) {
            model.selectChip(filter)
            return
        }
        switch id {
        case Control.genre: presentGenres()
        case Control.sort: presentSorts()
        case Control.filters: presentFacets()
        case Control.collections: openCollections()
        case Control.folders: browseFolders()
        default: break
        }
    }

    private func present(_ title: String, items: [MenuView.Item], from control: String, choose: @escaping (MenuView.Item) -> Void) {
        guard let window else { return }
        let anchor = controls.frameInWindow(of: control) ?? controls.frameInWindow
        let menu = MenuView(title: title, items: items, anchor: anchor)
        menu.onSelect = choose
        menu.present(in: window)
    }

    private func presentGenres() {
        let selected = model.options.genre
        let items = [MenuView.Item(id: "", title: String(localized: "All Genres"), isChecked: selected == nil)]
            + model.genres.map { MenuView.Item(id: "genre:\($0.key)", title: $0.title, isChecked: selected == $0.key) }
        present(String(localized: "Genre"), items: items, from: Control.genre) { [weak self] item in
            self?.model.setGenre(item.id.isEmpty ? nil : String(item.id.dropFirst("genre:".count)))
        }
    }

    private func presentSorts() {
        let selected = model.options.sort
        let items = kind.sortOptions(sources: model.ratingSources).map { MenuView.Item(id: $0.key, title: $0.title, isChecked: selected == $0.key) }
        present(String(localized: "Sort By"), items: items, from: Control.sort) { [weak self] item in
            self?.model.setSort(item.id)
        }
    }

    /// Decade, Rated and Resolution, each showing what is chosen; picking one opens its values.
    private func presentFacets() {
        let options = model.options
        let items = model.availableFacets.map { facet in
            let choices = model.facetChoices[facet] ?? []
            let chosen = options.facets[facet].flatMap { key in choices.first { $0.key == key } }.map { facet.display($0.title) }
            return MenuView.Item(id: facet.rawValue, title: facet.title, detail: chosen ?? facet.allTitle, symbol: Symbol(facet.symbol),
                                 isChecked: chosen != nil)
        }
        present(String(localized: "Filters", comment: "Button that opens the menu of extra library filters"), items: items, from: Control.filters) { [weak self] item in
            guard let facet = LibraryFacet(rawValue: item.id) else { return }
            self?.presentChoices(of: facet)
        }
    }

    private func presentChoices(of facet: LibraryFacet) {
        let selected = model.options.facets[facet]
        let items = [MenuView.Item(id: "", title: facet.allTitle, isChecked: selected == nil)]
            + (model.facetChoices[facet] ?? []).map { MenuView.Item(id: "choice:\($0.key)", title: facet.display($0.title), isChecked: selected == $0.key) }
        present(facet.title, items: items, from: Control.filters) { [weak self] item in
            self?.model.setFacet(facet, item.id.isEmpty ? nil : String(item.id.dropFirst("choice:".count)))
        }
    }

    private func openCollections() {
        rootView?.push(LibraryScreens.collections(api: api, sectionId: model.sectionId))
    }

    private func browseFolders() {
        rootView?.push(FolderBrowserScreen(api: api, source: .section(model.sectionId), title: String(localized: "Browse Folders"), kind: kind))
    }

    private func showAllRecent() {
        rootView?.push(LibraryScreens.recentlyWatched(api: api, sectionId: model.sectionId, kind: kind, items: model.recentItems,
                                                      aspect: Float(artworkShape.aspect)))
    }

    // MARK: A-Z rail

    private func updateRail() {
        let visible = state.isHidden && model.offersAlphabetJump
        rail.isHidden = !visible
        guard visible, let alphabet = model.alphabet else { return }
        rail.update(letters: alphabet.availableLetters)
        setNeedsLayout()
    }

    private func jump(to letter: String) {
        model.jump(to: letter) { [weak self] index in self?.scrollAndFocus(gridIndex: index) }
    }

    /// Scrolls the row holding the grid item just under the tab bar and moves the focus onto it.
    private func scrollAndFocus(gridIndex: Int) {
        let count = model.gridIds.count
        guard count > 0 else { return }
        if grid.items.count != count { applyContent() }
        page.layoutIfNeeded()
        grid.layoutIfNeeded()
        guard let card = grid.card(at: min(max(gridIndex, 0), count - 1)) else { return }
        let top = grid.frame.minY + card.frame.minY - Theme.current.metrics.tabBarClearance
        page.setOffset(min(max(top, 0), page.maximumOffset), animated: false)
        window?.focus.focus(card, animated: true, reveal: false)
    }

    /// The grid position on screen, so a deeply scrolled grid refreshes around it on return.
    private var firstVisibleGridIndex: Int {
        let top = page.offset - grid.frame.minY
        guard top > 0 else { return 0 }
        for index in 0..<grid.items.count {
            guard let card = grid.card(at: index) else { break }
            if card.frame.maxY >= top { return index }
        }
        return 0
    }

    /// Scrolling near the end of the loaded posters asks for the next page.
    private func loadMoreIfNeeded() {
        let visibleBottom = page.offset + page.frame.height
        guard grid.frame.maxY - visibleBottom < page.frame.height else { return }
        model.loadNextPageIfNeeded(near: max(0, model.gridIds.count - 1))
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        page.topInset = metrics.tabBarClearance
        page.frame = bounds
        state.frame = bounds
        let gridWidth = frame.width - metrics.sideMargin * 2
        recents.style = CardStyle.grid(aspect: grid.aspect, width: gridWidth)
        rail.frame = Rect(x: frame.width - AlphabetRailView.width, y: metrics.tabBarClearance, width: AlphabetRailView.width,
                          height: frame.height - metrics.tabBarClearance)
        page.setNeedsLayout()
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

extension LibraryScreen: Reloadable {
    func reload() {
        model.refreshAll()
    }
}

import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// Watch History (`HistoryViewController`): the plays newest first, grouped by day, with All, Movies and TV chips, Refresh,
/// the weekly summary and a play-again button on every row. Select opens the title's page; the Play/Pause key or the row's
/// button plays it again. Coming back from a page or the player reloads the list in place.
@MainActor
final class HistoryScreen: ScreenView {
    private static let refreshID = "refresh"

    private let api: APIClient
    private let feed: HistoryFeed
    private let page = PageView()
    private let heading = ScreenTitleView(title: String(localized: "Watch History"))
    private let chips = ChipRowView()
    private let state = StateView()
    private let noMatches = InlineMessageView()
    private var filter: HistoryFilter = .all
    private var sections: [String: HistoryDaySection] = [:]
    private var busy: Set<String> = []
    private var positions: [String: Int] = [:]
    private var hasRequestedFirstPage = false
    private var hasAppeared = false
    private var isRefreshing = false
    private var playTask: Task<Void, Never>?

    init(api: APIClient) {
        self.api = api
        feed = HistoryFeed(api: api)
        super.init()
        [page, state].forEach(addSubview)
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        chips.onSelect = { [weak self] chip in self?.chipPressed(chip.id) }
        feed.onEvent = { [weak self] event in self?.handle(event) }
        render()
    }

    override var preferredFocusView: View? {
        guard state.isHidden else { return state }
        return firstRow ?? chips
    }

    override var remembersFocus: Bool { true }

    private var firstRow: View? {
        page.sections.lazy.compactMap { ($0 as? HistoryDaySection)?.firstRow }.first
    }

    override func screenDidAppear() {
        hasRequestedFirstPage = true
        if hasAppeared, !feed.items.isEmpty, !feed.pager.isLoading {
            feed.refreshTop()
        } else {
            feed.loadFirstPageIfNeeded()
        }
        hasAppeared = true
        render()
    }

    override func screenWillDisappear() {
        playTask?.cancel()
    }

    override func descendantFocusDidChange(to view: View?) {
        guard let row = view?.enclosing(HistoryRowView.self), let position = positions[row.item.uniqueId],
              HistoryPager.isWithinPrefetchWindow(position: position, count: positions.count) else { return }
        feed.prefetchMore()
    }

    private func handle(_ event: HistoryFeed.Event) {
        let wasRefreshing = isRefreshing
        isRefreshing = false
        render()
        if event == .failed, wasRefreshing, !feed.items.isEmpty, let window {
            AlertView.notice(title: String(localized: "Couldn’t Refresh History"), message: String(localized: "Check your connection and try again."),
                             in: window)
        }
    }

    private var currentState: HistoryEmptyState {
        hasRequestedFirstPage ? feed.emptyState(filter: filter) : .loading
    }

    private func render() {
        let current = currentState
        switch current {
        case .loading:
            showState(.loading(title: String(localized: "Loading History")))
            return
        case .noActivity:
            showMessage(current, actionTitle: String(localized: "Refresh")) { [weak self] in self?.refresh() }
            return
        case .loadFailed:
            showMessage(current, actionTitle: String(localized: "Try Again")) { [weak self] in
                self?.feed.retry()
                self?.render()
            }
            return
        case .populated, .noMatches:
            break
        }
        let visible = feed.items(matching: filter)
        positions = Dictionary(visible.enumerated().map { ($1.uniqueId, $0) }, uniquingKeysWith: { first, _ in first })
        heading.summary = current == .populated ? HistorySummary.text(for: visible, now: Date()) : nil
        chips.setChips(HistoryFilter.allCases.map { ChipRowView.Chip(id: $0.rawValue, title: $0.title, isSelected: $0 == filter) }
                       + [ChipRowView.Chip(id: Self.refreshID, title: isRefreshing ? String(localized: "Refreshing") : String(localized: "Refresh"),
                                           symbol: "arrow.clockwise")])
        var shown: [View] = [heading, chips]
        if current == .populated {
            var next: [String: HistoryDaySection] = [:]
            for group in HistoryDay.groups(of: visible, calendar: .current) {
                let key = String(group.day.timeIntervalSince1970)
                let section = sections[key] ?? makeSection()
                section.update(title: HistoryDay.title(for: group.day, now: Date(), calendar: .current), items: group.items, busy: busy)
                next[key] = section
                shown.append(section)
            }
            sections = next
        } else if let content = HistoryEmptyState.noMatches(filter).content {
            noMatches.content = content
            shown.append(noMatches)
        }
        let hadFocus = state.containsFocus
        if !state.isHidden { page.fadeIn() }
        state.isHidden = true
        page.isHidden = false
        page.setSections(shown)
        if hadFocus, let target = preferredFocusView { window?.focus.focus(target, animated: false) }
        setNeedsLayout()
        feed.loadMoreIfNeeded(visibleCount: visible.count)
    }

    private func makeSection() -> HistoryDaySection {
        let section = HistoryDaySection()
        section.onOpen = { [weak self] item in self?.open(item) }
        section.onPlay = { [weak self] item in self?.playAgain(item) }
        section.onMenu = { [weak self] item, point in self?.presentMenu(for: item, at: point) }
        return section
    }

    private func showState(_ newState: StateView.State) {
        let hadFocus = containsFocus
        state.show(newState)
        state.isHidden = false
        page.isHidden = true
        if hadFocus { window?.focus.focus(state, animated: false) }
    }

    private func showMessage(_ empty: HistoryEmptyState, actionTitle: String, action: @escaping () -> Void) {
        guard let content = empty.content else { return }
        showState(.empty(title: content.title, message: content.message, symbol: Symbol(content.symbolName),
                         action: StateView.Action(title: actionTitle, handler: action)))
    }

    private func chipPressed(_ id: String) {
        if id == Self.refreshID {
            refresh()
        } else if let selected = HistoryFilter(rawValue: id), selected != filter {
            filter = selected
            render()
        }
    }

    private func refresh() {
        guard !feed.pager.isLoading else { return }
        isRefreshing = !feed.items.isEmpty
        feed.refresh()
        render()
    }

    private func open(_ item: HistoryItem) {
        let route: DetailRoute
        switch item.destination {
        case .episode(let ratingKey, let showKey, let seasonKey):
            route = .item(ratingKey: ratingKey, mediaType: "episode", showRatingKey: showKey, seasonRatingKey: seasonKey)
        case .show(let ratingKey):
            route = .show(ratingKey: ratingKey, initialSeasonKey: nil)
        case .movie(let ratingKey):
            route = .item(ratingKey: ratingKey, mediaType: "movie", showRatingKey: nil, seasonRatingKey: nil)
        }
        rootView?.push(DetailScreen.make(api: api, route: route))
    }

    /// Loads the full record and plays it from the start; a title the server no longer has says so.
    private func playAgain(_ item: HistoryItem) {
        guard !busy.contains(item.uniqueId) else { return }
        busy.insert(item.uniqueId)
        render()
        playTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.busy.remove(item.uniqueId)
                self.render()
            }
            do {
                guard let metadata = try await self.feed.metadata(for: item), !Task.isCancelled else {
                    if !Task.isCancelled { self.presentPlaybackError() }
                    return
                }
                self.rootView?.play(item: metadata, api: self.api, from: 0)
            } catch {
                guard !Task.isCancelled else { return }
                MidgarLog.error("History play again failed for \(item.ratingKey): \(error)", category: .playback)
                self.presentPlaybackError()
            }
        }
    }

    private func presentPlaybackError() {
        guard let window else { return }
        AlertView.notice(title: String(localized: "Couldn’t Start Playback"), message: String(localized: "The server didn’t return this title. Try again in a moment."),
                         in: window)
    }

    /// Play Again, Go to Details, and for the server's owner, Remove from History.
    private func presentMenu(for item: HistoryItem, at point: Point?) {
        guard let window else { return }
        var items = [
            MenuView.Item(id: "play", title: String(localized: "Play Again", comment: "Watch history action that plays a title again"), symbol: "play.fill"),
            MenuView.Item(id: "details", title: String(localized: "Go to Details", comment: "Watch history action that opens a title's page"), symbol: "info.circle"),
        ]
        if ServerOwnership.isOwner(), item.historyKey != nil {
            items.append(MenuView.Item(id: "remove", title: String(localized: "Remove from History", comment: "Owner action that deletes a play from the server's watch history"),
                                       symbol: "trash", isDestructive: true))
        }
        let frame = window.focusedView?.frameInWindow ?? frameInWindow
        let anchor = Rect(x: point.map { $0.x } ?? frame.minX, y: point.map { $0.y } ?? frame.maxY, width: 1, height: 1)
        let menu = MenuView(title: item.row.title, items: items, anchor: anchor)
        menu.onSelect = { [weak self] chosen in
            switch chosen.id {
            case "play": self?.playAgain(item)
            case "details": self?.open(item)
            case "remove": self?.remove(item)
            default: break
            }
        }
        menu.present(in: window)
    }

    private func remove(_ item: HistoryItem) {
        guard let historyKey = item.historyKey else { return }
        let api = api
        Task { [weak self] in
            do {
                try await LibraryManagement.deleteHistoryEntry(historyKey: historyKey, api: api)
                self?.feed.drop(item)
                self?.render()
            } catch {
                guard let window = self?.window else { return }
                AlertView.notice(title: ManageCopy.failed, message: ConnectionError.message(for: error), in: window)
            }
        }
    }

    override func layoutSubviews() {
        page.topInset = Theme.current.metrics.tabBarClearance
        page.frame = bounds
        state.frame = bounds
        page.setNeedsLayout()
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

extension HistoryScreen: Reloadable {
    func reload() {
        refresh()
    }
}

extension View {
    /// The nearest view of type `T` holding this one, itself included.
    func enclosing<T: View>(_ type: T.Type) -> T? {
        var current: View? = self
        while let view = current {
            if let match = view as? T { return match }
            current = view.superview
        }
        return nil
    }
}

/// One day of the history: its header and its plays.
@MainActor
private final class HistoryDaySection: View {
    var onOpen: ((HistoryItem) -> Void)?
    var onPlay: ((HistoryItem) -> Void)?
    var onMenu: ((HistoryItem, Point?) -> Void)?

    private var title = ""
    private var rows: [String: HistoryRowView] = [:]
    private var order: [String] = []

    override var remembersFocus: Bool { true }

    var firstRow: View? { order.first.flatMap { rows[$0]?.plate } }

    func update(title newTitle: String, items: [HistoryItem], busy: Set<String>) {
        title = newTitle
        var next: [String: HistoryRowView] = [:]
        for item in items {
            let row = rows[item.uniqueId] ?? HistoryRowView(item: item)
            row.item = item
            row.isBusy = busy.contains(item.uniqueId)
            row.onOpen = { [weak self] item in self?.onOpen?(item) }
            row.onPlay = { [weak self] item in self?.onPlay?(item) }
            row.onMenu = { [weak self] item, point in self?.onMenu?(item, point) }
            if row.superview == nil { addSubview(row) }
            next[item.uniqueId] = row
        }
        for (id, row) in rows where next[id] == nil { row.removeFromSuperview() }
        rows = next
        order = items.map(\.uniqueId)
        setNeedsLayout()
        setNeedsDisplay()
    }

    private var headerHeight: Float { Theme.current.metrics.tv(64) }
    private var rowHeight: Float { Theme.current.metrics.tv(144) }
    private var spacing: Float { Theme.current.metrics.tv(12) }

    override func sizeThatFits(_ size: Size) -> Size {
        let count = Float(order.count)
        return Size(width: size.width, height: headerHeight + count * rowHeight + max(count - 1, 0) * spacing + Theme.current.metrics.tv(40))
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let width = min(frame.width - metrics.sideMargin * 2, metrics.tv(1400))
        var y = headerHeight
        for id in order {
            rows[id]?.frame = Rect(x: metrics.sideMargin, y: y, width: width, height: rowHeight)
            y += rowHeight + spacing
        }
    }

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let theme = Theme.current
        let layout = TextLayout(title, font: theme.type.headline, scale: scale)
        context.text(layout, at: Point(x: theme.metrics.sideMargin, y: headerHeight - layout.size.height - theme.metrics.tv(12)), color: theme.palette.label)
    }
}

/// A play in the history (`HistoryRowView`): a plate with the poster, the title, the episode line and the time, lifted onto
/// the light plate under focus, and a glass Play Again button beside it that turns into a spinner while it starts.
@MainActor
private final class HistoryRowView: View {
    var item: HistoryItem { didSet { plate.presentation = item.row } }
    var isBusy = false { didSet { if isBusy != oldValue { setNeedsLayout() } } }
    var onOpen: ((HistoryItem) -> Void)?
    var onPlay: ((HistoryItem) -> Void)?
    var onMenu: ((HistoryItem, Point?) -> Void)?

    let plate: HistoryPlate
    private let play = ButtonView(style: .glass, title: nil, symbol: "play.fill")
    private let spinner = SpinnerView()

    init(item: HistoryItem) {
        self.item = item
        plate = HistoryPlate(presentation: item.row)
        super.init()
        plate.onActivate = { [weak self] in
            guard let self else { return }
            self.onOpen?(self.item)
        }
        plate.onPlay = { [weak self] in
            guard let self else { return }
            self.onPlay?(self.item)
        }
        plate.onMenu = { [weak self] point in
            guard let self else { return }
            self.onMenu?(self.item, point)
        }
        play.onPress = { [weak self] in
            guard let self else { return }
            self.onPlay?(self.item)
        }
        [plate, play, spinner].forEach(addSubview)
    }

    override var remembersFocus: Bool { true }
    override var preferredFocusView: View? { plate }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let side = metrics.tv(76)
        let buttonX = frame.width - side
        plate.frame = Rect(x: 0, y: 0, width: buttonX - metrics.tv(40), height: frame.height)
        play.frame = Rect(x: buttonX, y: (frame.height - side) / 2, width: side, height: side)
        spinner.frame = play.frame.insetBy(side * 0.2, side * 0.2)
        play.isHidden = isBusy
        spinner.isHidden = !isBusy
    }
}

/// The focusable part of a history row.
@MainActor
private final class HistoryPlate: View {
    var presentation: HistoryRowPresentation { didSet { if presentation != oldValue { poster.source = Self.source(presentation); setNeedsDisplay() } } }
    var onActivate: (() -> Void)?
    var onPlay: (() -> Void)?
    var onMenu: ((Point?) -> Void)?

    private let poster = ArtworkView()
    private var lift = Animated(0)

    init(presentation: HistoryRowPresentation) {
        self.presentation = presentation
        super.init()
        poster.source = Self.source(presentation)
        poster.cornerRadius = Theme.current.metrics.radiusXS
        addSubview(poster)
    }

    private static func source(_ presentation: HistoryRowPresentation) -> ArtworkSource? {
        presentation.posterPath.map { .path($0, .poster) }
    }

    override var canBecomeFocused: Bool { true }
    override var accessibilityLabel: String? { [presentation.title, presentation.subtitle, presentation.timeText].compactMap { $0 }.joined(separator: ", ") }

    private func update() {
        lift.set((isFocused && (window?.isFocusVisible ?? false)) || isHovered ? 1 : 0, animation: .focus)
        startAnimating()
    }

    override func focusDidChange(focused: Bool, animated: Bool) { update() }
    override func focusVisibilityDidChange(_ visible: Bool) { update() }
    override func pointerEntered() { update() }
    override func pointerExited() { update() }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        switch button {
        case .primary: return true
        case .secondary:
            onMenu?(transformToWindow.apply(point))
            return true
        default: return false
        }
    }

    override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        guard button == .primary, inside else { return }
        window?.focus.focus(self, animated: true, reveal: false)
        onActivate?()
    }

    override func activate() { onActivate?() }

    override func showContextMenu(at point: Point?) -> Bool {
        onMenu?(point)
        return true
    }

    override func keyPressed(_ event: KeyEvent) -> Bool {
        guard event.key == .mediaPlay || event.key == .mediaPause else { return false }
        onPlay?()
        return true
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = lift.advance(dt)
        setNeedsDisplay()
        return moving
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let height = metrics.tv(120)
        poster.frame = Rect(x: metrics.tv(12), y: (frame.height - height) / 2, width: metrics.tv(80), height: height)
    }

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let theme = Theme.current
        let metrics = theme.metrics
        let palette = theme.palette
        if lift.value > 0.01 {
            context.transformed(scale: 1 + 0.02 * lift.value, about: bounds.center) { inner in
                inner.shadow(bounds, radius: metrics.radiusM, blur: metrics.tv(24), offsetY: metrics.tv(10), opacity: 0.3 * lift.value)
                inner.fill(bounds, radius: metrics.radiusM, color: palette.focusFill.withAlpha(lift.value))
            }
        }
        let label = palette.label.mixed(with: palette.onFocusFill, amount: lift.value)
        let secondary = palette.labelSecondary.mixed(with: palette.onFocusFillSecondary, amount: lift.value)
        let time = presentation.timeText.map { TextLayout($0, font: theme.type.body, scale: scale) }
        let x = poster.frame.maxX + metrics.tv(28)
        let width = bounds.width - x - metrics.tv(28) - (time.map { $0.size.width + metrics.tv(24) } ?? 0)
        let title = TextLayout(presentation.title, font: theme.type.rowTitle, maxWidth: width, scale: scale)
        let subtitle = TextLayout(presentation.subtitle, font: theme.type.cardSubtitle, maxWidth: width, scale: scale)
        let top = ((bounds.height - title.size.height - subtitle.size.height - metrics.tv(4)) / 2).rounded()
        context.text(title, at: Point(x: x, y: top), color: label)
        context.text(subtitle, at: Point(x: x, y: top + title.size.height + metrics.tv(4)), color: secondary)
        if let time {
            context.text(time, at: Point(x: bounds.width - metrics.tv(28) - time.size.width, y: ((bounds.height - time.size.height) / 2).rounded()),
                         color: secondary)
        }
    }
}

/// A symbol, a title and a message drawn in the page (No Matches for a filter).
@MainActor
final class InlineMessageView: View {
    var content: HistoryEmptyState.Content? { didSet { setNeedsDisplay() } }

    override func sizeThatFits(_ size: Size) -> Size { Size(width: size.width, height: Theme.current.metrics.tv(460)) }

    override func draw(_ context: inout DrawContext) {
        guard let content, let scale = window?.scale else { return }
        let theme = Theme.current
        let metrics = theme.metrics
        let symbol = metrics.symbolState
        var y = metrics.tv(80)
        context.symbol(Symbol(content.symbolName), in: Rect(x: bounds.midX - symbol / 2, y: y, width: symbol, height: symbol), color: theme.palette.labelTertiary)
        y += symbol + metrics.tv(24)
        let title = TextLayout(content.title, font: theme.type.title3, maxWidth: metrics.messageColumn, alignment: .center, scale: scale)
        context.text(title, at: Point(x: ((bounds.width - title.size.width) / 2).rounded(), y: y), color: theme.palette.label)
        y += title.size.height + metrics.tv(12)
        if let message = content.message {
            let body = TextLayout(message, font: theme.type.callout, maxWidth: metrics.messageColumn, maxLines: 3, alignment: .center, scale: scale)
            context.text(body, at: Point(x: ((bounds.width - body.size.width) / 2).rounded(), y: y), color: theme.palette.labelSecondary)
        }
    }
}

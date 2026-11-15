import CrucibleCore
import CrucibleStats
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// Statistics (`TVStatisticsViewController`): the Week, Month, Year and All chips with the Plex or Everything source while
/// Trakt is connected and the Libraries filter, then the ember hero with its count-up, the KPI tiles, the activity heat map,
/// top shows and movies, when you watch, your momentum, your libraries, binges, your taste, On This Day and Wrapped moments.
/// Every section takes focus, so the keyboard walks the whole page. The mirror of the Plex history syncs each time the
/// screen appears and the page reloads once it has.
@MainActor
final class StatisticsScreen: ScreenView {
    private enum Control {
        static let source = "stats.source"
        static let libraries = "stats.libraries"

        static func range(_ range: StatsRange) -> String { "stats.range.\(range.rawValue)" }
    }

    private let api: APIClient
    private let page = PageView()
    private let heading = ScreenTitleView(title: String(localized: "Statistics"))
    private let controls = ChipRowView()
    private let state = StateView()
    private var range = StatsRange.year
    private var source = StatsSourceChoice.initial()
    private var shown = StatsPage.empty
    private var isShowingContent = false
    private var syncedAtLeastOnce = false
    private var loadTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var observers: [() -> Void] = []

    init(api: APIClient) {
        self.api = api
        super.init()
        [page, state].forEach(addSubview)
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        page.setSections([heading, controls])
        controls.onSelect = { [weak self] chip in self?.controlSelected(chip.id) }
        updateControls()
        state.show(.loading(title: StatsPlaceholder.loading.title))
    }

    override var preferredFocusView: View? { state.isHidden ? controls : state }
    override var remembersFocus: Bool { true }

    override func screenDidAppear() {
        startObserving()
        load(animate: !isShowingContent)
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            let ran = await StatsManager.shared.refreshNow()
            guard let self, !Task.isCancelled else { return }
            self.syncedAtLeastOnce = self.syncedAtLeastOnce || ran
            self.load(animate: false)
        }
    }

    override func screenWillDisappear() {
        loadTask?.cancel()
        syncTask?.cancel()
        observers.forEach { $0() }
        observers.removeAll()
    }

    /// Library visibility and Trakt reload the page while it is up.
    private func startObserving() {
        guard observers.isEmpty else { return }
        let visibility = LibraryVisibility.addObserver { [weak self] in
            self?.updateControls()
            self?.load(animate: false)
        }
        let trakt = TraktAccount.shared.observe { [weak self] in
            guard let self else { return }
            self.source = StatsSourceChoice.initial()
            self.updateControls()
            self.load(animate: false)
        }
        observers = [{ LibraryVisibility.removeObserver(visibility) }, { TraktAccount.shared.stopObserving(trakt) }]
    }

    // MARK: Loading

    private func load(animate: Bool) {
        guard let loader = StatsManager.shared.pageLoader else {
            show(placeholder: .unavailable)
            return
        }
        let range = range
        let source = source
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            do {
                let loaded = try await loader.load(range: range, source: source)
                guard let self, !Task.isCancelled else { return }
                self.apply(loaded, animate: animate)
            } catch {
                guard let self, !Task.isCancelled else { return }
                MidgarLog.error("Statistics failed to load: \(error)", category: .stats)
                guard !self.isShowingContent else { return }
                self.state.show(.error(title: String(localized: "Couldn’t Load Statistics"), message: String(localized: "The local statistics store could not be read."),
                                       retryTitle: String(localized: "Try Again"), retry: { [weak self] in self?.load(animate: true) }))
                self.revealState()
            }
        }
    }

    private func apply(_ loaded: StatsPage, animate: Bool) {
        if !loaded.isEmpty, loaded == shown, isShowingContent { return }
        shown = loaded
        updateControls()
        guard !loaded.isEmpty else {
            isShowingContent = false
            page.setSections([heading, controls])
            show(placeholder: StatsPlaceholder.forEmptyPage(syncedAtLeastOnce: syncedAtLeastOnce, librariesFiltered: LibraryVisibility.isCustomized))
            return
        }
        DemoTour.shared.record(.statistics)
        let focusedID = window?.focusedView.flatMap { focused in sectionViews.first { focused.isDescendant(of: $0.view) }?.id }
        sectionViews = StatsSections.make(loaded, animate: animate, open: { [weak self] destination in self?.open(destination) })
        page.setSections([heading, controls] + sectionViews.map(\.view))
        isShowingContent = true
        page.isHidden = false
        state.isHidden = true
        if let focusedID, let view = sectionViews.first(where: { $0.id == focusedID })?.view { window?.focus.focus(view, animated: false) }
        setNeedsLayout()
    }

    private var sectionViews: [(id: String, view: View)] = []

    private func show(placeholder: StatsPlaceholder) {
        switch placeholder {
        case .loading:
            state.show(.loading(title: placeholder.title))
        case .unavailable:
            state.show(.empty(title: placeholder.title, message: placeholder.message, symbol: Symbol(placeholder.symbol ?? "exclamationmark.triangle"), action: nil))
        case .empty(let filtered):
            let include = StateView.Action(title: String(localized: "Include All Libraries")) {
                let filter = StatsLibraryFilter.current()
                filter.entries.filter { !$0.isIncluded }.forEach { filter.toggle($0) }
            }
            state.show(.empty(title: placeholder.title, message: placeholder.message, symbol: Symbol(placeholder.symbol ?? "chart.bar.xaxis"),
                              action: filtered ? include : nil))
        }
        revealState()
    }

    private func revealState() {
        let hadFocus = page.containsFocus && !controls.containsFocus
        state.isHidden = false
        if hadFocus { window?.focus.focus(state, animated: false) }
    }

    private func open(_ destination: StatsDestination) {
        guard destination.isOnServer else { return }
        switch destination {
        case .movie(let key):
            rootView?.push(DetailScreen.make(api: api, route: .item(ratingKey: key, mediaType: "movie", showRatingKey: nil, seasonRatingKey: nil)))
        case .episode(let key, let show):
            rootView?.push(DetailScreen.make(api: api, route: .item(ratingKey: key, mediaType: "episode", showRatingKey: show, seasonRatingKey: nil)))
        case .show(let key):
            rootView?.push(DetailScreen.make(api: api, route: .show(ratingKey: key, initialSeasonKey: nil)))
        }
    }

    // MARK: Controls

    private func updateControls() {
        var chips = StatsRange.allCases.map { candidate in
            ChipRowView.Chip(id: Control.range(candidate), title: candidate.title, isSelected: candidate == range)
        }
        if StatsManager.shared.offersEverything {
            chips.append(ChipRowView.Chip(id: Control.source, title: source.title, symbol: "line.3.horizontal.decrease"))
        }
        let filter = StatsLibraryFilter.current()
        if filter.isAvailable {
            chips.append(ChipRowView.Chip(id: Control.libraries, title: filter.isCustomized ? String(localized: "Libraries · Filtered") : String(localized: "Libraries"),
                                          symbol: Symbol(filter.symbol), isSelected: filter.isCustomized))
        }
        controls.setChips(chips)
    }

    private func controlSelected(_ id: String) {
        if let chosen = StatsRange.allCases.first(where: { Control.range($0) == id }) {
            guard chosen != range else { return }
            range = chosen
            updateControls()
            load(animate: true)
            return
        }
        switch id {
        case Control.source: presentSources()
        case Control.libraries: presentLibraries()
        default: break
        }
    }

    private func presentSources() {
        guard let window else { return }
        let menu = MenuView(title: String(localized: "Source"), items: StatsSource.allCases.map { candidate in
            MenuView.Item(id: candidate.title, title: candidate.title, detail: candidate.accessibilityLabel, isChecked: candidate == source)
        }, anchor: controls.frameInWindow(of: Control.source) ?? controls.frameInWindow)
        menu.onSelect = { [weak self] item in
            guard let self, let chosen = StatsSource.allCases.first(where: { $0.title == item.id }), chosen != self.source else { return }
            self.source = chosen
            StatsSourceChoice.remember(chosen)
            self.updateControls()
            self.load(animate: true)
        }
        menu.present(in: window)
    }

    /// Include in Statistics: a switch per library (the last one on cannot go), and Reset to Plex Defaults once anything differs.
    private func presentLibraries() {
        guard let window else { return }
        let filter = StatsLibraryFilter.current()
        var items = filter.entries.map { entry in
            MenuView.Item(id: "library.\(entry.id)", title: entry.title, detail: entry.subtitle, symbol: Symbol(entry.symbol), isChecked: entry.isIncluded)
        }
        if filter.hasOverrides {
            items.append(MenuView.Item(id: "reset", title: String(localized: "Reset to Plex Defaults"), symbol: "arrow.counterclockwise"))
        }
        let menu = MenuView(title: String(localized: "Include in Statistics"), items: items, anchor: controls.frameInWindow(of: Control.libraries) ?? controls.frameInWindow)
        menu.onSelect = { item in
            if item.id == "reset" {
                filter.resetToPlexDefaults()
            } else if let entry = filter.entries.first(where: { "library.\($0.id)" == item.id }), !entry.isLocked {
                filter.toggle(entry)
            }
        }
        menu.present(in: window)
    }

    override func layoutSubviews() {
        page.topInset = Theme.current.metrics.tabBarClearance
        page.frame = bounds
        let top = controls.frame.maxY > 0 ? controls.frame.maxY + Theme.current.metrics.tv(40) : Theme.current.metrics.tabBarClearance + Theme.current.metrics.tv(260)
        state.frame = Rect(x: 0, y: top, width: frame.width, height: max(0, frame.height - top))
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

extension StatisticsScreen: Reloadable {
    func reload() {
        load(animate: false)
    }
}

/// The sections of a Statistics page as views, each keyed so focus can find its way back after a reload.
@MainActor
enum StatsSections {
    static func make(_ page: StatsPage, animate: Bool, open: @escaping (StatsDestination) -> Void) -> [(id: String, view: View)] {
        var sections: [(id: String, view: View)] = []
        for section in [StatsPageSection.hero, .kpis, .heatmap, .topShows, .topMovies, .clock, .momentum, .libraries, .binges, .genres, .onThisDay, .superlatives]
        where page.sections.contains(section) {
            guard let view = view(for: section, page: page, animate: animate, open: open) else { continue }
            sections.append(("\(section)", view))
        }
        return sections
    }

    private static func view(for section: StatsPageSection, page: StatsPage, animate: Bool, open: @escaping (StatsDestination) -> Void) -> View? {
        switch section {
        case .hero:
            let hero = StatsHeroView()
            let content = page.hero
            hero.configure(eyebrow: content.eyebrow, value: content.value, unit: content.unit, detail: content.detail, since: content.since,
                           stripLevels: YearInReviewSummary.stripLevels(from: page.snapshot.heatmap, today: StatsTime().todayDayEpoch()), animate: animate)
            return Margins(hero)
        case .kpis:
            return Margins(TileGrid(page.tiles.map { tile in
                let view = StatTileView()
                view.configure(title: tile.title, value: tile.value, symbol: Symbol(tile.systemImage), caption: tile.caption, sparkline: tile.sparkline, animate: animate)
                return StatsPanelView(content: view, flush: true)
            }))
        case .heatmap:
            let heatmap = ContributionHeatmapView()
            let model = page.heatmap
            heatmap.configure(columns: model.columns, lastDayIndex: model.lastDayEpoch - model.firstDayEpoch,
                              cells: model.cells.map { ContributionHeatmapView.Cell(column: $0.column, row: $0.row, level: $0.level) },
                              monthLabels: model.monthLabels.sorted { $0.key < $1.key }.map { (column: $0.key, text: $0.value) }, animate: animate)
            return Margins(StatsPanelView(title: String(localized: "Activity"), accessory: StatsHeatLegendView(), content: heatmap))
        case .topShows:
            return shelf(String(localized: "Top Shows"), items: page.topShows.map { show in
                var subtitle = show.valueText
                if let completion = show.completion { subtitle += " · \(Int((completion * 100).rounded()))%" }
                let card = CardItem(id: "show-\(show.ratingKey)", artwork: show.thumb.map { .path($0, .poster) }, title: show.title, subtitle: subtitle,
                                    badgeText: "#\(show.rank)", placeholderSymbol: "tv")
                return (card, StatsDestination.show(ratingKey: show.ratingKey))
            }, open: open)
        case .topMovies:
            return shelf(String(localized: "Top Movies"), items: page.topMovies.map { (card($0, id: "movie-\($0.destination)"), $0.destination) }, open: open)
        case .onThisDay:
            return shelf(String(localized: "On This Day"), items: page.onThisDay.enumerated().map { (card($1, id: "day-\($0)-\($1.destination)"), $1.destination) }, open: open)
        case .clock:
            let clock = ClockSection()
            clock.configure(page.clock, animate: animate)
            return Margins(StatsPanelView(title: String(localized: "When You Watch"), content: clock))
        case .momentum:
            guard let momentum = page.momentum else { return nil }
            let trend = TrendAreaView()
            trend.configure(values: momentum.values, peakText: momentum.peakText, animate: animate)
            return Margins(StatsPanelView(title: String(localized: "Your Momentum"), content: trend))
        case .libraries:
            let libraries = page.libraries
            let breakdown = LibrariesBreakdownView()
            breakdown.configure(slices: zip(libraries.segments, libraries.legend).map { segment, row in
                LibrariesBreakdownView.Slice(title: row.title, value: segment.value, valueText: row.value, colorIndex: row.colorIndex)
            }, centerTitle: libraries.centerTitle, centerSubtitle: libraries.centerSubtitle, animate: animate)
            return Margins(StatsPanelView(title: String(localized: "Your Libraries"), content: breakdown))
        case .genres:
            let taste = TasteView()
            switch page.genres {
            case .pending(let pending): taste.showPending(title: pending.title, fraction: pending.barFraction)
            case .ranked(let rows):
                taste.show(rows: rows.map { TasteView.Row(title: $0.title, valueText: $0.valueText, fraction: $0.fraction, colorIndex: $0.colorIndex) })
            }
            return Margins(StatsPanelView(title: String(localized: "Your Taste"), content: taste))
        case .binges:
            let shelf = PanelShelfView(title: String(localized: "Binges & Streaks"), height: BingeCardView.height)
            shelf.setPanels(page.binges.enumerated().map { index, session in
                let count = session.episodeCount == 1 ? String(localized: "1 ep") : String(localized: "\(session.episodeCount) eps")
                let panel = StatsPanelView(content: BingeCardView(title: session.showTitle, episodes: session.episodeCount, countText: count,
                                                                  caption: session.endedCaption ?? "", colorIndex: index), flush: true)
                if let key = session.showRatingKey { panel.onSelect = { open(.show(ratingKey: key)) } }
                return panel
            })
            return shelf
        case .superlatives:
            let shelf = PanelShelfView(title: String(localized: "Wrapped Moments"), height: Theme.current.metrics.tv(380))
            shelf.setPanels(page.superlatives.map { moment in
                StatsPanelView(content: SuperlativeCardView(symbol: Symbol(moment.symbol), headline: moment.headline, title: moment.title, caption: moment.caption),
                               flush: true)
            })
            return shelf
        }
    }

    private static func card(_ poster: StatsPoster, id: String) -> CardItem {
        CardItem(id: id, artwork: poster.posterPath.map { .path($0, .poster) }, title: poster.title, subtitle: poster.subtitle,
                 placeholderSymbol: Symbol(poster.placeholderSymbol))
    }

    private static func shelf(_ title: String, items: [(card: CardItem, destination: StatsDestination)], open: @escaping (StatsDestination) -> Void) -> View {
        let shelf = ShelfView(header: SectionHeader(title: title), style: .poster)
        shelf.setItems(items.map(\.card))
        let destinations = Dictionary(items.map { ($0.card.id, $0.destination) }, uniquingKeysWith: { first, _ in first })
        shelf.onActivate = { card in destinations[card.id].map(open) }
        return shelf
    }
}

/// A section inset to the side margins with the page's room below it.
@MainActor
private final class Margins: View {
    private let child: View

    init(_ child: View) {
        self.child = child
        super.init()
        addSubview(child)
    }

    override var preferredFocusView: View? { child }
    override var remembersFocus: Bool { true }

    private var margin: Float { Theme.current.metrics.sideMargin }

    override func sizeThatFits(_ size: Size) -> Size {
        let inner = child.sizeThatFits(Size(width: size.width - margin * 2, height: 0))
        return Size(width: size.width, height: inner.height + Theme.current.metrics.tv(44))
    }

    override func layoutSubviews() {
        let height = child.sizeThatFits(Size(width: frame.width - margin * 2, height: 0)).height
        child.frame = Rect(x: margin, y: 0, width: frame.width - margin * 2, height: height)
    }
}

/// The KPI tiles three to a row (two in a narrow window), the gutter between them.
@MainActor
private final class TileGrid: View {
    private let tiles: [View]

    init(_ tiles: [View]) {
        self.tiles = tiles
        super.init()
        tiles.forEach(addSubview)
    }

    override var preferredFocusView: View? { tiles.first }
    override var remembersFocus: Bool { true }

    private func columns(_ width: Float) -> Int { width < Theme.current.metrics.tv(1300) ? 2 : 3 }

    private func tileSize(_ width: Float) -> Size {
        let gutter = Theme.current.metrics.gutter
        let count = Float(columns(width))
        let tileWidth = ((width - gutter * (count - 1)) / count).rounded(.down)
        let height = tiles.map { $0.sizeThatFits(Size(width: tileWidth, height: 0)).height }.max() ?? 0
        return Size(width: tileWidth, height: height)
    }

    override func sizeThatFits(_ size: Size) -> Size {
        let tile = tileSize(size.width)
        let rows = Float((tiles.count + columns(size.width) - 1) / columns(size.width))
        return Size(width: size.width, height: rows * tile.height + max(0, rows - 1) * Theme.current.metrics.gutter)
    }

    override func layoutSubviews() {
        let gutter = Theme.current.metrics.gutter
        let tile = tileSize(frame.width)
        let count = columns(frame.width)
        for (index, view) in tiles.enumerated() {
            let column = Float(index % count)
            let row = Float(index / count)
            view.frame = Rect(x: column * (tile.width + gutter), y: row * (tile.height + gutter), width: tile.width, height: tile.height)
        }
    }
}

/// When You Watch: the clock and the weekday columns side by side (stacked in a narrow window) over the verdict line.
@MainActor
private final class ClockSection: View {
    private let clock = RadialClockView()
    private let weekdays = WeekdayChartView()
    private var verdict = ""

    init() {
        super.init()
        [clock, weekdays].forEach(addSubview)
    }

    func configure(_ model: StatsPage.Clock, animate: Bool) {
        clock.configure(hours: model.hours, animate: animate)
        let values = model.weekdays.count == 7 ? model.weekdays : Array(repeating: 0, count: 7)
        weekdays.configure(values: values, initials: (1...7).map { String(StatsFormat.weekdayShort($0).prefix(1)) },
                           counts: values.map(StatsFormat.abbreviatedCount), animate: animate)
        verdict = model.verdict
        setNeedsLayout()
    }

    private var metrics: Metrics { Theme.current.metrics }

    private func isStacked(_ width: Float) -> Bool { width < RadialClockView.side + metrics.tv(48) + metrics.tv(500) }

    /// The clock's side: the Apple TV's 440 points, grown with a wide card to a quarter of it (at most 700 points), so the
    /// clock keeps the share of the card it has on a television.
    private func clockSide(_ width: Float) -> Float {
        isStacked(width) ? RadialClockView.side : min(metrics.tv(700), max(RadialClockView.side, width * 0.25))
    }

    /// Beside the clock the columns stand most of its height.
    private func weekdayHeight(_ width: Float) -> Float {
        let natural = weekdays.sizeThatFits(Size(width: width, height: 0)).height
        return isStacked(width) ? natural : max(natural, clockSide(width) * 0.85)
    }

    private func verdictLayout(width: Float) -> TextLayout? {
        guard !verdict.isEmpty else { return nil }
        return TextLayout(verdict, font: Font(size: metrics.tv(35), weight: .semibold), maxWidth: width, maxLines: 2, alignment: .center, scale: window?.scale ?? 1)
    }

    private func chartsHeight(_ width: Float) -> Float {
        isStacked(width) ? RadialClockView.side + metrics.tv(32) + weekdayHeight(width) : max(clockSide(width), weekdayHeight(width))
    }

    override func sizeThatFits(_ size: Size) -> Size {
        let verdictHeight = verdictLayout(width: size.width).map { $0.size.height + metrics.tv(32) } ?? 0
        return Size(width: size.width, height: chartsHeight(size.width) + verdictHeight)
    }

    override func layoutSubviews() {
        let side = clockSide(frame.width)
        let weekdayHeight = weekdayHeight(frame.width)
        if isStacked(frame.width) {
            clock.frame = Rect(x: ((frame.width - side) / 2).rounded(), y: 0, width: side, height: side)
            weekdays.frame = Rect(x: 0, y: side + metrics.tv(32), width: frame.width, height: weekdayHeight)
        } else {
            let height = chartsHeight(frame.width)
            clock.frame = Rect(x: 0, y: ((height - side) / 2).rounded(), width: side, height: side)
            let x = side + metrics.tv(48)
            weekdays.frame = Rect(x: x, y: ((height - weekdayHeight) / 2).rounded(), width: frame.width - x, height: weekdayHeight)
        }
    }

    override func draw(_ context: inout DrawContext) {
        guard let layout = verdictLayout(width: frame.width) else { return }
        let y = chartsHeight(frame.width) + metrics.tv(32)
        context.text(layout, at: Point(x: ((frame.width - layout.size.width) / 2).rounded(), y: y), color: Theme.current.palette.accentText)
    }
}

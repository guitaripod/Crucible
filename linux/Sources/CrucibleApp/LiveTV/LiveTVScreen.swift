import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// The Live TV destination: the title with its Beta tag, the filters (all channels, favourites, recent, each source and
/// group) beside Recordings, Playlists and Now, what the focused airing is, and the guide. Select plays a channel that is
/// on, or opens what can be done with an airing still to come (record it on a tuner, watch the channel now).
@MainActor
final class LiveTVScreen: ScreenView, Reloadable {
    private let payload: LaunchPayload
    private let guide: LiveTVGuide
    private let header = LiveTVHeaderView()
    private let chips = ChipRowView()
    private let panel = LiveProgramPanel()
    private let grid = GuideGridView()
    private let state = StateView()
    private var clock: Task<Void, Never>?
    private var scheduledKeys: Set<String> = []
    private var scheduledTask: Task<Void, Never>?
    private var recordingsObserver: NSObjectProtocol?
    private var hasRendered = false
    /// Whether the guide has taken the focus since its rows first arrived; until then the focus waits on the filters.
    private var guideTookFocus = false

    init(payload: LaunchPayload) {
        self.payload = payload
        guide = LiveTVGuide(context: LiveTVGuide.Context(payload: payload))
        super.init()
        [header, chips, panel, grid, state].forEach(addSubview)
        state.isHidden = true
        header.tag.onPress = { [weak self] in self?.presentBetaNote() }
        header.tag.invites = !LiveTVPreferences.hasSeenBetaNote
        chips.onSelect = { [weak self] chip in self?.choose(chip.id) }
        grid.timeLabel = { LiveGuideMath.slotLabel($0) }
        grid.loadingText = LiveTVCopy.loadingGuide
        grid.emptyText = LiveTVCopy.noGuide
        grid.onVisibleRows = { [weak self] ids in self?.guide.loadPrograms(for: ids) }
        grid.onFocusMove = { [weak self] row, cell in self?.showPanel(row: row, cell: cell) }
        grid.onActivate = { [weak self] row, cell in self?.activate(row: row, cell: cell) }
        grid.onPlay = { [weak self] row in self?.play(row.id) }
        grid.onContextMenu = { [weak self] row, cell, point in self?.presentMenu(row: row, cell: cell, at: point) }
        guide.onChange = { [weak self] in self?.render() }
        guide.onPrograms = { [weak self] ids in self?.programsArrived(ids) }
        recordingsObserver = NotificationCenter.default.addObserver(forName: .liveRecordingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadScheduled() }
        }
    }

    isolated deinit {
        clock?.cancel()
        scheduledTask?.cancel()
        if let recordingsObserver { NotificationCenter.default.removeObserver(recordingsObserver) }
    }

    override var preferredFocusView: View? {
        if !state.isHidden { return state }
        return grid.rows.isEmpty ? chips : grid
    }

    override var remembersFocus: Bool { true }

    override func screenDidAppear() {
        if !hasRendered {
            hasRendered = true
            guide.load()
        }
        startClock()
    }

    override func screenWillDisappear() {
        clock?.cancel()
        clock = nil
    }

    func reload() {
        guide.load(force: true)
    }

    /// Keeps the line at the present moment and the guide's start on the current half hour.
    private func startClock() {
        clock?.cancel()
        tick()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.tick()
            }
        }
    }

    private func tick() {
        let now = Date()
        grid.now = now
        let origin = LiveGuideMath.slotStart(now)
        if grid.origin != origin { grid.origin = origin }
        if let focused = grid.focused { showPanel(row: focused.row, cell: focused.cell) }
    }

    // MARK: Rendering

    private func render() {
        switch guide.state {
        case .loading:
            showState(.loading(title: nil))
        case .empty:
            showState(.empty(title: LiveTVCopy.emptyTitle, message: LiveTVCopy.emptyText, symbol: "antenna.radiowaves.left.and.right",
                             action: .init(title: LiveTVCopy.addPlaylist) { [weak self] in self?.openPlaylists(adding: true) }))
        case .failed(let message):
            showState(.error(title: LiveTVCopy.failedTitle, message: message, retryTitle: LiveTVCopy.tryAgain, retry: { [weak self] in self?.guide.load(force: true) },
                             secondary: .init(title: LiveTVCopy.playlists) { [weak self] in self?.openPlaylists(adding: false) }))
        case .ready:
            showState(nil)
        }
        renderChips()
        let channels = guide.visibleChannels
        grid.rows = channels.map(row(for:))
        if guide.state == .ready, channels.isEmpty, guide.filter == .favorites {
            showState(.empty(title: LiveTVCopy.favorites, message: LiveTVCopy.noFavoritesText, symbol: "star", action: .init(title: LiveTVCopy.allChannels) { [weak self] in
                self?.guide.filter = .all
            }))
        }
        if grid.focused == nil, let first = channels.first { grid.focusRow(LiveTVPreferences.recentChannels.first.flatMap { id in channels.first { $0.id == id }?.id } ?? first.id) }
        if let focused = grid.focused { showPanel(row: focused.row, cell: focused.cell) }
        if !guideTookFocus, !grid.rows.isEmpty, !grid.isHidden {
            guideTookFocus = true
            if containsFocus, !grid.containsFocus { window?.focus.focus(grid, animated: false) }
        }
        loadScheduled()
        setNeedsLayout()
    }

    private func showState(_ newState: StateView.State?) {
        let hadFocus = containsFocus
        if let newState {
            state.show(newState)
            state.isHidden = false
            grid.isHidden = true
            panel.isHidden = true
        } else {
            state.isHidden = true
            grid.isHidden = false
            panel.isHidden = false
        }
        if hadFocus { window?.focus.focus(preferredFocusView, animated: false) }
    }

    private func renderChips() {
        var list = guide.filters().filter { if case .group = $0 { false } else { true } }.map { filter in
            ChipRowView.Chip(id: Self.chipID(filter), title: guide.title(of: filter), symbol: Self.symbol(of: filter), isSelected: filter == guide.filter)
        }
        if !guide.groups().isEmpty {
            let current: String? = if case .group(let name) = guide.filter { name } else { nil }
            list.append(ChipRowView.Chip(id: "categories", title: current ?? LiveTVCopy.categories, isSelected: current != nil, opensMenu: true))
        }
        list.append(ChipRowView.Chip(id: "now", title: LiveTVCopy.jumpToNow, symbol: "clock"))
        if guide.canRecord { list.append(ChipRowView.Chip(id: "recordings", title: LiveTVCopy.recordings, symbol: "record.circle")) }
        list.append(ChipRowView.Chip(id: "playlists", title: LiveTVCopy.playlists, symbol: "list.bullet"))
        chips.setChips(list)
    }

    private static func chipID(_ filter: LiveTVGuide.Filter) -> String {
        switch filter {
        case .all: "f.all"
        case .favorites: "f.favorites"
        case .recent: "f.recent"
        case .source(let id): "f.source.\(id)"
        case .group(let name): "f.group.\(name)"
        }
    }

    private static func symbol(of filter: LiveTVGuide.Filter) -> Symbol? {
        switch filter {
        case .all: "square.grid.2x2"
        case .favorites: "star"
        case .recent: "clock.arrow.circlepath"
        case .source: "antenna.radiowaves.left.and.right"
        case .group: nil
        }
    }

    private func choose(_ id: String) {
        switch id {
        case "now": grid.jumpToNow()
        case "categories": presentCategories()
        case "recordings": rootView?.push(LiveRecordingsScreen(api: payload.api))
        case "playlists": openPlaylists(adding: false)
        default:
            if let filter = guide.filters().first(where: { Self.chipID($0) == id }) { guide.filter = filter }
        }
    }

    /// The groups the channels are filed under, as a menu below the Categories chip.
    private func presentCategories() {
        guard let window else { return }
        let anchor = chips.frameInWindow(of: "categories") ?? Rect(x: bounds.midX, y: chips.frameInWindow.maxY, width: 1, height: 1)
        let current: String? = if case .group(let name) = guide.filter { name } else { nil }
        var entries: [ContextMenuView.Entry] = [.action(.init(LiveTVCopy.allChannels, isChecked: current == nil) { [weak self] in self?.guide.filter = .all })]
        entries.append(.separator)
        for group in guide.groups() {
            entries.append(.action(.init(group.name, detail: String(group.count), isChecked: current == group.name) { [weak self] in
                self?.guide.filter = .group(group.name)
            }))
        }
        ContextMenuView(anchor: anchor) { entries }.present(in: window)
    }

    private func openPlaylists(adding: Bool) {
        let screen = LivePlaylistsScreen()
        rootView?.push(screen)
        if adding { screen.presentAdd() }
    }

    private func row(for channel: LiveChannel) -> GuideRow {
        GuideRow(id: channel.id, number: channel.number, title: channel.title, logo: channel.logo.map { .url($0) }, isFavorite: guide.isFavorite(channel.id),
                 cells: guide.programs[channel.id].map { $0.map(cell(for:)) })
    }

    private func cell(for program: LiveProgram) -> GuideCell {
        let detail = [program.episodeCode, program.episodeTitle].compactMap { $0 }.joined(separator: " · ")
        return GuideCell(id: program.id, title: program.title, detail: detail.isEmpty ? nil : detail, start: program.start, end: program.end,
                         isNew: program.isNew || program.isPremiere, isRecording: scheduledKeys.contains(Self.scheduleKey(program.title, program.start)))
    }

    private func programsArrived(_ ids: Set<String>) {
        grid.rows = grid.rows.map { row in
            guard ids.contains(row.id), let channel = guide.channel(id: row.id) else { return row }
            return self.row(for: channel)
        }
        if let focused = grid.focused, ids.contains(focused.row.id) { showPanel(row: focused.row, cell: focused.cell) }
    }

    private func showPanel(row: GuideRow, cell: GuideCell?) {
        guard let channel = guide.channel(id: row.id) else { return }
        let program = cell.flatMap { cell in guide.programs(of: row.id).first { $0.id == cell.id } } ?? guide.nowAndNext(row.id).now
        panel.show(channel: channel, program: program, next: program == nil ? nil : guide.programs(of: row.id).first { $0.start >= (program?.end ?? .distantFuture) })
    }

    // MARK: Actions

    private func activate(row: GuideRow, cell: GuideCell?) {
        guard let cell, cell.start > Date() else {
            play(row.id)
            return
        }
        presentMenu(row: row, cell: cell, at: nil)
    }

    func play(_ channelID: String) {
        guard let channel = guide.channel(id: channelID) else { return }
        guide.watched(channel.id)
        rootView?.playLive(channel, guide: guide)
    }

    private func presentMenu(row: GuideRow, cell: GuideCell?, at point: Point?) {
        guard let window, let channel = guide.channel(id: row.id) else { return }
        let program = cell.flatMap { cell in guide.programs(of: row.id).first { $0.id == cell.id } }
        var entries: [ContextMenuView.Entry] = []
        if let program { entries.append(.section(program.title)) }
        entries.append(.action(.init(LiveTVCopy.watch, detail: channel.numberedTitle, symbol: "play.fill") { [weak self] in self?.play(channel.id) }))
        if let program, program.end > Date(), program.record != nil, guide.source(of: channel)?.records == true {
            entries.append(.action(.init(LiveTVCopy.record, symbol: "record.circle") { [weak self] in self?.record(program, at: point) }))
        }
        let favorite = guide.isFavorite(channel.id)
        entries.append(.action(.init(favorite ? LiveTVCopy.removeFavorite : LiveTVCopy.addFavorite, symbol: favorite ? "star.slash" : "star") { [weak self] in
            self?.guide.toggleFavorite(channel.id)
        }))
        let menu = point.map { ContextMenuView(at: $0, highlightingFirstRow: false) { entries } }
            ?? ContextMenuView(anchor: grid.transformToWindow.apply(grid.bounds).insetBy(grid.bounds.width * 0.4, grid.bounds.height * 0.4)) { entries }
        menu.present(in: window)
    }

    /// Asks the server what it can record of `program`, then offers the choices (this airing, the series).
    private func record(_ program: LiveProgram, at point: Point?) {
        guard let hint = program.record else { return }
        let api = payload.api
        Task { [weak self] in
            do {
                let options = try await LiveRecordings.options(for: hint, api: api)
                guard let self, let window = self.window else { return }
                guard !options.isEmpty else {
                    AlertView.notice(title: LiveTVCopy.recordingFailed, message: nil, in: window)
                    return
                }
                let entries: [ContextMenuView.Entry] = [.section(LiveTVCopy.record)] + options.map { option in
                    .action(.init(option.isSeries ? LiveTVCopy.recordSeries : LiveTVCopy.recordEpisode,
                                  detail: option.librarySectionTitle.map(LiveTVCopy.savesTo), symbol: option.isSeries ? "rectangle.stack" : "record.circle") { [weak self] in
                        self?.schedule(option)
                    })
                }
                let anchor = point ?? Point(x: self.grid.frameInWindow.midX, y: self.grid.frameInWindow.midY)
                ContextMenuView(at: anchor) { entries }.present(in: window)
            } catch {
                guard let self, let window = self.window else { return }
                AlertView.notice(title: LiveTVCopy.recordingError(error), message: nil, in: window)
            }
        }
    }

    private func schedule(_ option: RecordingOption) {
        let api = payload.api
        Task { [weak self] in
            do {
                try await LiveRecordings.record(option, api: api)
                guard let self, let window = self.window else { return }
                AlertView.notice(title: LiveTVCopy.recordingScheduled, message: option.title, in: window)
            } catch {
                guard let self, let window = self.window else { return }
                AlertView.notice(title: LiveTVCopy.recordingError(error), message: nil, in: window)
            }
        }
    }

    private static func scheduleKey(_ title: String, _ start: Date?) -> String {
        "\(title.lowercased())|\(Int(start?.timeIntervalSince1970 ?? 0) / 60)"
    }

    private func loadScheduled() {
        guard guide.canRecord else { return }
        let api = payload.api
        scheduledTask?.cancel()
        scheduledTask = Task { [weak self] in
            guard let recordings = try? await LiveRecordings.scheduled(api: api), let self, !Task.isCancelled else { return }
            let keys = Set(recordings.filter { $0.status == .scheduled || $0.status == .recording }.map { Self.scheduleKey($0.title, $0.start) })
            guard keys != self.scheduledKeys else { return }
            self.scheduledKeys = keys
            self.grid.rows = self.guide.visibleChannels.map(self.row(for:))
        }
    }

    private func presentBetaNote() {
        guard let window else { return }
        LiveTVPreferences.hasSeenBetaNote = true
        header.tag.invites = false
        var actions = [AlertView.Action(LiveTVCopy.betaDismiss, role: .cancel)]
        if let mail = LiveTVCopy.feedbackURL { actions.insert(AlertView.Action(LiveTVCopy.betaFeedback) { Browser.open(mail) }, at: 0) }
        FeatureNoteView(tag: LiveTVCopy.beta, title: LiveTVCopy.betaTitle, intro: LiveTVCopy.betaIntro,
                        points: LiveTVCopy.betaPoints.map { FeatureNoteView.Point(symbol: Symbol($0.symbol), text: $0.text) },
                        footer: LiveTVCopy.betaFooter, actions: actions).present(in: window)
    }

    // MARK: Layout

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let margin = metrics.sideMargin
        var y = metrics.tabBarClearance
        let headerSize = header.sizeThatFits(Size(width: bounds.width - margin * 2, height: bounds.height))
        header.frame = Rect(x: margin, y: y, width: bounds.width - margin * 2, height: headerSize.height)
        y += headerSize.height + metrics.tv(12)
        let chipHeight = chips.sizeThatFits(Size(width: bounds.width - margin * 2, height: bounds.height)).height
        chips.frame = Rect(x: margin, y: y, width: bounds.width - margin * 2, height: chipHeight)
        y += chipHeight + metrics.tv(20)
        let panelHeight = panel.sizeThatFits(Size(width: bounds.width - margin * 2, height: bounds.height)).height
        panel.frame = Rect(x: margin, y: y, width: bounds.width - margin * 2, height: panelHeight)
        y += panelHeight + metrics.tv(20)
        grid.frame = Rect(x: margin, y: y, width: bounds.width - margin * 2, height: max(bounds.height - y - metrics.tv(24), 0))
        state.frame = Rect(x: 0, y: chips.frame.maxY, width: bounds.width, height: max(bounds.height - chips.frame.maxY, 0))
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

/// The screen's title with the Beta tag beside it.
@MainActor
final class LiveTVHeaderView: View {
    let tag = BetaTagView(title: LiveTVCopy.beta)

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        addSubview(tag)
    }

    override var accessibilityRole: AccessibilityRole { .heading }
    override var accessibilityLabel: String? { LiveTVCopy.title }

    private func titleLayout() -> TextLayout {
        TextLayout(LiveTVCopy.title, font: Theme.current.type.screenTitle, scale: window?.scale ?? 1)
    }

    override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: titleLayout().size.height)
    }

    override func layoutSubviews() {
        let title = titleLayout()
        let size = tag.sizeThatFits(bounds.size)
        tag.frame = Rect(x: title.size.width + Theme.current.metrics.tv(24), y: ((title.size.height - size.height) / 2).rounded(), width: size.width, height: size.height)
    }

    override func draw(_ context: inout DrawContext) {
        context.text(titleLayout(), at: .zero, color: Theme.current.palette.label)
    }
}

/// What the focused airing is: the channel above, the title, when it airs and how long is left, the episode and the
/// summary, and what follows.
@MainActor
final class LiveProgramPanel: View {
    private var channelText = ""
    private var titleText = ""
    private var metaText = ""
    private var summaryText = ""
    private var nextText = ""
    private var isLive = false

    func show(channel: LiveChannel, program: LiveProgram?, next: LiveProgram?) {
        let now = Date()
        channelText = channel.numberedTitle
        titleText = program?.title ?? LiveTVCopy.noGuide
        var meta: [String] = []
        if let program {
            meta.append(LiveGuideMath.timeRange(program))
            if program.isOn(at: now) { meta.append(LiveGuideMath.remaining(program, at: now)) }
            if let code = program.episodeCode { meta.append(code) }
            if let episode = program.episodeTitle { meta.append(episode) }
            if let rating = program.contentRating { meta.append(rating) }
        }
        metaText = meta.joined(separator: "  ·  ")
        summaryText = program?.summary ?? channel.summary ?? ""
        nextText = next.map { "\(LiveTVCopy.upNext): \($0.title)  \(LiveGuideMath.slotLabel($0.start))" } ?? ""
        isLive = program?.isOn(at: now) ?? false
        superview?.setNeedsLayout()
        setNeedsDisplay()
    }

    override var accessibilityRole: AccessibilityRole { .status }
    override var accessibilityLabel: String? { [channelText, titleText, metaText].filter { !$0.isEmpty }.joined(separator: ", ") }

    /// The panel is as tall as what it has to say, so a channel without listings leaves the guide more room; the
    /// height only grows while the screen is up, so the guide below does not jump as the focus moves.
    private var tallest: Float = 0

    override func sizeThatFits(_ size: Size) -> Size {
        let theme = Theme.current
        let metrics = theme.metrics
        let scale = window?.scale ?? 1
        let width = min(size.width, metrics.tv(1500))
        var height = TextLayout("Ag", font: theme.type.eyebrow, scale: scale).size.height + metrics.tv(8)
        height += TextLayout("Ag", font: theme.type.headline, scale: scale).size.height + metrics.tv(6)
        height += TextLayout("Ag", font: theme.type.cardSubtitle, scale: scale).size.height + metrics.tv(8)
        if !summaryText.isEmpty {
            height += TextLayout(summaryText, font: theme.type.body, maxWidth: width, maxLines: theme.density == .desk ? 2 : 1, scale: scale).size.height + metrics.tv(8)
        }
        if !nextText.isEmpty { height += TextLayout("Ag", font: theme.type.footnote, scale: scale).size.height }
        tallest = max(tallest, height)
        return Size(width: size.width, height: tallest)
    }

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let theme = Theme.current
        let palette = theme.palette
        let metrics = theme.metrics
        let width = min(bounds.width, metrics.tv(1500))
        var y: Float = 0
        var eyebrowX: Float = 0
        if isLive {
            let badge = TextLayout(LiveTVCopy.live, font: theme.type.badge, scale: scale)
            let rect = Rect(x: 0, y: 0, width: badge.size.width + metrics.tv(20), height: badge.size.height + metrics.tv(6))
            context.fill(rect, radius: metrics.radiusXS, color: palette.destructive)
            context.text(badge, at: Point(x: metrics.tv(10), y: metrics.tv(3)), color: .white)
            eyebrowX = rect.maxX + metrics.tv(14)
        }
        let eyebrow = TextLayout(channelText, font: theme.type.eyebrow, maxWidth: width - eyebrowX, scale: scale)
        context.text(eyebrow, at: Point(x: eyebrowX, y: 0), color: palette.accentText)
        y += eyebrow.size.height + metrics.tv(8)
        let title = TextLayout(titleText, font: theme.type.headline, maxWidth: width, scale: scale)
        context.text(title, at: Point(x: 0, y: y), color: palette.label)
        y += title.size.height + metrics.tv(6)
        if !metaText.isEmpty {
            let meta = TextLayout(metaText, font: theme.type.cardSubtitle, maxWidth: width, scale: scale)
            context.text(meta, at: Point(x: 0, y: y), color: palette.labelSecondary)
            y += meta.size.height + metrics.tv(8)
        }
        let room = bounds.height - y - (nextText.isEmpty ? 0 : metrics.tv(36))
        if !summaryText.isEmpty, room > metrics.tv(30) {
            let lines = max(Int(room / (theme.type.body.size * 1.35)), 1)
            let summary = TextLayout(summaryText, font: theme.type.body, maxWidth: width, maxLines: min(lines, theme.density == .desk ? 2 : 1), scale: scale)
            context.text(summary, at: Point(x: 0, y: y), color: palette.labelSecondary)
        }
        if !nextText.isEmpty {
            let next = TextLayout(nextText, font: theme.type.footnote, maxWidth: width, scale: scale)
            context.text(next, at: Point(x: 0, y: bounds.height - next.size.height), color: palette.labelTertiary)
        }
    }
}

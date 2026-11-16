import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// What one sitting carries from title to title (`TVPlayerCoordinator`'s run): the episodes that started with nobody at the
/// keyboard, whether the viewer did anything during this one, a timed sleep timer, and the audio and subtitle languages.
struct PlayerRun {
    var unattendedEpisodes = 0
    var viewerActedThisEpisode = true
    var sleepTimer: SleepTimer?
    var trackLanguages: TrackLanguages?
    /// The playlist being played, standing on the title on screen: what follows is its next entry, not the next episode.
    var queue: PlaybackQueue?
    /// Whether the window was out of full screen when the sitting's first title opened; nil until it opens.
    var beganWindowed: Bool?

    /// Whether the Up Next card asks "Still watching?" instead of counting down.
    var asksStillWatching: Bool {
        !viewerActedThisEpisode && StillWatchingRule.asks(unattended: unattendedEpisodes, limit: Preferences.stillWatchingAfter)
    }

    /// The run the next title starts with: one the viewer chose starts a new run, one that started on its own adds to the
    /// episodes nobody attended. A timer that stops at the end of an item ends with it; a timed one keeps counting.
    func advancing(byViewer: Bool, languages: TrackLanguages?, sleepTimer: SleepTimer?, queue: PlaybackQueue? = nil) -> PlayerRun {
        PlayerRun(unattendedEpisodes: byViewer ? 0 : (viewerActedThisEpisode ? 0 : unattendedEpisodes) + 1,
                  viewerActedThisEpisode: byViewer,
                  sleepTimer: sleepTimer.flatMap { $0.stopsAtEndOfItem ? nil : $0 },
                  trackLanguages: languages,
                  queue: queue,
                  beganWindowed: beganWindowed)
    }
}

/// The player's info panel (the tvOS player's info area): Info with the poster, the title, the episode or year line, the
/// synopsis, genres and rating; the chapters with their pictures; and Stream Info, how the title reaches the screen.
@MainActor
final class PlayerInfoPanel: View {
    enum Tab: String {
        case info, chapters, stream
    }

    struct Content {
        var title: String
        var subtitle: String?
        var summary: String?
        var facts: String?
        var posterPath: String?
        var chapters: [PlexChapter]
        var streamLines: [StreamInfoLine]
    }

    var onChapter: ((PlexChapter) -> Void)?
    var onClose: (() -> Void)?

    private let tabs = ChipRowView()
    private let poster = ArtworkView()
    private let chapters = ShelfView(header: nil, style: .landscape)
    private var content: Content
    private var tab = Tab.info
    private var tone = GlassTone()

    init(content: Content) {
        self.content = content
        super.init()
        poster.cornerRadius = Theme.current.metrics.radiusS
        poster.source = content.posterPath.map { .path($0, .poster) }
        tabs.onSelect = { [weak self] chip in self?.select(Tab(rawValue: chip.id) ?? .info) }
        chapters.onActivate = { [weak self] card in
            guard let self, let index = Int(card.id.dropFirst("chapter.".count)), self.content.chapters.indices.contains(index) else { return }
            self.onChapter?(self.content.chapters[index])
        }
        [tabs, poster, chapters].forEach(addSubview)
        update(content)
    }

    override var isFocusScope: Bool { true }
    override var preferredFocusView: View? { tabs }
    override var remembersFocus: Bool { true }
    override var overdraw: Float { Theme.current.metrics.tv(60) }

    func update(_ newContent: Content) {
        content = newContent
        poster.source = content.posterPath.map { .path($0, .poster) }
        var chips = [ChipRowView.Chip(id: Tab.info.rawValue, title: String(localized: "Info"), isSelected: tab == .info)]
        if !content.chapters.isEmpty {
            chips.append(.init(id: Tab.chapters.rawValue, title: ChapterList.title, isSelected: tab == .chapters))
        }
        if !content.streamLines.isEmpty {
            chips.append(.init(id: Tab.stream.rawValue, title: StreamInfo.title, isSelected: tab == .stream))
        }
        tabs.setChips(chips)
        chapters.setItems(content.chapters.enumerated().map { index, chapter in
            CardItem(id: "chapter.\(index)", artwork: chapter.thumb.map { .path($0, .backdrop) },
                     title: chapter.tag ?? String(localized: "Chapter \(index + 1)"), subtitle: TransportView.clock(chapter.startSecs),
                     placeholderSymbol: "film")
        })
        showTab()
    }

    private func select(_ next: Tab) {
        tab = next
        update(content)
    }

    private func showTab() {
        poster.isHidden = tab != .info
        chapters.isHidden = tab != .chapters
        setNeedsLayout()
        setNeedsDisplay()
    }

    override func keyPressed(_ event: KeyEvent) -> Bool {
        guard event.modifiers.isEmpty, event.key == .escape || event.key == .back || event.key == Key.character("i") else { return false }
        onClose?()
        return true
    }

    override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        return Size(width: size.width, height: metrics.tv(500))
    }

    private var inset: Float { Theme.current.metrics.tv(40) }

    fileprivate var streamArea: Rect { body }
    fileprivate var streamLines: [StreamInfoLine] { content.streamLines }

    private var body: Rect {
        let metrics = Theme.current.metrics
        let top = inset + metrics.chipHeight + metrics.tv(24)
        return Rect(x: inset, y: top, width: bounds.width - inset * 2, height: bounds.height - top - inset)
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        tabs.frame = Rect(x: inset - metrics.sideMargin, y: inset - metrics.tv(24), width: bounds.width - inset * 2 + metrics.sideMargin * 2,
                          height: metrics.chipHeight + metrics.tv(48))
        let area = body
        let posterHeight = area.height
        poster.frame = Rect(x: area.x, y: area.y, width: (posterHeight / 1.5).rounded(), height: posterHeight)
        chapters.frame = Rect(x: area.x - metrics.sideMargin, y: area.y - metrics.shelfTopInset, width: area.width + metrics.sideMargin * 2,
                              height: area.height + metrics.shelfTopInset)
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = tone.advance(dt)
        setNeedsDisplay()
        return moving
    }

    override func draw(_ context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        guard let scale = window?.scale else { return }
        if tone.update(context, rect: bounds) { startAnimating() }
        GlassStyle.capsule(in: bounds, radius: metrics.radiusL, light: Point(x: bounds.midX, y: bounds.minY - bounds.height), floating: true,
                           tone: tone.value, context: &context)
        let label = GlassStyle.label(tone: tone.value)
        let secondary = GlassStyle.secondaryLabel(tone: tone.value)
        if tab == .stream { drawStreamInfo(label: label, secondary: secondary, scale: scale, context: &context) }
        guard tab == .info else { return }
        let x = poster.frame.maxX + metrics.tv(40)
        let width = body.maxX - x
        var y = body.y
        let title = TextLayout(content.title, font: theme.type.title3, maxWidth: width, maxLines: 2, scale: scale)
        context.text(title, at: Point(x: x, y: y), color: label)
        y += title.size.height + metrics.tv(8)
        for (text, font, color, lines) in [(content.subtitle, theme.type.callout, secondary, 1), (content.facts, theme.type.callout, secondary, 1),
                                           (content.summary, theme.type.body, label, 6)] {
            guard let text, !text.isEmpty else { continue }
            let layout = TextLayout(text, font: font, maxWidth: width, maxLines: lines, scale: scale)
            guard y + layout.size.height <= body.maxY else { break }
            context.text(layout, at: Point(x: x, y: y), color: color)
            y += layout.size.height + metrics.tv(12)
        }
    }
}

extension PlayerInfoPanel {
    /// Stream Info (`TVStreamInfoViewController`): one label and value per line, in two columns when the lines would not fit
    /// in one.
    private func drawStreamInfo(label: Color, secondary: Color, scale: Float, context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        let area = streamArea
        let lines = streamLines
        guard !lines.isEmpty else { return }
        let rowHeight = metrics.tv(54)
        let rows = max(Int(area.height / rowHeight), 1)
        let columns = (lines.count + rows - 1) / rows
        let columnWidth = area.width / Float(max(columns, 1))
        let labelWidth = metrics.tv(290)
        for (index, line) in lines.enumerated() {
            let x = area.x + Float(index / rows) * columnWidth
            let y = area.y + Float(index % rows) * rowHeight
            let key = TextLayout(line.label, font: theme.type.callout, maxWidth: labelWidth - metrics.tv(16), scale: scale)
            let value = TextLayout(line.value, font: theme.type.callout, maxWidth: columnWidth - labelWidth - metrics.tv(24), scale: scale)
            context.text(key, at: Point(x: x, y: y), color: secondary)
            context.text(value, at: Point(x: x + labelWidth, y: y), color: label)
        }
    }
}

/// The pre-roll (`TVPlayerPrerollViewController`): before the first frame, a dark screen with the poster, the title, the
/// episode or year line and a spinner, faded in together; it dissolves into the picture once the stream shows one, or
/// after ten seconds, when the player's own buffering takes over.
@MainActor
final class PrerollView: View {
    static let revealTimeout: Duration = .seconds(10)
    private static let posterWait: Duration = .milliseconds(400)

    private let poster = ArtworkView()
    private let spinner = SpinnerView()
    private let title: String
    private let subtitle: String?
    private var shown = Animated(0)
    private var revealed = false
    private var fadeTask: Task<Void, Never>?

    init(title: String, subtitle: String?, posterPath: String?) {
        self.title = title
        self.subtitle = subtitle
        super.init()
        poster.cornerRadius = Theme.current.metrics.radiusM
        poster.source = posterPath.map { .path($0, .poster) }
        poster.isHidden = posterPath == nil
        [poster, spinner].forEach(addSubview)
        alpha = 0
    }

    override var isPointerInteractive: Bool { false }

    override func didMoveToWindow() {
        guard window != nil, fadeTask == nil else { return }
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.posterWait)
            guard let self, !self.revealed else { return }
            self.shown.set(1, animation: .timed(duration: 0.3, curve: .easeInOut))
            self.startAnimating()
        }
    }

    /// Dissolves into the picture underneath and leaves.
    func reveal() {
        guard !revealed else { return }
        revealed = true
        fadeTask?.cancel()
        shown.set(0, animation: .timed(duration: 0.45, curve: .easeInOut))
        startAnimating()
    }

    var isRevealed: Bool { revealed }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = shown.advance(dt)
        alpha = revealed ? shown.value : 1
        setNeedsDisplay()
        if revealed, !moving { removeFromSuperview() }
        return moving
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let height = metrics.tv(360)
        let width = (height / 1.5).rounded()
        poster.frame = Rect(x: ((bounds.width - width) / 2).rounded(), y: (bounds.height * 0.5 - height - metrics.tv(30)).rounded(), width: width,
                            height: height)
        let side = metrics.tv(64)
        spinner.frame = Rect(x: ((bounds.width - side) / 2).rounded(), y: (bounds.height * 0.5 + metrics.tv(150)).rounded(), width: side, height: side)
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Color.shade(1))
        guard let scale = window?.scale else { return }
        let theme = Theme.current
        let metrics = theme.metrics
        let fade = revealed ? 1 : shown.value
        context.faded(fade) { inner in
            var y = (bounds.height * 0.5).rounded()
            let titleLayout = TextLayout(title, font: theme.type.title2, maxWidth: bounds.width - metrics.sideMargin * 2, maxLines: 2, alignment: .center,
                                         scale: scale)
            inner.text(titleLayout, at: Point(x: ((bounds.width - titleLayout.size.width) / 2).rounded(), y: y), color: theme.palette.onArt)
            y += titleLayout.size.height + metrics.tv(8)
            if let subtitle {
                let line = TextLayout(subtitle, font: theme.type.callout, maxWidth: bounds.width - metrics.sideMargin * 2, scale: scale)
                inner.text(line, at: Point(x: ((bounds.width - line.size.width) / 2).rounded(), y: y), color: theme.palette.onArtSecondary)
            }
        }
        poster.alpha = fade
        spinner.alpha = fade
    }
}

/// What's next once nothing plays next (`TVPostPlayViewController`): titles like the one that ended over its last frame,
/// with Close. Selecting a movie plays it in the same player; a show opens its page. Nothing plays on its own.
@MainActor
final class PostPlayView: View {
    var onPick: ((PlexMetadata) -> Void)?
    var onClose: (() -> Void)?

    private let heading: String
    private let shelf = ShelfView(header: nil, style: .poster)
    private let close = ButtonView(style: .glass, title: PostPlay.closeTitle, symbol: "xmark")
    private var items: [String: PlexMetadata] = [:]
    private var shown = Animated(0)
    private var answered = false

    init(heading: String, items suggestions: [PlexMetadata]) {
        self.heading = heading
        super.init()
        items = Dictionary(suggestions.map { ($0.entryID, $0) }, uniquingKeysWith: { first, _ in first })
        shelf.setItems(suggestions.map { item in
            var card = TitleCards.card(item)
            card.id = item.entryID
            return card
        })
        shelf.onActivate = { [weak self] card in
            guard let self, !self.answered, let item = self.items[card.id] else { return }
            self.answered = true
            self.onPick?(item)
        }
        close.onPress = { [weak self] in self?.leave() }
        [shelf, close].forEach(addSubview)
        shown.set(1, animation: .timed(duration: 0.4, curve: .easeInOut))
    }

    override var isFocusScope: Bool { true }
    override var preferredFocusView: View? { shelf }
    override var remembersFocus: Bool { true }

    override func didMoveToWindow() { startAnimating() }

    private func leave() {
        guard !answered else { return }
        answered = true
        onClose?()
    }

    override func keyPressed(_ event: KeyEvent) -> Bool {
        guard event.modifiers.isEmpty, event.key == .escape || event.key == .back else { return false }
        leave()
        return true
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = shown.advance(dt)
        alpha = shown.value
        setNeedsDisplay()
        return moving
    }

    private var headingTop: Float { (bounds.height * 0.2).rounded() }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let shelfTop = headingTop + metrics.tv(120)
        shelf.frame = Rect(x: 0, y: shelfTop, width: bounds.width, height: shelf.preferredHeight)
        let size = close.sizeThatFits(Size(width: 600, height: 200))
        close.frame = Rect(x: metrics.sideMargin, y: shelf.frame.maxY + metrics.tv(24), width: size.width, height: size.height)
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Color.shade(0.78))
        guard let scale = window?.scale else { return }
        let theme = Theme.current
        let metrics = theme.metrics
        let title = TextLayout(heading, font: theme.type.title2, maxWidth: bounds.width - metrics.sideMargin * 2, maxLines: 2, scale: scale)
        context.text(title, at: Point(x: metrics.sideMargin, y: headingTop), color: theme.palette.onArt)
    }
}

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
    /// How many titles of the sitting played before this one (0 for the one the viewer started), for After the First Episode.
    var titlesBefore = 0

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
                  beganWindowed: beganWindowed,
                  titlesBefore: titlesBefore + 1)
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
        /// The artwork is a sixteen by nine picture (a web video's thumbnail), not a poster.
        var posterIsLandscape = false
        var chapters: [PlexChapter]
        var streamLines: [StreamInfoLine]
        /// What the player does with the picture and sound now (`PlayerScreen.livePlaybackLines`), how the title reaches
        /// it now (`liveDeliveryLines`), and the last minute's bitrate samples.
        var liveLines: [StreamInfoLine] = []
        var deliveryLines: [StreamInfoLine] = []
        var bitrates: [Double] = []
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
        poster.source = content.posterPath.map(WebArtwork.poster)
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
        poster.source = content.posterPath.map(WebArtwork.poster)
        var chips = [ChipRowView.Chip(id: Tab.info.rawValue, title: String(localized: "Info"), isSelected: tab == .info)]
        if !content.chapters.isEmpty {
            chips.append(.init(id: Tab.chapters.rawValue, title: ChapterList.title, isSelected: tab == .chapters))
        }
        if !content.streamLines.isEmpty || !content.liveLines.isEmpty || !content.deliveryLines.isEmpty {
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
        superview?.setNeedsLayout()
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

    /// On Stream Info, tall enough for its longest column (at least the live columns' seven rows, so the panel keeps
    /// its height as live lines come and go), but never taller than the room `size` offers.
    override func sizeThatFits(_ size: Size) -> Size {
        let theme = Theme.current
        let metrics = theme.metrics
        var wanted = metrics.tv(500)
        if tab == .stream {
            let heading = TextLayout("A", font: theme.type.caption2, maxLines: 1, scale: window?.scale ?? 1).size.height + metrics.tv(14)
            let rows = Float(max(content.streamLines.count, Self.liveRows))
            wanted = max(wanted, body.y + heading + rows * Self.rowHeight + inset + metrics.tv(8))
        }
        return Size(width: size.width, height: size.height > 0 ? min(wanted, max(size.height, metrics.tv(360))) : wanted)
    }

    /// Stream Info's line pitch, and the rows its live columns take: six playback lines, or the bitrate graph and four
    /// delivery lines.
    fileprivate static var rowHeight: Float { Theme.current.metrics.tv(46) }
    fileprivate static let liveRows = 7
    fileprivate static var graphHeight: Float { rowHeight * 3 - Theme.current.metrics.tv(20) }

    private var inset: Float { Theme.current.metrics.tv(40) }

    fileprivate var streamArea: Rect { body }
    fileprivate var streamLines: [StreamInfoLine] { content.streamLines }
    fileprivate var liveLines: [StreamInfoLine] { content.liveLines }
    fileprivate var deliveryLines: [StreamInfoLine] { content.deliveryLines }
    fileprivate var bitrates: [Double] { content.bitrates }

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
        if content.posterIsLandscape {
            let width = min((area.height * 16 / 9).rounded(), (area.width * 0.34).rounded())
            poster.frame = Rect(x: area.x, y: area.y, width: width, height: (width * 9 / 16).rounded())
        } else {
            poster.frame = Rect(x: area.x, y: area.y, width: (area.height / 1.5).rounded(), height: area.height)
        }
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
    private struct Block {
        let heading: String
        let lines: [StreamInfoLine]
        var graphed = false
    }

    /// Stream Info (`TVStreamInfoViewController`) in up to three columns: the title as the server sends it, what the
    /// player does with the picture and sound now, and how the title reaches it now under the last minute's bitrate. The
    /// live columns refresh every second. Each column is as wide as its widest line wants, sharing out what is left over;
    /// in a panel too narrow for that the lines take a smaller size, and the columns give up the same share each when even
    /// those do not fit. A column whose lines would not fit in its height splits into more.
    private func drawStreamInfo(label: Color, secondary: Color, scale: Float, context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        let area = streamArea
        let blocks = [
            Block(heading: String(localized: "This Title", comment: "Stream Info heading: how the server sends the title"), lines: streamLines),
            Block(heading: String(localized: "Player", comment: "Stream Info heading: what the player does with the picture and sound now"),
                  lines: liveLines),
            Block(heading: String(localized: "Streaming", comment: "Stream Info heading: how the title reaches the player now"), lines: deliveryLines,
                  graphed: bitrates.count > 1),
        ].filter { !$0.lines.isEmpty || $0.graphed }
        guard !blocks.isEmpty else { return }
        let labelGap = metrics.tv(24)
        let gap = metrics.tv(56)
        let room = area.width - gap * Float(blocks.count - 1)
        func measure(_ font: Font) -> [(label: Float, value: Float)] {
            blocks.map { block in
                block.lines.reduce((label: Float(0), value: Float(0))) { widest, line in
                    (max(widest.label, TextLayout(line.label, font: font, maxLines: 1, scale: scale).size.width),
                     max(widest.value, TextLayout(line.value, font: font, maxLines: 1, scale: scale).size.width))
                }
            }
        }
        func wanted(_ sizes: [(label: Float, value: Float)]) -> [Float] {
            zip(blocks, sizes).map { block, size in max(size.label + labelGap + size.value, block.graphed ? metrics.tv(420) : 0) }
        }
        var font = theme.type.callout
        var measured = measure(font)
        var wants = wanted(measured)
        if wants.reduce(0, +) > room {
            font = theme.type.footnote
            measured = measure(font)
            wants = wanted(measured)
        }
        let total = wants.reduce(0, +)
        var x = area.x
        for (index, block) in blocks.enumerated() {
            let width = total <= room ? wants[index] + (room - total) * wants[index] / total : wants[index] * room / total
            let rect = Rect(x: x, y: area.y, width: width, height: area.height)
            let graphHeight = block.graphed ? Self.graphHeight : 0
            let band = drawLineBlock(block.heading, block.lines, in: rect, font: font, labelWidth: measured[index].label + labelGap,
                                     reserving: graphHeight > 0 ? graphHeight + metrics.tv(20) : 0, label: label, secondary: secondary,
                                     scale: scale, context: &context)
            if block.graphed { drawBitrateGraph(in: Rect(x: rect.x, y: band, width: rect.width, height: graphHeight), scale: scale, context: &context) }
            x = rect.maxX + gap
        }
    }

    /// A heading over label and value lines in `font`, in as few balanced columns as fit, values starting `labelWidth` in
    /// (at most 45% of a column), leaving `reserved` points free under the heading; returns the top of that free band.
    @discardableResult
    private func drawLineBlock(_ heading: String, _ lines: [StreamInfoLine], in area: Rect, font: Font, labelWidth wanted: Float,
                               reserving reserved: Float = 0, label: Color, secondary: Color, scale: Float, context: inout DrawContext) -> Float {
        let theme = Theme.current
        let metrics = theme.metrics
        let title = TextLayout(heading.uppercased(), font: theme.type.caption2, maxWidth: area.width, maxLines: 1, scale: scale)
        context.text(title, at: Point(x: area.x, y: area.y), color: secondary)
        let band = area.y + title.size.height + metrics.tv(14)
        guard !lines.isEmpty else { return band }
        let top = band + reserved
        let rowHeight = Self.rowHeight
        let fit = max(Int((area.maxY - top) / rowHeight), 1)
        let columns = (lines.count + fit - 1) / fit
        let rows = (lines.count + columns - 1) / columns
        let columnGap = metrics.tv(32)
        let columnWidth = (area.width - columnGap * Float(columns - 1)) / Float(columns)
        let labelWidth = min(wanted, columnWidth * 0.45)
        for (index, line) in lines.enumerated() {
            let x = area.x + Float(index / rows) * (columnWidth + columnGap)
            let y = top + Float(index % rows) * rowHeight
            let key = TextLayout(line.label, font: font, maxWidth: labelWidth - metrics.tv(12), maxLines: 1, scale: scale)
            let value = TextLayout(line.value, font: font, maxWidth: columnWidth - labelWidth, maxLines: 1, scale: scale)
            context.text(key, at: Point(x: x, y: y), color: secondary)
            context.text(value, at: Point(x: x + labelWidth, y: y), color: label)
        }
        return band
    }

    /// The last minute's bitrate as bars on a faint track under a "Last minute" caption, the newest in the accent at the
    /// right, scaled to the minute's peak.
    private func drawBitrateGraph(in rect: Rect, scale: Float, context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        let samples = bitrates
        guard rect.width > 0, samples.count > 1, let peak = samples.max(), peak > 0 else { return }
        context.fill(rect, radius: metrics.tv(10), color: Color.black.withSRGBAlpha(0.24))
        let inner = rect.insetBy(metrics.tv(12), metrics.tv(10))
        let caption = TextLayout(String(localized: "Last minute", comment: "Stream Info: over the bitrate graph of the last sixty seconds"),
                                 font: theme.type.caption2, maxLines: 1, scale: scale)
        context.text(caption, at: Point(x: inner.x, y: inner.y), color: Color.white.withSRGBAlpha(0.55))
        let captionHeight = caption.size.height + metrics.tv(6)
        let plot = Rect(x: inner.x, y: inner.y + captionHeight, width: inner.width, height: max(inner.height - captionHeight, metrics.tv(8)))
        let slot = plot.width / 60
        for (index, sample) in samples.enumerated() {
            let height = max(metrics.tv(2), plot.height * Float(sample / peak))
            let x = plot.maxX - Float(samples.count - index) * slot
            context.fill(Rect(x: x, y: plot.maxY - height, width: max(slot * 0.7, 1), height: height),
                         radius: min(slot * 0.35, metrics.tv(3)),
                         color: index == samples.count - 1 ? theme.palette.accent : Color.white.withSRGBAlpha(0.4))
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
    private var title: String
    private var subtitle: String?
    private var shown = Animated(0)
    private var revealed = false
    private var fadeTask: Task<Void, Never>?
    private let isLandscape: Bool

    /// `isLandscape` shows the artwork as a sixteen by nine picture (a web video's thumbnail) in place of a poster.
    init(title: String, subtitle: String?, posterPath: String?, isLandscape: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.isLandscape = isLandscape
        super.init()
        poster.cornerRadius = Theme.current.metrics.radiusM
        poster.source = posterPath.map(WebArtwork.poster)
        poster.isHidden = posterPath == nil
        [poster, spinner].forEach(addSubview)
        alpha = 0
    }

    override var isPointerInteractive: Bool { false }

    /// Shows a title and a line under it that were learned after the pre-roll came up (a link's video, once it was read).
    func update(title: String, subtitle: String?, posterPath: String?) {
        self.title = title
        self.subtitle = subtitle
        if let posterPath {
            poster.source = WebArtwork.poster(posterPath)
            poster.isHidden = false
        }
        setNeedsDisplay()
    }

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
        let height = isLandscape ? metrics.tv(300) : metrics.tv(360)
        let width = isLandscape ? (height * 16 / 9).rounded() : (height / 1.5).rounded()
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

/// What a key or menu choice just did, briefly at the top of the picture ("Audio sync +0.1 s", "Speed 1.25×"), on a small
/// glass capsule that fades out after a moment; a newer message replaces it in place.
@MainActor
final class PlayerToast: View {
    private var message = ""
    private var symbol: Symbol?
    private var shown = Animated(0)
    private var tone = GlassTone()
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, symbol: Symbol?) {
        self.message = message
        self.symbol = symbol
        shown.set(1, animation: .timed(duration: 0.15, curve: .easeOut))
        startAnimating()
        setNeedsDisplay()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, !Task.isCancelled else { return }
            self.shown.set(0, animation: .timed(duration: 0.4, curve: .easeInOut))
            self.startAnimating()
        }
    }

    override var accessibilityLabel: String? { message }

    func preferredSize(scale: Float) -> Size {
        let metrics = Theme.current.metrics
        let text = TextLayout(message, font: Theme.current.type.callout, maxLines: 1, scale: scale).size
        let icon: Float = symbol == nil ? 0 : metrics.tv(44)
        return Size(width: (text.width + icon + metrics.tv(64)).rounded(.up), height: metrics.tv(72))
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [shown.advance(dt), tone.advance(dt)].contains(true)
        setNeedsDisplay()
        return moving
    }

    override func draw(_ context: inout DrawContext) {
        guard shown.value > 0.01, let scale = window?.scale else { return }
        let metrics = Theme.current.metrics
        let size = preferredSize(scale: scale)
        let pill = Rect(x: ((bounds.width - size.width) / 2).rounded(), y: 0, width: size.width, height: size.height)
        if tone.update(context, rect: pill) { startAnimating() }
        context.faded(shown.value) { faded in
            GlassStyle.capsule(in: pill, radius: pill.height / 2, light: Point(x: pill.midX, y: -pill.height), floating: true, tone: tone.value, context: &faded)
            let color = GlassStyle.label(tone: tone.value)
            var x = pill.x + metrics.tv(32)
            if let symbol {
                let side = metrics.tv(30)
                faded.symbol(symbol, in: Rect(x: x, y: pill.midY - side / 2, width: side, height: side), color: color)
                x += metrics.tv(44)
            }
            let text = TextLayout(message, font: Theme.current.type.callout, maxLines: 1, scale: scale)
            faded.text(text, at: Point(x: x, y: ((pill.midY - text.size.height / 2) * scale).rounded() / scale), color: color)
        }
    }
}

/// The preview still for where a seek is going, filling the picture until the seek lands: the screen answers a scrub at
/// once even when the picture comes from a slow disk. It fades away as the picture arrives, or after a few seconds should
/// it never say.
@MainActor
final class StillVeil: View {
    private var texture: Texture?
    private var shown = Animated(0)
    private var giveUp: Task<Void, Never>?

    func show(_ still: Texture) {
        texture = still
        shown.set(1, animation: .timed(duration: 0.08, curve: .easeOut))
        startAnimating()
        setNeedsDisplay()
        giveUp?.cancel()
        giveUp = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.lift()
        }
    }

    func lift() {
        guard shown.target > 0 else { return }
        giveUp?.cancel()
        shown.set(0, animation: .timed(duration: 0.25, curve: .easeInOut))
        startAnimating()
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = shown.advance(dt)
        setNeedsDisplay()
        return moving
    }

    override func draw(_ context: inout DrawContext) {
        guard let texture, shown.value > 0.01 else { return }
        context.faded(shown.value) { faded in
            faded.fill(bounds, color: .black)
            faded.image(texture, in: bounds, fit: true)
        }
    }
}

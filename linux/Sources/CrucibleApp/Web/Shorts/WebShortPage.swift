import CrucibleCore
import CrucibleUI
import CrucibleWeb
import Foundation
import Kiln

/// One clip of the Shorts feed as a page: its upright thumbnail until its first frame is drawn, then the clip, with its
/// channel, Follow, title and facts over the bottom, the playhead along the lower edge, a mark as it pauses and plays,
/// and what went wrong when it cannot play. The pages either side of the one playing are drawn smaller and darker.
@MainActor
final class WebShortPage: View {
    struct Content: Equatable {
        var title = ""
        var channel: String?
        var facts: String?
        var poster: ArtworkSource?
        var avatar: ArtworkSource?
        var canFollow = false
        var isFollowed = false
    }

    let index: Int
    var content = Content() {
        didSet {
            guard content != oldValue else { return }
            poster.source = content.poster
            avatar.source = content.avatar
            avatar.isHidden = content.avatar == nil
            follow.isHidden = !content.canFollow
            follow.style = .chip(selected: !content.isFollowed)
            follow.title = content.isFollowed ? WebShortsCopy.followed : WebShortsCopy.follow
            follow.symbol = content.isFollowed ? "checkmark" : "plus"
            setNeedsLayout()
            setNeedsDisplay()
        }
    }
    /// The player holding this clip, while one does.
    weak var slot: WebShortSlot? { didSet { if slot !== oldValue { refresh() } } }
    /// How far the page is from the one playing, in pages.
    var distance: Float = 0 {
        didSet {
            guard distance != oldValue else { return }
            scale = 1 - 0.05 * min(distance, 1)
            chrome.alpha = 1 - min(distance * 1.6, 1)
            setNeedsDisplay()
        }
    }
    /// Room kept clear down the page's trailing side, where the action rail lies over a narrow window's clip.
    var trailingInset: Float = 0 { didSet { if trailingInset != oldValue { setNeedsLayout() } } }
    /// Whether the viewer paused this clip, which leaves a play mark over it.
    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            rest.set(isPaused ? 1 : 0, animation: .fade)
            startAnimating()
        }
    }
    /// Where a drag along the playhead points, from 0 to 1, while one is under way.
    var scrubbing: Double? { didSet { if scrubbing != oldValue { setNeedsDisplay() } } }
    /// Whether the playhead is drawn thick with its times: under the pointer, while dragged and while paused.
    var emphasizesBar = false {
        didSet {
            guard emphasizesBar != oldValue else { return }
            emphasis.set(emphasizesBar ? 1 : 0, animation: .focus)
            startAnimating()
        }
    }
    var onFollow: (() -> Void)?
    var onRetry: (() -> Void)?

    private let poster = ArtworkView()
    private let picture = Canvas()
    private let chrome = Canvas()
    private let avatar = ArtworkView()
    private let follow = ButtonView(style: .chip(selected: true), title: WebShortsCopy.follow, symbol: "plus")
    private let spinner = SpinnerView()
    private let retry = ButtonView(style: .glass, title: WebShortsCopy.retry, symbol: "arrow.clockwise")
    private var reveal = Animated(0)
    private var rest = Animated(0)
    private var emphasis = Animated(0)
    private var burst = Animated(1)
    private var burstSymbol: Symbol = "play.fill"

    init(index: Int) {
        self.index = index
        super.init()
        poster.fillsUntilLoaded = true
        avatar.isHidden = true
        follow.isHidden = true
        retry.isHidden = true
        spinner.isHidden = true
        follow.onPress = { [weak self] in self?.onFollow?() }
        retry.onPress = { [weak self] in self?.onRetry?() }
        picture.render = { [weak self] context in self?.drawPicture(&context) }
        chrome.render = { [weak self] context in self?.drawChrome(&context) }
        chrome.addSubview(avatar)
        chrome.addSubview(follow)
        [poster, picture, chrome, spinner, retry].forEach(addSubview)
    }

    override var accessibilityLabel: String? { [content.title, content.channel].compactMap { $0 }.joined(separator: ", ") }
    override var overdraw: Float { Theme.current.metrics.tv(60) }

    /// The Follow button, for the keyboard to reach.
    var followButton: View? { follow.isHidden ? nil : follow }
    var retryButton: View? { retry.isHidden ? nil : retry }

    private var holdsClip: Bool { slot?.index == index }

    /// Shows what the slot says now: the spinner while the clip is on its way, what went wrong when it failed.
    func refresh() {
        let phase = holdsClip ? slot?.phase : nil
        var failed = false
        if case .failed = phase { failed = true }
        let buffering = phase == .open && slot?.player.state.isBuffering == true && slot?.hasPicture == true
        spinner.isHidden = !(phase == .resolving || phase == .opening || buffering)
        retry.isHidden = !failed
        if !holdsClip || slot?.hasPicture != true { reveal.reset(0) }
        setNeedsLayout()
        setNeedsDisplay()
    }

    /// Flashes `symbol` over the clip, as it pauses or plays.
    func flash(_ symbol: Symbol) {
        burstSymbol = symbol
        burst.reset(0)
        burst.set(1, animation: .timed(duration: 0.5, curve: .easeOut))
        startAnimating()
    }

    private var radius: Float { Theme.current.metrics.radiusL }
    private var inset: Float { Theme.current.metrics.tv(30) }
    private var avatarDiameter: Float { Theme.current.metrics.tv(64) }

    /// Where the playhead's bar lies, which the stage hit-tests for a drag along it.
    var barRect: Rect {
        let metrics = Theme.current.metrics
        return Rect(x: inset, y: bounds.height - metrics.tv(30), width: max(bounds.width - inset * 2, 1), height: metrics.tv(8))
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        poster.frame = bounds
        poster.cornerRadius = radius
        picture.frame = bounds
        chrome.frame = bounds
        let side = metrics.tv(72)
        spinner.frame = Rect(x: (bounds.midX - side / 2).rounded(), y: (bounds.midY - side / 2).rounded(), width: side, height: side)
        let retrySize = retry.sizeThatFits(Size(width: bounds.width, height: metrics.primaryControlHeight))
        retry.frame = Rect(x: (bounds.midX - retrySize.width / 2).rounded(), y: (bounds.height * 0.62).rounded(), width: retrySize.width, height: retrySize.height)
        let row = channelRow
        avatar.frame = Rect(x: inset, y: row.y, width: avatarDiameter, height: avatarDiameter)
        avatar.cornerRadius = avatarDiameter / 2
        let followSize = follow.sizeThatFits(Size(width: bounds.width, height: metrics.chipHeight))
        let nameWidth = channelLayout(maxWidth: row.width - followSize.width - metrics.tv(20))?.size.width ?? 0
        follow.frame = Rect(x: row.x + nameWidth + metrics.tv(20), y: (row.midY - followSize.height / 2).rounded(), width: followSize.width, height: followSize.height)
    }

    private var scaleFactor: Float { window?.scale ?? 1 }
    private var textWidth: Float { max(bounds.width - inset * 2 - trailingInset, 1) }

    private func titleLayout() -> TextLayout? {
        guard !content.title.isEmpty else { return nil }
        return TextLayout(content.title, font: Theme.current.type.cardTitle, maxWidth: textWidth, maxLines: 2, scale: scaleFactor)
    }

    private func factsLayout() -> TextLayout? {
        guard let facts = content.facts, !facts.isEmpty else { return nil }
        return TextLayout(facts, font: Theme.current.type.footnote, maxWidth: textWidth, maxLines: 1, scale: scaleFactor)
    }

    private func channelLayout(maxWidth: Float) -> TextLayout? {
        guard let channel = content.channel, !channel.isEmpty else { return nil }
        return TextLayout(channel, font: Theme.current.type.control, maxWidth: max(maxWidth, 1), maxLines: 1, scale: scaleFactor)
    }

    /// Where the channel's name sits beside its picture: above the title and the facts, which stand on the playhead.
    private var channelRow: Rect {
        let metrics = Theme.current.metrics
        var y = barRect.minY - metrics.tv(22)
        if let facts = factsLayout() { y -= facts.size.height + metrics.tv(8) }
        if let title = titleLayout() { y -= title.size.height + metrics.tv(14) }
        let x = inset + avatarDiameter + metrics.tv(18)
        return Rect(x: x, y: y - avatarDiameter, width: max(bounds.width - x - inset - trailingInset, 1), height: avatarDiameter)
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [reveal.advance(dt), rest.advance(dt), emphasis.advance(dt), burst.advance(dt)].contains(true)
        setNeedsDisplay()
        return moving
    }

    /// The clip over its thumbnail, fading in with its first frame; a wide clip lies across the dimmed thumbnail.
    private func drawPicture(_ context: inout DrawContext) {
        guard let window, let slot, holdsClip, let rect = slot.pictureRect(in: bounds) else { return }
        let fills = rect == bounds
        if !fills, reveal.value > 0 { context.fill(bounds, radius: radius, color: Color.shade(0.78 * reveal.value)) }
        let drew = slot.draw(in: rect, radius: fills ? radius : 0, opacity: reveal.value, context: &context, window: window)
        if drew, reveal.target == 0 {
            reveal.set(1, animation: .timed(duration: 0.16, curve: .easeOut))
            startAnimating()
            spinner.isHidden = true
        }
    }

    private func drawChrome(_ context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        let palette = theme.palette
        context.gradient(bounds, vertical: true, stops: [(0, Color.shade(0)), (0.5, Color.shade(0)), (0.8, Color.shade(0.55)), (1, Color.shade(0.9))],
                         radius: radius)
        let bar = barRect
        var y = bar.minY - metrics.tv(22)
        if let facts = factsLayout() {
            y -= facts.size.height
            context.text(facts, at: Point(x: inset, y: y), color: palette.onArtSecondary)
            y -= metrics.tv(8)
        }
        if let title = titleLayout() {
            y -= title.size.height
            context.text(title, at: Point(x: inset, y: y), color: palette.onArt)
        }
        let row = channelRow
        if content.avatar == nil, let channel = content.channel, !channel.isEmpty { drawMonogram(for: channel, in: avatar.frame, context: &context) }
        let followWidth = follow.isHidden ? 0 : follow.frame.width + metrics.tv(20)
        if let name = channelLayout(maxWidth: row.width - followWidth) {
            context.text(name, at: Point(x: row.x, y: ((row.midY - name.size.height / 2) * scaleFactor).rounded() / scaleFactor), color: palette.onArt)
        }
        drawBar(in: bar, context: &context)
        if !spinner.isHidden {
            let disc = spinner.frame.insetBy(-metrics.tv(18), -metrics.tv(18))
            context.fill(disc, radius: disc.height / 2, color: Color.shade(0.5))
        }
        drawMarks(&context)
        if holdsClip, case .failed(let message) = slot?.phase { drawFailure(message, context: &context) }
    }

    /// A channel without a picture gets its initials on its own two colours, as a followed channel's card does.
    private func drawMonogram(for channel: String, in rect: Rect, context: inout DrawContext) {
        let gradient = CastAvatar.gradient(for: channel)
        context.gradient(rect, vertical: true, stops: [(0, Color(hex: gradient.start)), (1, Color(hex: gradient.end))], radius: rect.height / 2)
        let initials = TextLayout(DetailFormat.initials(channel), font: Theme.current.type.caption1, maxLines: 1, scale: scaleFactor)
        context.text(initials, at: Point(x: ((rect.midX - initials.size.width / 2) * scaleFactor).rounded() / scaleFactor,
                                         y: ((rect.midY - initials.size.height / 2) * scaleFactor).rounded() / scaleFactor), color: .white)
    }

    private func drawBar(in bar: Rect, context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        let state = holdsClip ? slot?.player.state : nil
        let duration = state?.duration ?? 0
        let fraction = scrubbing ?? (duration > 0 ? min(max((state?.position ?? 0) / duration, 0), 1) : 0)
        let grown = emphasis.value
        let thickness = metrics.tv(5) + metrics.tv(6) * grown
        let track = Rect(x: bar.x, y: bar.midY - thickness / 2, width: bar.width, height: thickness)
        context.fill(track, radius: thickness / 2, color: Color.white.withSRGBAlpha(0.3))
        let filled = Rect(x: track.x, y: track.y, width: max(track.width * Float(fraction), thickness), height: thickness)
        context.fill(filled, radius: thickness / 2, color: theme.palette.accent)
        guard grown > 0.01, duration > 0 else { return }
        let knob = metrics.tv(22) * grown
        context.fill(Rect(x: filled.maxX - knob / 2, y: track.midY - knob / 2, width: knob, height: knob), radius: knob / 2, color: .white)
        let clock = "\(TransportView.clock(fraction * duration)) / \(TransportView.clock(duration))"
        var font = theme.type.footnote
        font.monospacedDigits = true
        let text = TextLayout(clock, font: font, maxLines: 1, scale: scaleFactor)
        context.faded(grown) { faded in
            faded.text(text, at: Point(x: bar.maxX - text.size.width - trailingInset, y: bar.minY - metrics.tv(22) - text.size.height),
                       color: theme.palette.onArt)
        }
    }

    /// The play mark resting over a paused clip, and the mark that flashes as the clip pauses or plays.
    private func drawMarks(_ context: inout DrawContext) {
        let metrics = Theme.current.metrics
        let side = metrics.tv(132)
        let circle = Rect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        func mark(_ symbol: Symbol, opacity: Float, size: Float, context: inout DrawContext) {
            context.faded(opacity) { faded in
                faded.transformed(scale: size, about: circle.center) { drawn in
                    drawn.fill(circle, radius: side / 2, color: Color.shade(0.5))
                    let glyph = side * 0.42
                    drawn.symbol(symbol, in: Rect(x: circle.midX - glyph / 2, y: circle.midY - glyph / 2, width: glyph, height: glyph), color: .white)
                }
            }
        }
        if burst.value < 1 {
            mark(burstSymbol, opacity: 1 - burst.value, size: 0.82 + 0.5 * burst.value, context: &context)
        } else if rest.value > 0.01 {
            mark("play.fill", opacity: rest.value, size: 0.9 + 0.1 * rest.value, context: &context)
        }
    }

    private func drawFailure(_ message: String, context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        context.fill(bounds, radius: radius, color: Color.shade(0.7))
        let side = metrics.tv(72)
        let text = TextLayout(message, font: theme.type.callout, maxWidth: max(bounds.width - inset * 2, 1), maxLines: 5, alignment: .center, scale: scaleFactor)
        let top = retry.frame.minY - metrics.tv(36) - text.size.height
        context.symbol("exclamationmark.triangle", in: Rect(x: bounds.midX - side / 2, y: top - side - metrics.tv(24), width: side, height: side),
                       color: theme.palette.onArtSecondary)
        context.text(text, at: Point(x: ((bounds.midX - text.size.width / 2) * scaleFactor).rounded() / scaleFactor, y: top), color: theme.palette.onArt)
    }

    override func drawOverlay(_ context: inout DrawContext) {
        guard distance > 0.001 else { return }
        context.fill(bounds, radius: radius, color: Color.shade(0.62 * min(distance, 1)))
    }
}

/// A view drawn by whoever holds it, for a layer of a page that sits between its subviews.
@MainActor
private final class Canvas: View {
    var render: ((inout DrawContext) -> Void)?

    override func draw(_ context: inout DrawContext) {
        render?(&context)
    }
}

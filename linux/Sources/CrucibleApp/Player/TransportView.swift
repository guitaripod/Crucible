import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// The floating glass transport: the title, the player's menu buttons at the end of its row (Info, Speed, Sleep Timer,
/// Audio, Subtitles), a scrubber with what is buffered and a tick at each chapter, the time played and left, and
/// play/pause. Hovering the scrubber shows the time there and the chapter it falls in.
@MainActor
final class TransportView: View {
    enum Control: String, CaseIterable {
        case info, speed, sleep, audio, subtitles

        var title: String {
            switch self {
            case .info: String(localized: "Info")
            case .speed: String(localized: "Playback Speed")
            case .sleep: String(localized: "Sleep Timer")
            case .audio: String(localized: "Audio")
            case .subtitles: String(localized: "Subtitles")
            }
        }

        var symbol: Symbol {
            switch self {
            case .info: "info.circle"
            case .speed: "gauge.with.dots.needle.33percent"
            case .sleep: "moon.zzz"
            case .audio: "waveform"
            case .subtitles: "captions.bubble"
            }
        }
    }

    var title = "" { didSet { setNeedsDisplay() } }
    /// Chapter starts in seconds on the title's timeline, ticked on the scrubber.
    var chapterMarks: [Double] = [] { didSet { setNeedsDisplay() } }
    /// The name of the chapter a time falls in, for the scrubber's hover preview.
    var chapterTitle: ((Double) -> String?)?
    /// The preview still at a time, shown above the scrubber where the pointer is.
    var still: ((Double) -> Texture?)?
    /// A sleep timer is set, so its button is lit.
    var isSleepTimerSet = false { didSet { setNeedsDisplay() } }
    /// Playback runs at another speed than normal, so its button is lit.
    var isSpeedChanged = false { didSet { setNeedsDisplay() } }
    /// Where a drag along the scrubber is: begun, moving, or let go, with the fraction of the title it points at.
    enum ScrubPhase {
        case began, moved, ended
    }

    var onScrub: ((Float, ScrubPhase) -> Void)?
    var onTogglePause: (() -> Void)?
    /// A menu button was pressed, with where it sits in the window.
    var onControl: ((Control, Rect) -> Void)?

    private var position: Double = 0
    private var duration: Double = 0
    private var buffered: Double = 0
    private var paused = true
    private var buffering = false
    private var hoverFraction: Float?
    private var scrubbing = false
    /// The fraction a drag points at, which the knob, the time and the still follow rather than the player, whose picture
    /// trails a drag by a seek.
    private var scrubFraction: Float = 0
    private var lastScrubX: Float = 0
    private var tone = GlassTone()
    /// Each label's own tone over the picture right under it: dark over glare there while the glass as a whole reads dark.
    private var labelTones: [Label: GlassTone] = [:]

    private enum Label: Hashable {
        case title, play, elapsed, remaining, buffering, preview
        case control(Control)
    }

    func update(position: Double, duration: Double, buffered: Double, paused: Bool, buffering: Bool) {
        self.position = position
        self.duration = duration
        self.buffered = buffered
        self.paused = paused
        self.buffering = buffering
        setNeedsDisplay()
    }

    /// Where a control's button sits, in this view's points: right to left from the end of the title row.
    func frame(of control: Control) -> Rect {
        let metrics = Theme.current.metrics
        let side = metrics.tv(56)
        let order: [Control] = Control.allCases.reversed()
        let index = Float(order.firstIndex(of: control) ?? 0)
        return Rect(x: frame.width - metrics.tv(48) - side - index * (side + metrics.tv(16)), y: metrics.tv(20), width: side, height: side)
    }

    override var isPointerInteractive: Bool { true }
    override var cursor: Cursor { .default }

    /// The name of the icon under the pointer: play or pause, or one of the menu buttons.
    override func tooltip(at point: Point) -> String? {
        if playButton.insetBy(-8, -8).contains(point) { return paused ? String(localized: "Play") : String(localized: "Pause") }
        return Control.allCases.first { frame(of: $0).insetBy(-6, -6).contains(point) }?.title
    }

    override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: Theme.current.metrics.tv(150))
    }

    private var bar: Rect {
        let metrics = Theme.current.metrics
        let inset = metrics.tv(48)
        let playSize = metrics.tv(64)
        return Rect(x: inset + playSize + metrics.tv(32), y: frame.height - metrics.tv(52), width: frame.width - inset * 2 - playSize - metrics.tv(32),
                    height: metrics.tv(10))
    }

    private var playButton: Rect {
        let metrics = Theme.current.metrics
        let side = metrics.tv(64)
        return Rect(x: metrics.tv(48), y: bar.midY - side / 2, width: side, height: side)
    }

    private func fraction(at point: Point) -> Float {
        min(max((point.x - bar.x) / max(bar.width, 1), 0), 1)
    }

    override func pointerMoved(to point: Point) {
        guard !scrubbing else { return }
        hoverFraction = point.y > bar.y - Theme.current.metrics.tv(40) && point.x >= bar.x ? fraction(at: point) : nil
        setNeedsDisplay()
    }

    /// A drag keeps scrubbing wherever the pointer goes once it pressed the bar, off the transport included.
    override func pointerDragged(to point: Point) {
        guard scrubbing else { return }
        scrubFraction = scrubTarget(at: point)
        lastScrubX = point.x
        hoverFraction = scrubFraction
        onScrub?(scrubFraction, .moved)
        setNeedsDisplay()
    }

    /// Where a drag moving to `point` points: with Shift held the knob moves a tenth as far as the pointer, for a precise
    /// spot in a long title; otherwise it follows the pointer and settles on a chapter start it passes within a few points of.
    private func scrubTarget(at point: Point) -> Float {
        if window?.modifiers.contains(.shift) == true {
            return min(max(scrubFraction + (point.x - lastScrubX) / max(bar.width, 1) / 10, 0), 1)
        }
        let target = fraction(at: point)
        guard duration > 0 else { return target }
        let reach = Theme.current.metrics.tv(8) / max(bar.width, 1)
        let snapped = chapterMarks.map { Float($0 / duration) }.filter { abs($0 - target) <= reach }.min { abs($0 - target) < abs($1 - target) }
        return snapped ?? target
    }

    override func pointerExited() {
        hoverFraction = nil
        setNeedsDisplay()
    }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard button == .primary else { return false }
        if playButton.insetBy(-8, -8).contains(point) {
            onTogglePause?()
            return true
        }
        if let control = Control.allCases.first(where: { frame(of: $0).insetBy(-6, -6).contains(point) }) {
            onControl?(control, transformToWindow.apply(frame(of: control)))
            return true
        }
        if point.x >= bar.x - 8 {
            scrubbing = true
            scrubFraction = fraction(at: point)
            lastScrubX = point.x
            hoverFraction = scrubFraction
            onScrub?(scrubFraction, .began)
            setNeedsDisplay()
        }
        return true
    }

    override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        guard scrubbing else { return }
        scrubbing = false
        onScrub?(scrubFraction, .ended)
        setNeedsDisplay()
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    override func draw(_ context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        guard let scale = window?.scale else { return }
        if tone.update(context, rect: bounds) { startAnimating() }
        GlassStyle.capsule(in: bounds, radius: metrics.radiusL, light: Point(x: bounds.midX, y: bounds.minY - bounds.height), floating: true,
                           tone: tone.value, context: &context)
        let label = GlassStyle.label(tone: tone.value)
        let firstControl = Control.allCases.map(frame(of:)).map(\.minX).min() ?? frame.width
        let titleLayout = TextLayout(title, font: theme.type.headline, maxWidth: firstControl - metrics.tv(72), scale: scale)
        let titleOrigin = Point(x: metrics.tv(48), y: metrics.tv(28))
        context.text(titleLayout, at: titleOrigin,
                     color: GlassStyle.label(tone: labelTone(.title, over: Rect(origin: titleOrigin, size: titleLayout.size), context)))
        drawControls(context: &context)
        let symbol: Symbol = paused ? "play.fill" : "pause.fill"
        let play = playButton
        context.symbol(symbol, in: play.insetBy(play.width * 0.22, play.height * 0.22), color: GlassStyle.label(tone: labelTone(.play, over: play, context)))
        drawBar(label: label, scale: scale, context: &context)
    }

    /// The tone of `label` at `rect`, read from the picture under it, beside the glass's own.
    private func labelTone(_ label: Label, over rect: Rect, _ context: DrawContext) -> Float {
        var each = labelTones[label] ?? GlassTone()
        if each.update(context, rect: rect, on: tone) { startAnimating() }
        labelTones[label] = each
        return each.value
    }

    /// The menu buttons; a set sleep timer or a changed speed lights its button in the accent.
    private func drawControls(context: inout DrawContext) {
        let accent = Theme.current.palette.accent
        for control in Control.allCases {
            let button = frame(of: control)
            let lit = (control == .sleep && isSleepTimerSet) || (control == .speed && isSpeedChanged)
            let symbol: Symbol = control == .sleep && isSleepTimerSet ? "moon.zzz.fill" : control.symbol
            let label = GlassStyle.label(tone: labelTone(.control(control), over: button, context))
            context.symbol(symbol, in: button.insetBy(button.width * 0.22, button.height * 0.22), color: lit ? accent : label)
        }
    }

    private func drawBar(label: Color, scale: Float, context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        let track = bar
        context.fill(track, radius: track.height / 2, color: label.withAlpha(0.22))
        if duration > 0 {
            let bufferedEnd = min((position + buffered) / duration, 1)
            context.fill(Rect(x: track.x, y: track.y, width: track.width * Float(bufferedEnd), height: track.height), radius: track.height / 2,
                         color: label.withAlpha(0.18))
            let played = scrubbing ? scrubFraction : Float(min(max(position / duration, 0), 1))
            context.fill(Rect(x: track.x, y: track.y, width: max(track.width * played, track.height), height: track.height), radius: track.height / 2,
                         color: theme.palette.accent)
            for mark in chapterMarks where mark > 0 && mark < duration {
                let x = track.x + track.width * Float(mark / duration)
                context.fill(Rect(x: x - metrics.tv(2), y: track.y, width: metrics.tv(4), height: track.height), color: Color.shade(0.55))
            }
            let knob = metrics.tv(22)
            context.fill(Rect(x: track.x + track.width * played - knob / 2, y: track.midY - knob / 2, width: knob, height: knob), radius: knob / 2,
                         color: .white)
            if let hoverFraction {
                let time = Double(hoverFraction) * duration
                let text = [chapterTitle?(time), Self.clock(time)].compactMap { $0 }.joined(separator: " · ")
                let preview = TextLayout(text, font: theme.type.caption1, scale: scale)
                let anchor = track.x + track.width * hoverFraction
                let tick = metrics.tv(4)
                context.fill(Rect(x: (anchor - tick / 2).rounded(), y: track.y - metrics.tv(6), width: tick, height: track.height + metrics.tv(12)),
                             radius: tick / 2, color: label.withAlpha(0.85))
                if let texture = still?(time) {
                    drawStill(texture, caption: preview, centeredAt: anchor, context: &context)
                } else {
                    let origin = Point(x: min(max(anchor - preview.size.width / 2, track.x), track.maxX - preview.size.width),
                                       y: track.y - preview.size.height - metrics.tv(14))
                    context.text(preview, at: origin, color: GlassStyle.label(tone: labelTone(.preview, over: Rect(origin: origin, size: preview.size), context)))
                }
            }
        }
        let shown = scrubbing ? Double(scrubFraction) * duration : position
        let elapsed = TextLayout(Self.clock(shown), font: theme.type.caption1, scale: scale)
        let remaining = TextLayout("-" + Self.clock(max(duration - shown, 0)), font: theme.type.caption1, scale: scale)
        let elapsedOrigin = Point(x: track.x, y: track.maxY + metrics.tv(8))
        let remainingOrigin = Point(x: track.maxX - remaining.size.width, y: track.maxY + metrics.tv(8))
        context.text(elapsed, at: elapsedOrigin,
                     color: GlassStyle.secondaryLabel(tone: labelTone(.elapsed, over: Rect(origin: elapsedOrigin, size: elapsed.size), context)))
        context.text(remaining, at: remainingOrigin,
                     color: GlassStyle.secondaryLabel(tone: labelTone(.remaining, over: Rect(origin: remainingOrigin, size: remaining.size), context)))
        if buffering {
            let note = TextLayout(String(localized: "Buffering…"), font: theme.type.caption1, scale: scale)
            let origin = Point(x: track.midX - note.size.width / 2, y: track.maxY + metrics.tv(8))
            context.text(note, at: origin, color: GlassStyle.secondaryLabel(tone: labelTone(.buffering, over: Rect(origin: origin, size: note.size), context)))
        }
    }

    /// The preview still as a card floating above the glass over where the pointer is, kept inside the transport's width,
    /// with the time and chapter there on a dark pill at its foot.
    private func drawStill(_ texture: Texture, caption: TextLayout, centeredAt anchor: Float, context: inout DrawContext) {
        let metrics = Theme.current.metrics
        let width = metrics.tv(scrubbing ? 620 : 440)
        let height = (width * Float(texture.height) / Float(max(texture.width, 1))).rounded()
        let inset = metrics.tv(24)
        let x = min(max(anchor - width / 2, inset), bounds.width - inset - width).rounded()
        let card = Rect(x: x, y: (-metrics.tv(20) - height).rounded(), width: width, height: height)
        context.shadow(card, radius: metrics.radiusS, blur: metrics.tv(28), offsetY: metrics.tv(10), opacity: 0.5)
        context.image(texture, in: card, radius: metrics.radiusS)
        context.stroke(card, radius: metrics.radiusS, width: 1, color: Color.white.withAlpha(0.22))
        let pillHeight = caption.size.height + metrics.tv(12)
        let pillWidth = min(caption.size.width + metrics.tv(28), card.width - metrics.tv(16))
        let pill = Rect(x: (card.midX - pillWidth / 2).rounded(), y: (card.maxY - metrics.tv(10) - pillHeight).rounded(), width: pillWidth, height: pillHeight)
        context.fill(pill, radius: pillHeight / 2, color: Color.black.withAlpha(0.6))
        context.text(caption, at: Point(x: (pill.midX - caption.size.width / 2).rounded(), y: (pill.midY - caption.size.height / 2).rounded()), color: .white)
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        var moving = tone.advance(dt)
        for (label, var each) in labelTones {
            moving = each.advance(dt) || moving
            labelTones[label] = each
        }
        setNeedsDisplay()
        return moving
    }
}

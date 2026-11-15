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
    /// A sleep timer is set, so its button is lit.
    var isSleepTimerSet = false { didSet { setNeedsDisplay() } }
    /// Playback runs at another speed than normal, so its button is lit.
    var isSpeedChanged = false { didSet { setNeedsDisplay() } }
    var onSeek: ((Float) -> Void)?
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
    private var tone = GlassTone()

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
        hoverFraction = point.y > bar.y - Theme.current.metrics.tv(40) && point.x >= bar.x ? fraction(at: point) : nil
        if scrubbing { onSeek?(fraction(at: point)) }
        setNeedsDisplay()
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
            onSeek?(fraction(at: point))
        }
        return true
    }

    override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        scrubbing = false
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
        let secondary = GlassStyle.secondaryLabel(tone: tone.value)
        let firstControl = Control.allCases.map(frame(of:)).map(\.minX).min() ?? frame.width
        let titleLayout = TextLayout(title, font: theme.type.headline, maxWidth: firstControl - metrics.tv(72), scale: scale)
        context.text(titleLayout, at: Point(x: metrics.tv(48), y: metrics.tv(28)), color: label)
        drawControls(label: label, context: &context)
        let symbol: Symbol = paused ? "play.fill" : "pause.fill"
        let play = playButton
        context.symbol(symbol, in: play.insetBy(play.width * 0.22, play.height * 0.22), color: label)
        drawBar(label: label, secondary: secondary, scale: scale, context: &context)
    }

    /// The menu buttons; a set sleep timer or a changed speed lights its button in the accent.
    private func drawControls(label: Color, context: inout DrawContext) {
        let accent = Theme.current.palette.accent
        for control in Control.allCases {
            let button = frame(of: control)
            let lit = (control == .sleep && isSleepTimerSet) || (control == .speed && isSpeedChanged)
            let symbol: Symbol = control == .sleep && isSleepTimerSet ? "moon.zzz.fill" : control.symbol
            context.symbol(symbol, in: button.insetBy(button.width * 0.22, button.height * 0.22), color: lit ? accent : label)
        }
    }

    private func drawBar(label: Color, secondary: Color, scale: Float, context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        let track = bar
        context.fill(track, radius: track.height / 2, color: label.withAlpha(0.22))
        if duration > 0 {
            let bufferedEnd = min((position + buffered) / duration, 1)
            context.fill(Rect(x: track.x, y: track.y, width: track.width * Float(bufferedEnd), height: track.height), radius: track.height / 2,
                         color: label.withAlpha(0.18))
            let played = Float(min(max(position / duration, 0), 1))
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
                let x = min(max(track.x + track.width * hoverFraction - preview.size.width / 2, track.x), track.maxX - preview.size.width)
                context.text(preview, at: Point(x: x, y: track.y - preview.size.height - metrics.tv(14)), color: label)
            }
        }
        let elapsed = TextLayout(Self.clock(position), font: theme.type.caption1, scale: scale)
        let remaining = TextLayout("-" + Self.clock(max(duration - position, 0)), font: theme.type.caption1, scale: scale)
        context.text(elapsed, at: Point(x: track.x, y: track.maxY + metrics.tv(8)), color: secondary)
        context.text(remaining, at: Point(x: track.maxX - remaining.size.width, y: track.maxY + metrics.tv(8)), color: secondary)
        if buffering {
            let note = TextLayout(String(localized: "Buffering…"), font: theme.type.caption1, scale: scale)
            context.text(note, at: Point(x: track.midX - note.size.width / 2, y: track.maxY + metrics.tv(8)), color: secondary)
        }
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = tone.advance(dt)
        setNeedsDisplay()
        return moving
    }
}

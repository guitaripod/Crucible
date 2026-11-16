import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// The floating glass transport. On a couch, the tvOS layout: the title, the menu buttons at the end of its row, a slim
/// scrubber with play/pause before it and the times beneath. On a desk, a control bar made for the pointer: the title, a
/// tall scrubbing band whose track thickens under the pointer with the times at either end, and a row of large buttons
/// (skip back, play/pause, skip ahead, mute with a volume slider; Audio, Subtitles, Speed, Sleep Timer, Info and Full
/// Screen at the far end), each lit under the pointer and named with its shortcut in a tooltip. Either way the scrubber
/// shows what is buffered and a tick at each chapter, and hovering it shows the time there, the chapter and a still.
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

        /// The key that does the same, for the button's tooltip.
        var shortcut: String {
            switch self {
            case .info: "I"
            case .speed: "[ ]"
            case .sleep: "T"
            case .audio: "A"
            case .subtitles: "C"
            }
        }
    }

    /// A button of the desk's control row.
    enum Button: Hashable {
        case play, back, ahead, mute, fullscreen
        case control(Control)
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
    /// The window fills the screen, so the desk's Full Screen button offers to leave it.
    var isFullscreen = false { didSet { setNeedsDisplay() } }
    /// How far the desk's skip buttons go, for their tooltips.
    var skipSeconds = (back: 10, ahead: 10) { didSet { setNeedsDisplay() } }
    /// Where a drag along the scrubber is: begun, moving, or let go, with the fraction of the title it points at.
    enum ScrubPhase {
        case began, moved, ended
    }

    var onScrub: ((Float, ScrubPhase) -> Void)?
    var onTogglePause: (() -> Void)?
    /// A menu button was pressed, with where it sits in the window.
    var onControl: ((Control, Rect) -> Void)?
    /// The desk's skip buttons: false back, true ahead.
    var onSkip: ((Bool) -> Void)?
    var onToggleMute: (() -> Void)?
    /// The desk's volume slider or the wheel over it asks for this volume.
    var onVolume: ((Double) -> Void)?
    var onToggleFullscreen: (() -> Void)?
    /// The pointer moved over the transport, which keeps it showing, or left it (false), which lets it hide again.
    var onPointerActivity: ((Bool) -> Void)?

    /// Whether the pointer rests on the transport or drags its scrubber or volume, so it must not hide.
    var holdsChrome: Bool { pointer != nil || scrubbing || draggingVolume }

    private var position: Double = 0
    private var duration: Double = 0
    private var buffered: Double = 0
    private var paused = true
    private var buffering = false
    private var volume: Double = 100
    /// The volume the wheel is turning toward, unrounded, so a touchpad's small steps add up.
    private var wheelVolume: Double?
    /// When the viewer last set the volume here, before the player has reported it back.
    private var volumeSetAt: Double = 0
    private var muted = false
    private var maximumVolume: Double = 100
    private var hoverFraction: Float?
    private var scrubbing = false
    private var draggingVolume = false
    /// The fraction a drag points at, which the knob, the time and the still follow rather than the player, whose picture
    /// trails a drag by a seek.
    private var scrubFraction: Float = 0
    private var lastScrubX: Float = 0
    private var pointer: Point?
    private var hovered: Button?
    private var pressed: Button?
    /// How far the desk's track has thickened under the pointer, 0 to 1.
    private var thicken = Animated(0)
    private var tone = GlassTone()
    /// Each label's own tone over the picture right under it: dark over glare there while the glass as a whole reads dark.
    private var labelTones: [Label: GlassTone] = [:]

    private enum Label: Hashable {
        case title, play, elapsed, remaining, buffering, preview
        case button(Button)
    }

    private var isDesk: Bool { Theme.current.density == .desk }

    func update(position: Double, duration: Double, buffered: Double, paused: Bool, buffering: Bool) {
        self.position = position
        self.duration = duration
        self.buffered = buffered
        self.paused = paused
        self.buffering = buffering
        setNeedsDisplay()
    }

    /// The sound's state, for the desk's mute button and volume slider.
    func updateSound(volume: Double, muted: Bool, maximum: Double) {
        guard volume != self.volume || muted != self.muted || maximum != maximumVolume else { return }
        if !draggingVolume && Window.now() - volumeSetAt > 0.6 {
            self.volume = volume
            wheelVolume = nil
        }
        self.muted = muted
        maximumVolume = max(maximum, 1)
        setNeedsDisplay()
    }

    /// Where a control's button sits, in this view's points.
    func frame(of control: Control) -> Rect {
        if isDesk { return deskFrame(of: .control(control)) }
        let metrics = Theme.current.metrics
        let side = metrics.tv(56)
        let order: [Control] = Control.allCases.reversed()
        let index = Float(order.firstIndex(of: control) ?? 0)
        return Rect(x: frame.width - metrics.tv(48) - side - index * (side + metrics.tv(16)), y: metrics.tv(20), width: side, height: side)
    }

    override var isPointerInteractive: Bool { true }
    override var cursor: Cursor { .default }

    /// The name of the button under the pointer, with its key on a desk.
    override func tooltip(at point: Point) -> String? {
        if isDesk {
            guard let button = deskButton(at: point) else { return nil }
            return "\(name(of: button)) (\(shortcut(of: button)))"
        }
        if playButton.insetBy(-8, -8).contains(point) { return paused ? String(localized: "Play") : String(localized: "Pause") }
        return Control.allCases.first { frame(of: $0).insetBy(-6, -6).contains(point) }?.title
    }

    override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: Theme.current.metrics.tv(isDesk ? 372 : 150))
    }

    // MARK: Geometry

    /// The track the scrubber draws: on a desk, between the two times, thickening under the pointer.
    private var bar: Rect {
        let metrics = Theme.current.metrics
        if isDesk {
            let clock = clockWidth
            let x = deskInset + clock + metrics.tv(32)
            let height = metrics.tv(12) + metrics.tv(14) * thicken.value
            return Rect(x: x, y: (deskBarMidY - height / 2), width: frame.width - x * 2, height: height)
        }
        let inset = metrics.tv(48)
        let playSize = metrics.tv(64)
        return Rect(x: inset + playSize + metrics.tv(32), y: frame.height - metrics.tv(52), width: frame.width - inset * 2 - playSize - metrics.tv(32),
                    height: metrics.tv(10))
    }

    private var playButton: Rect {
        if isDesk { return deskFrame(of: .play) }
        let metrics = Theme.current.metrics
        let side = metrics.tv(64)
        return Rect(x: metrics.tv(48), y: bar.midY - side / 2, width: side, height: side)
    }

    private var deskInset: Float { Theme.current.metrics.tv(56) }
    private var deskBarMidY: Float { Theme.current.metrics.tv(146) }

    /// The band a press or hover scrubs in: the track's row from end to end, tall enough to hit without aiming.
    private var scrubBand: Rect {
        let metrics = Theme.current.metrics
        let track = bar
        return Rect(x: track.minX - metrics.tv(16), y: deskBarMidY - metrics.tv(46), width: track.width + metrics.tv(32), height: metrics.tv(92))
    }

    /// Room for the longest time either end of the desk's track shows, so the track does not shift as the digits change.
    private var clockWidth: Float {
        let sample = duration >= 3600 ? "-00:00:00" : "-00:00"
        return (TextLayout(sample, font: Theme.current.type.control, scale: window?.scale ?? 1).size.width + 2).rounded(.up)
    }

    private var deskButtonSide: Float { Theme.current.metrics.tv(116) }
    private var deskRowMidY: Float { frame.height - Theme.current.metrics.tv(34) - Theme.current.metrics.tv(66) }

    /// Where each button of the desk's row sits: back, play, ahead and mute from the start, the menus and Full Screen from
    /// the end.
    private func deskFrame(of button: Button) -> Rect {
        let metrics = Theme.current.metrics
        let side = deskButtonSide
        let gap = metrics.tv(12)
        func at(_ x: Float, _ size: Float = side) -> Rect { Rect(x: x, y: deskRowMidY - size / 2, width: size, height: size) }
        let start = deskInset - metrics.tv(22)
        let playSide = metrics.tv(132)
        switch button {
        case .back: return at(start)
        case .play: return at(start + side + gap, playSide)
        case .ahead: return at(start + side + gap * 2 + playSide)
        case .mute: return at(start + side * 2 + gap * 2 + playSide + metrics.tv(44))
        case .fullscreen: return at(frame.width - start - side)
        case .control(let control):
            let order: [Control] = [.info, .sleep, .speed, .subtitles, .audio]
            let index = Float(order.firstIndex(of: control) ?? 0)
            return at(frame.width - start - side * (index + 2) - gap * (index + 1) - metrics.tv(40))
        }
    }

    private var deskButtons: [Button] { [.back, .play, .ahead, .mute, .fullscreen] + Control.allCases.map { .control($0) } }

    /// The volume slider beside the mute button, as wide as the room before the menu buttons allows (none in a narrow
    /// window), and the wider band that takes presses and the wheel, never over a button.
    private var volumeTrack: Rect {
        let metrics = Theme.current.metrics
        let mute = deskFrame(of: .mute)
        let room = deskFrame(of: .control(.audio)).minX - metrics.tv(48) - (mute.maxX + metrics.tv(14))
        let width = min(metrics.tv(300), room)
        return Rect(x: mute.maxX + metrics.tv(14), y: deskRowMidY - metrics.tv(6), width: width >= metrics.tv(90) ? width : 0, height: metrics.tv(12))
    }

    private var hasVolumeSlider: Bool { volumeTrack.width > 0 }

    private var volumeBand: Rect {
        guard hasVolumeSlider else { return .zero }
        let metrics = Theme.current.metrics
        let band = volumeTrack.insetBy(-metrics.tv(18), -metrics.tv(44))
        let start = deskFrame(of: .mute).maxX + 1
        return Rect(x: max(band.minX, start), y: band.minY, width: band.maxX - max(band.minX, start), height: band.height)
    }

    private func deskButton(at point: Point) -> Button? {
        deskButtons.first { deskFrame(of: $0).contains(point) }
    }

    private func name(of button: Button) -> String {
        switch button {
        case .play: paused ? String(localized: "Play") : String(localized: "Pause")
        case .back: String(localized: "Skip Back \(skipSeconds.back) s", comment: "Player menu, with the skip distance")
        case .ahead: String(localized: "Skip Ahead \(skipSeconds.ahead) s", comment: "Player menu, with the skip distance")
        case .mute: muted ? String(localized: "Unmute", comment: "Player button") : String(localized: "Mute", comment: "Player button")
        case .fullscreen: isFullscreen ? String(localized: "Exit Full Screen", comment: "Player button") : String(localized: "Full Screen", comment: "Player menu")
        case .control(let control): control.title
        }
    }

    private func shortcut(of button: Button) -> String {
        switch button {
        case .play: KeyName.space
        case .back: KeyName.left
        case .ahead: KeyName.right
        case .mute: "M"
        case .fullscreen: "F"
        case .control(let control): control.shortcut
        }
    }

    private func symbol(of button: Button) -> Symbol {
        switch button {
        case .play: paused ? "play.fill" : "pause.fill"
        case .back: "gobackward.10"
        case .ahead: "goforward.10"
        case .mute: muted || volume <= 0 ? "speaker.slash" : (volume < 50 ? "speaker.wave.2" : "speaker.wave.3")
        case .fullscreen: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        case .control(let control): control == .sleep && isSleepTimerSet ? "moon.zzz.fill" : control.symbol
        }
    }

    private func fraction(at point: Point) -> Float {
        min(max((point.x - bar.x) / max(bar.width, 1), 0), 1)
    }

    // MARK: Pointer

    override func pointerMoved(to point: Point) {
        pointer = point
        onPointerActivity?(true)
        guard !scrubbing, !draggingVolume else { return }
        if isDesk {
            let inBand = scrubBand.contains(point)
            hoverFraction = inBand ? fraction(at: point) : nil
            setHovered(deskButton(at: point))
            thicken.set(inBand ? 1 : 0, animation: .timed(duration: 0.12, curve: .easeOut))
            startAnimating()
        } else {
            hoverFraction = point.y > bar.y - Theme.current.metrics.tv(40) && point.x >= bar.x ? fraction(at: point) : nil
        }
        setNeedsDisplay()
    }

    private func setHovered(_ button: Button?) {
        guard button != hovered else { return }
        hovered = button
        setNeedsDisplay()
    }

    /// A drag keeps scrubbing (or setting the volume) wherever the pointer goes once it pressed the bar, off the transport
    /// included.
    override func pointerDragged(to point: Point) {
        if draggingVolume {
            setVolume(at: point)
            return
        }
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
        pointer = nil
        onPointerActivity?(false)
        setHovered(nil)
        if !scrubbing {
            thicken.set(0, animation: .timed(duration: 0.18, curve: .easeOut))
            startAnimating()
        }
        setNeedsDisplay()
    }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard button == .primary else { return false }
        if isDesk {
            if let hit = deskButton(at: point) {
                pressed = hit
                setNeedsDisplay()
                return true
            }
            if volumeBand.contains(point) {
                draggingVolume = true
                setVolume(at: point)
                return true
            }
            if scrubBand.contains(point) { beginScrub(at: point) }
            return true
        }
        if playButton.insetBy(-8, -8).contains(point) {
            onTogglePause?()
            return true
        }
        if let control = Control.allCases.first(where: { frame(of: $0).insetBy(-6, -6).contains(point) }) {
            onControl?(control, transformToWindow.apply(frame(of: control)))
            return true
        }
        if point.x >= bar.x - 8 { beginScrub(at: point) }
        return true
    }

    private func beginScrub(at point: Point) {
        scrubbing = true
        scrubFraction = fraction(at: point)
        lastScrubX = point.x
        hoverFraction = scrubFraction
        onScrub?(scrubFraction, .began)
        setNeedsDisplay()
    }

    override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        if draggingVolume {
            draggingVolume = false
            onPointerActivity?(bounds.contains(point))
            return
        }
        if let hit = pressed {
            pressed = nil
            setNeedsDisplay()
            if deskButton(at: point) == hit { run(hit) }
            return
        }
        guard scrubbing else { return }
        scrubbing = false
        onScrub?(scrubFraction, .ended)
        onPointerActivity?(bounds.contains(point))
        if !scrubBand.contains(point) {
            thicken.set(0, animation: .timed(duration: 0.18, curve: .easeOut))
            startAnimating()
        }
        setNeedsDisplay()
    }

    private func run(_ button: Button) {
        switch button {
        case .play: onTogglePause?()
        case .back: onSkip?(false)
        case .ahead: onSkip?(true)
        case .mute: onToggleMute?()
        case .fullscreen: onToggleFullscreen?()
        case .control(let control): onControl?(control, transformToWindow.apply(deskFrame(of: button)))
        }
    }

    private func setVolume(at point: Point) {
        let track = volumeTrack
        let fraction = Double(min(max((point.x - track.x) / max(track.width, 1), 0), 1))
        volume = (fraction * maximumVolume).rounded()
        wheelVolume = nil
        volumeSetAt = Window.now()
        onVolume?(volume)
        setNeedsDisplay()
    }

    /// The wheel over the mute button or the volume slider turns the volume (5% a notch); anywhere else it goes on to the
    /// player, which seeks.
    override func scrolled(_ event: ScrollEvent) -> Bool {
        guard isDesk, let pointer, volumeBand.contains(pointer) || deskFrame(of: .mute).contains(pointer) else { return false }
        let step = event.isDiscrete ? Double(-event.notchesY + event.notchesX) * 5 : Double(-event.dy + event.dx) * 0.2
        guard step != 0 else { return true }
        let exact = min(max((wheelVolume ?? volume) + step, 0), maximumVolume)
        wheelVolume = exact
        volumeSetAt = Window.now()
        guard exact.rounded() != volume else { return true }
        volume = exact.rounded()
        onVolume?(volume)
        setNeedsDisplay()
        return true
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    // MARK: Drawing

    override func draw(_ context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        guard let scale = window?.scale else { return }
        if isDesk {
            GlassStyle.frostedSheet(in: bounds, radius: metrics.radiusL, scale: scale, dark: true, veil: 0.62, context: &context)
            drawDesk(label: GlassStyle.label(tone: 0), scale: scale, context: &context)
            return
        }
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

    /// The desk's layout: the title, the band with its times, and the row of buttons with the volume slider.
    private func drawDesk(label: Color, scale: Float, context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        let titleWidth = frame.width - deskInset * 2
        let titleLayout = TextLayout(title, font: theme.type.headline, maxWidth: titleWidth, maxLines: 1, scale: scale)
        let titleOrigin = Point(x: deskInset, y: metrics.tv(40))
        context.text(titleLayout, at: titleOrigin, color: label)
        let accent = theme.palette.accent
        for button in deskButtons {
            let rect = deskFrame(of: button)
            if hovered == button || pressed == button {
                context.fill(rect, radius: rect.height / 2, color: label.withAlpha(pressed == button ? 0.24 : 0.14))
            }
            let lit = (button == .control(.sleep) && isSleepTimerSet) || (button == .control(.speed) && isSpeedChanged)
            let inset = button == .play ? rect.width * 0.28 : rect.width * 0.29
            context.symbol(symbol(of: button), in: rect.insetBy(inset, inset), color: lit ? accent : label)
        }
        if hasVolumeSlider { drawVolume(label: label, context: &context) }
        drawBar(label: label, scale: scale, context: &context)
    }

    private func drawVolume(label: Color, context: inout DrawContext) {
        let theme = Theme.current
        let track = volumeTrack
        let level = Float(min(max(volume / maximumVolume, 0), 1))
        context.fill(track, radius: track.height / 2, color: label.withAlpha(0.22))
        if maximumVolume > 100 {
            let x = track.x + track.width * Float(100 / maximumVolume)
            context.fill(Rect(x: x - 0.5, y: track.y - theme.metrics.tv(4), width: 1, height: track.height + theme.metrics.tv(8)), color: label.withAlpha(0.4))
        }
        let fill = muted ? label.withAlpha(0.35) : label
        context.fill(Rect(x: track.x, y: track.y, width: max(track.width * level, track.height), height: track.height), radius: track.height / 2, color: fill)
        let knob = theme.metrics.tv(draggingVolume ? 28 : 24)
        context.fill(Rect(x: track.x + track.width * level - knob / 2, y: track.midY - knob / 2, width: knob, height: knob), radius: knob / 2,
                     color: muted ? Color.white.withAlpha(0.6) : .white)
    }

    /// The tone of `label` at `rect`, read from the picture under it, beside the glass's own.
    private func labelTone(_ label: Label, over rect: Rect, _ context: DrawContext) -> Float {
        var each = labelTones[label] ?? GlassTone()
        if each.update(context, rect: rect, on: tone) { startAnimating() }
        labelTones[label] = each
        return each.value
    }

    /// The couch's menu buttons; a set sleep timer or a changed speed lights its button in the accent.
    private func drawControls(context: inout DrawContext) {
        let accent = Theme.current.palette.accent
        for control in Control.allCases {
            let button = frame(of: control)
            let lit = (control == .sleep && isSleepTimerSet) || (control == .speed && isSpeedChanged)
            let symbol: Symbol = control == .sleep && isSleepTimerSet ? "moon.zzz.fill" : control.symbol
            let label = GlassStyle.label(tone: labelTone(.button(.control(control)), over: button, context))
            context.symbol(symbol, in: button.insetBy(button.width * 0.22, button.height * 0.22), color: lit ? accent : label)
        }
    }

    private func drawBar(label: Color, scale: Float, context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        let track = bar
        let timeFont = isDesk ? theme.type.control : theme.type.caption1
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
            let knob = isDesk ? metrics.tv(26) + metrics.tv(14) * thicken.value : metrics.tv(22)
            context.fill(Rect(x: track.x + track.width * played - knob / 2, y: track.midY - knob / 2, width: knob, height: knob), radius: knob / 2,
                         color: .white)
            if let hoverFraction {
                let time = Double(hoverFraction) * duration
                let text = [chapterTitle?(time), Self.clock(time)].compactMap { $0 }.joined(separator: " · ")
                let preview = TextLayout(text, font: isDesk ? theme.type.callout : theme.type.caption1, scale: scale)
                let anchor = track.x + track.width * hoverFraction
                let tick = metrics.tv(4)
                context.fill(Rect(x: (anchor - tick / 2).rounded(), y: track.y - metrics.tv(6), width: tick, height: track.height + metrics.tv(12)),
                             radius: tick / 2, color: label.withAlpha(0.85))
                if let texture = still?(time) {
                    drawStill(texture, caption: preview, centeredAt: anchor, context: &context)
                } else {
                    let origin = Point(x: min(max(anchor - preview.size.width / 2, track.x), track.maxX - preview.size.width),
                                       y: track.y - preview.size.height - metrics.tv(14))
                    context.text(preview, at: origin, color: isDesk ? label : GlassStyle.label(tone: labelTone(.preview, over: Rect(origin: origin, size: preview.size), context)))
                }
            }
        }
        let shown = scrubbing ? Double(scrubFraction) * duration : position
        let elapsed = TextLayout(Self.clock(shown), font: timeFont, scale: scale)
        let remaining = TextLayout("-" + Self.clock(max(duration - shown, 0)), font: timeFont, scale: scale)
        let elapsedOrigin: Point
        let remainingOrigin: Point
        if isDesk {
            elapsedOrigin = Point(x: deskInset, y: (track.midY - elapsed.size.height / 2).rounded())
            remainingOrigin = Point(x: frame.width - deskInset - remaining.size.width, y: (track.midY - remaining.size.height / 2).rounded())
        } else {
            elapsedOrigin = Point(x: track.x, y: track.maxY + metrics.tv(8))
            remainingOrigin = Point(x: track.maxX - remaining.size.width, y: track.maxY + metrics.tv(8))
        }
        let timeColor = { (tone: Float) in self.isDesk ? label : GlassStyle.secondaryLabel(tone: tone) }
        context.text(elapsed, at: elapsedOrigin, color: timeColor(labelTone(.elapsed, over: Rect(origin: elapsedOrigin, size: elapsed.size), context)))
        context.text(remaining, at: remainingOrigin, color: timeColor(labelTone(.remaining, over: Rect(origin: remainingOrigin, size: remaining.size), context)))
        if buffering {
            let note = TextLayout(String(localized: "Buffering…"), font: theme.type.caption1, scale: scale)
            let origin = isDesk
                ? Point(x: track.midX - note.size.width / 2, y: track.maxY + metrics.tv(12))
                : Point(x: track.midX - note.size.width / 2, y: track.maxY + metrics.tv(8))
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
        moving = thicken.advance(dt) || moving
        for (label, var each) in labelTones {
            moving = each.advance(dt) || moving
            labelTones[label] = each
        }
        setNeedsDisplay()
        return moving
    }
}

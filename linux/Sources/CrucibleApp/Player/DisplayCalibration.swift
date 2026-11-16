import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// The viewer's own measure of how far above white each screen goes in HDR (`DisplayCalibrationView`), kept per screen. It
/// wins over what the compositor says, which on most screens is a guess read from EDID.
@MainActor
enum DisplayCalibrationStore {
    private static let key = "display.headroom"

    /// The key a screen's calibration is kept under: its connector and the compositor's description of it, so the same TV
    /// on another port, or another TV on the same port, starts uncalibrated.
    static func screenKey(for window: Window) -> String {
        "\(window.outputName ?? "")|\(window.outputDescription ?? "")"
    }

    static func headroom(for screen: String, in defaults: UserDefaults = .standard) -> Double? {
        (defaults.dictionary(forKey: key)?[screen] as? Double).flatMap { $0 >= 1 ? $0 : nil }
    }

    static func save(headroom: Double?, for screen: String, in defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: key) ?? [:]
        all[screen] = headroom
        defaults.set(all, forKey: key)
    }

    /// How many times brighter than its white the screen shows: the viewer's calibration, else what the compositor says for
    /// an HDR screen (capped at what PQ carries), else 1 for an SDR screen or one the compositor says nothing about.
    static func headroom(for window: Window) -> (value: Double, calibrated: Bool) {
        guard let color = window.displayColor, color.isHDR else { return (1, false) }
        if let calibrated = headroom(for: screenKey(for: window)) { return (calibrated, true) }
        return (min(color.headroom > 1 ? color.headroom : 1000 / referenceWhite, maximumHeadroom), false)
    }

    /// Kiln's 1.0 in cd/m² (BT.2408's HDR reference white), the scale mpv's target peak is given in.
    static let referenceWhite = 203.0
    /// The most PQ carries above that white (10,000 cd/m²).
    static let maximumHeadroom = 10_000 / referenceWhite
}

extension PlayerScreen {
    /// Maps the picture to the screen the player is on: an HDR screen gets the picture tone-mapped by mpv to the brightest
    /// it shows above its white (`DisplayCalibrationStore.headroom(for:)`) and the compositor is told that peak, so it adds
    /// no curve of its own; an SDR screen gets HDR pictures mapped into its white, with mpv measuring each scene's peak.
    func applyDisplay() {
        guard let player, let window else { return }
        let headroom = DisplayCalibrationStore.headroom(for: window)
        let peak = (DisplayCalibrationStore.referenceWhite * headroom.value).rounded()
        player.set("target-peak", String(Int(peak)))
        player.set("tone-mapping", headroom.value >= DisplayCalibrationStore.maximumHeadroom ? "clip" : "spline")
        player.set("hdr-compute-peak", "yes")
        window.gpu.setContentPeak(nits: Float(peak))
        guard peak != appliedDisplayPeak else { return }
        appliedDisplayPeak = peak
        let color = window.displayColor
        MidgarLog.notice("Picture mapped to \(Int(peak)) cd/m2 (\(String(format: "%.1f", headroom.value))x white, \(headroom.calibrated ? "calibrated" : "as the compositor says")) "
                         + "on \(window.outputName ?? "?"): transfer \(color?.transfer ?? 0), reference \(Int(color?.reference ?? 0)), peak \(Int(color?.peak ?? 0))",
                         category: .playback)
    }

    /// Opens the calibration patterns over the picture, playback held until they close.
    func presentCalibration() {
        guard let window, calibration == nil else { return }
        let wasPlaying = player?.state.isPaused == false
        if wasPlaying { player?.setPaused(true) }
        let view = DisplayCalibrationView(screen: DisplayCalibrationStore.screenKey(for: window), color: window.displayColor,
                                          headroom: DisplayCalibrationStore.headroom(for: window).value)
        view.onClose = { [weak self] saved in
            guard let self else { return }
            self.calibration?.removeFromSuperview()
            self.calibration = nil
            self.applyDisplay()
            if wasPlaying { self.player?.setPaused(false) }
            self.window?.focus.focus(self, animated: false)
            if saved { self.say(String(localized: "Calibration Saved", comment: "Player message"), symbol: "checkmark") }
        }
        calibration = view
        addSubview(view)
        view.frame = bounds
        window.focus.focus(view, animated: false)
        showChrome(autoHide: true)
    }
}

/// Test patterns that set up a screen for Crucible's pictures, drawn in exact light by Kiln over a black field. Black: a
/// PLUGE-style row of near-black bars, with what to change on the TV when the darkest is lost or black looks grey (most
/// often a mismatch of full and limited range). Peak, on an HDR screen: a patch whose brightness Left and Right change,
/// with a sign at the brightest PQ can carry inside it; where the sign melts into the patch is the most the screen shows,
/// kept for this screen and used to tone-map every picture to it.
@MainActor
final class DisplayCalibrationView: View {
    enum Step {
        case black, peak
    }

    /// Closes the patterns: true when a peak was saved.
    var onClose: ((Bool) -> Void)?

    private let screen: String
    private let color: DisplayColor?
    private var step = Step.black
    private var headroom: Double

    init(screen: String, color: DisplayColor?, headroom: Double) {
        self.screen = screen
        self.color = color
        self.headroom = max(headroom, 1.5)
        super.init()
    }

    private var isHDR: Bool { color?.isHDR ?? false }

    override var canBecomeFocused: Bool { true }
    override var isPointerInteractive: Bool { true }
    override var accessibilityLabel: String? { title }

    override func keyPressed(_ event: KeyEvent) -> Bool {
        switch (step, event.key) {
        case (_, .escape), (_, .back):
            onClose?(false)
        case (.black, .return), (.black, .space), (.black, .right):
            if isHDR { step = .peak } else { onClose?(false) }
        case (.peak, .left):
            adjust(event.modifiers.contains(.shift) ? 0.99 : 0.95)
        case (.peak, .right):
            adjust(event.modifiers.contains(.shift) ? 1 / 0.99 : 1 / 0.95)
        case (.peak, .return), (.peak, .space):
            DisplayCalibrationStore.save(headroom: headroom, for: screen)
            onClose?(true)
        case (.peak, Key.character("a")):
            DisplayCalibrationStore.save(headroom: nil, for: screen)
            onClose?(false)
        default:
            return true
        }
        setNeedsDisplay()
        return true
    }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool { true }

    override func scrolled(_ event: ScrollEvent) -> Bool {
        guard step == .peak else { return true }
        adjust(event.dy < 0 || event.notchesY < 0 ? 1 / 0.97 : 0.97)
        setNeedsDisplay()
        return true
    }

    private func adjust(_ factor: Double) {
        headroom = min(max(headroom * factor, 1), DisplayCalibrationStore.maximumHeadroom)
    }

    private var title: String {
        switch step {
        case .black: String(localized: "Black Level", comment: "Display calibration step")
        case .peak: String(localized: "Brightest Highlight", comment: "Display calibration step")
        }
    }

    private var instructions: [String] {
        switch step {
        case .black:
            return [
                String(localized: "Bar 2 should be just visible, and the space around the bars pure black.",
                       comment: "Display calibration: black level goal"),
                String(localized: "Can’t see bar 2? Raise your TV’s Brightness, or set its HDMI black level to match your computer (Low or Limited when the computer sends limited range, Normal or Full for full range).",
                       comment: "Display calibration: black level fix when the darkest bar is lost"),
                String(localized: "Black looks grey? Lower Brightness, and check the same black level setting.",
                       comment: "Display calibration: black level fix when black is grey"),
                isHDR ? String(localized: "Press Return for the next pattern.", comment: "Display calibration: go on")
                      : String(localized: "Press Return when it looks right. The highlight pattern appears when HDR is on.",
                               comment: "Display calibration: done on an SDR screen"),
            ]
        case .peak:
            let nits = color.map { Int(($0.reference > 0 ? $0.reference : DisplayCalibrationStore.referenceWhite) * headroom) }
            let estimate = nits.map { String(localized: "about \($0) cd/m²", comment: "Display calibration: the brightness the patch is set to") } ?? ""
            return [
                String(localized: "Press → until the sign inside the square just disappears, then ← once so it is barely there.",
                       comment: "Display calibration: peak goal"),
                String(localized: "For an honest result, turn off your TV’s own HDR tone mapping (on LG TVs, set Dynamic Tone Mapping to HGIG).",
                       comment: "Display calibration: TV setting advice"),
                String(localized: "Now: \(String(format: "%.1f", headroom))× white, \(estimate). Return saves it for this screen, A goes back to automatic, Esc leaves it as it was.",
                       comment: "Display calibration: current value and keys"),
            ]
        }
    }

    override func draw(_ context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        guard let scale = window?.scale else { return }
        context.fill(bounds, color: .black)
        switch step {
        case .black: drawBlackBars(&context)
        case .peak: drawPeakPatch(&context)
        }
        let width = min(bounds.width - metrics.sideMargin * 2, metrics.tv(1500))
        var y = metrics.tv(70)
        let heading = TextLayout(title, font: theme.type.title3, maxWidth: width, scale: scale)
        context.text(heading, at: Point(x: ((bounds.width - heading.size.width) / 2).rounded(), y: y), color: Color.white.withAlpha(0.8))
        y += heading.size.height + metrics.tv(16)
        for line in instructions {
            let layout = TextLayout(line, font: theme.type.callout, maxWidth: width, maxLines: 4, alignment: .center, scale: scale)
            context.text(layout, at: Point(x: ((bounds.width - layout.size.width) / 2).rounded(), y: y), color: Color.white.withAlpha(0.55))
            y += layout.size.height + metrics.tv(10)
        }
    }

    /// Near-black bars on black, at 2, 4 and 8 percent of the signal above black (BT.1886 light), numbered beneath.
    private func drawBlackBars(_ context: inout DrawContext) {
        let metrics = Theme.current.metrics
        guard let scale = window?.scale else { return }
        let levels: [(Int, Double)] = [(2, 0.02), (4, 0.04), (8, 0.08)]
        let barWidth = metrics.tv(180)
        let barHeight = bounds.height * 0.38
        let gap = metrics.tv(90)
        let total = Float(levels.count) * barWidth + Float(levels.count - 1) * gap
        let top = bounds.midY - barHeight / 2 + metrics.tv(60)
        for (index, level) in levels.enumerated() {
            let x = (bounds.width - total) / 2 + Float(index) * (barWidth + gap)
            let light = Float(pow(level.1, 2.4))
            context.fill(Rect(x: x, y: top, width: barWidth, height: barHeight), color: Color(linearRed: light, green: light, blue: light))
            let label = TextLayout(String(level.0), font: Theme.current.type.headline, scale: scale)
            context.text(label, at: Point(x: (x + (barWidth - label.size.width) / 2).rounded(), y: top + barHeight + metrics.tv(24)), color: Color.white.withAlpha(0.5))
        }
    }

    /// A square at the chosen brightness with a ring and a cross at PQ's 10,000 cd/m² inside: while the screen can show
    /// the square, the sign stands out; once the square reaches the screen's limit, both clip to it and the sign melts away.
    private func drawPeakPatch(_ context: inout DrawContext) {
        let side = min(bounds.width, bounds.height) * 0.34
        let patch = Rect(x: bounds.midX - side / 2, y: bounds.midY - side / 2 + Theme.current.metrics.tv(70), width: side, height: side)
        let level = Float(headroom)
        context.fill(patch, color: Color(linearRed: level, green: level, blue: level))
        let top = Float(DisplayCalibrationStore.maximumHeadroom)
        let sign = Color(linearRed: top, green: top, blue: top)
        let ring = patch.insetBy(side * 0.3, side * 0.3)
        context.stroke(ring, radius: ring.width / 2, width: side * 0.035, color: sign)
        let bar = side * 0.035
        context.fill(Rect(x: patch.midX - bar / 2, y: ring.minY + ring.height * 0.2, width: bar, height: ring.height * 0.6), color: sign)
        context.fill(Rect(x: ring.minX + ring.width * 0.2, y: patch.midY - bar / 2, width: ring.width * 0.6, height: bar), color: sign)
    }
}

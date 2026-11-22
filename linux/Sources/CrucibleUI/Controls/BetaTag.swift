import Foundation
import Kiln

/// A small accent capsule reading BETA beside a feature's title, which explains the feature when pressed. Until the viewer
/// has opened it once, a soft glow breathes around it so it is noticed; afterwards it rests.
@MainActor
public final class BetaTagView: View {
    public var title: String { didSet { superview?.setNeedsLayout(); setNeedsDisplay() } }
    public var onPress: (() -> Void)?
    /// Whether the glow invites a first look.
    public var invites = false {
        didSet {
            guard invites != oldValue else { return }
            if invites { startAnimating() }
            setNeedsDisplay()
        }
    }

    private var lift = Animated(0)
    private var phase: Float = 0

    public init(title: String) {
        self.title = title
        super.init()
    }

    public override var canBecomeFocused: Bool { true }
    public override var accessibilityRole: AccessibilityRole { .button }
    public override var accessibilityLabel: String? { title }
    public override var overdraw: Float { Theme.current.metrics.tv(24) }
    public override var cursor: Cursor { .pointer }

    private func label(scale: Float) -> TextLayout {
        var font = Theme.current.type.badge
        font.letterSpacing = 1.5
        return TextLayout(title, font: font, scale: scale)
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        let text = label(scale: window?.scale ?? 1)
        return Size(width: (text.size.width + metrics.tv(28)).rounded(.up), height: (text.size.height + metrics.tv(12)).rounded(.up))
    }

    public override func activate() {
        onPress?()
    }

    public override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard button == .primary else { return false }
        window?.focus.focus(self, animated: true, reveal: false)
        onPress?()
        return true
    }

    public override func pointerEntered() { updateLift() }
    public override func pointerExited() { updateLift() }
    public override func focusDidChange(focused: Bool, animated: Bool) { updateLift() }

    private func updateLift() {
        lift.set(isFocused || isHovered ? 1 : 0, animation: .focus)
        startAnimating()
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = lift.advance(dt)
        if invites, !Animation.reduceMotion { phase = (phase + dt / 2.4).truncatingRemainder(dividingBy: 1) }
        setNeedsDisplay()
        return moving || (invites && !Animation.reduceMotion)
    }

    public override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let theme = Theme.current
        let palette = theme.palette
        let grow = 1 + 0.08 * lift.value
        let rect = Rect(x: bounds.midX - bounds.width * grow / 2, y: bounds.midY - bounds.height * grow / 2, width: bounds.width * grow, height: bounds.height * grow)
        let radius = rect.height / 2
        if invites {
            let breath = 0.5 - 0.5 * cos(phase * 2 * .pi)
            let halo = rect.insetBy(-theme.metrics.tv(6) * breath, -theme.metrics.tv(6) * breath)
            context.fill(halo, radius: halo.height / 2, color: palette.accent.withSRGBAlpha(0.22 * breath))
        }
        if lift.value > 0.01 { context.shadow(rect, radius: radius, blur: theme.metrics.tv(14), offsetY: theme.metrics.tv(6), opacity: 0.35 * lift.value) }
        context.fill(rect, radius: radius, color: palette.accent.mixed(with: palette.canvas, amount: 0.78 * (1 - lift.value)))
        context.stroke(rect, radius: radius, width: theme.metrics.tv(2), color: palette.accent.withSRGBAlpha(0.7 + 0.3 * lift.value))
        let text = label(scale: scale)
        let ink = palette.accentText.mixed(with: palette.onAccent, amount: lift.value)
        context.text(text, at: Point(x: (rect.midX - text.size.width / 2).rounded(), y: (rect.midY - text.size.height / 2).rounded()), color: ink)
    }
}

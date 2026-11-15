import Foundation
import Kiln

/// Rates one title (`TVRatingViewController`): a glass panel over the dimmed screen with five stars in ten half steps.
/// Left and Right (or the pointer) move the preview, Return or a click commits it, Clear Rating removes a rating the
/// title has, and Escape closes without a change.
@MainActor
public final class RatingPanelView: View {
    /// The chosen rating in half stars (1 to 10), or nil for Clear Rating.
    public var onCommit: ((Int?) -> Void)?
    private let heading: String
    private let stars: StarRowView
    private let clear: ButtonView?
    private var appear = Animated(0)
    private var tone = GlassTone()
    private weak var returnFocus: View?

    public init(title: String, halfStars: Int?, clearTitle: String) {
        heading = title
        stars = StarRowView(halfStars: halfStars ?? 0)
        clear = halfStars == nil ? nil : ButtonView(style: .glass, title: clearTitle)
        super.init()
        addSubview(stars)
        stars.onCommit = { [weak self] value in self?.commit(value) }
        if let clear {
            clear.onPress = { [weak self] in self?.commit(nil) }
            addSubview(clear)
        }
    }

    public func present(in window: Window) {
        returnFocus = window.focusedView
        window.contentView.addSubview(self)
        frame = window.contentView.bounds
        appear.set(1, animation: .spring(response: 0.3, dampingFraction: 0.9))
        startAnimating()
        window.focus.setVisible(true)
        window.focus.focus(stars, animated: false)
    }

    public func dismiss() {
        guard superview != nil else { return }
        let window = self.window
        let focus = returnFocus
        removeFromSuperview()
        if let focus, focus.window != nil { window?.focus.focus(focus, animated: false) }
    }

    private func commit(_ value: Int?) {
        dismiss()
        onCommit?(value)
    }

    public override var preferredFocusView: View? { stars }
    public override var isFocusScope: Bool { true }
    public override var isPointerInteractive: Bool { true }
    public override var cursor: Cursor { .default }

    public override func keyPressed(_ event: KeyEvent) -> Bool {
        guard event.key == .escape || event.key == .back else { return false }
        dismiss()
        return true
    }

    public override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        if !panel.contains(point) { dismiss() }
        return true
    }

    public override func scrolled(_ event: ScrollEvent) -> Bool { true }

    private var inset: Float { Theme.current.metrics.tv(48) }

    private func headingLayout(scale: Float) -> TextLayout {
        TextLayout(heading, font: Theme.current.type.headline, maxWidth: panelWidth - inset * 2, maxLines: 2, alignment: .center, scale: scale)
    }

    private var panelWidth: Float { min(Theme.current.metrics.messageColumn, frame.width - Theme.current.metrics.sideMargin * 2) }

    private var panel: Rect {
        let metrics = Theme.current.metrics
        let scale = window?.scale ?? 1
        var height = inset * 2 + headingLayout(scale: scale).size.height + metrics.tv(28) + stars.preferredHeight
        if clear != nil { height += metrics.tv(28) + metrics.primaryControlHeight }
        return Rect(x: ((frame.width - panelWidth) / 2).rounded(), y: ((frame.height - height) / 2).rounded(), width: panelWidth, height: height)
    }

    public override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let area = panel
        let scale = window?.scale ?? 1
        var y = area.y + inset + headingLayout(scale: scale).size.height + metrics.tv(28)
        let width = stars.preferredWidth
        stars.frame = Rect(x: (area.midX - width / 2).rounded(), y: y, width: width, height: stars.preferredHeight)
        y += stars.preferredHeight + metrics.tv(28)
        if let clear {
            let size = clear.sizeThatFits(Size(width: area.width, height: metrics.primaryControlHeight))
            clear.frame = Rect(x: (area.midX - size.width / 2).rounded(), y: y, width: size.width, height: size.height)
        }
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [appear.advance(dt), tone.advance(dt)].contains(true)
        stars.alpha = appear.value
        clear?.alpha = appear.value
        setNeedsDisplay()
        return moving
    }

    public override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let area = panel
        context.fill(bounds, color: Color.black.withSRGBAlpha(0.55 * appear.value))
        if tone.update(context, rect: area) { startAnimating() }
        context.faded(appear.value) { faded in
            GlassStyle.capsule(in: area, radius: Theme.current.metrics.radiusL, light: Point(x: area.midX, y: area.minY - area.height), floating: true,
                               tone: tone.value, context: &faded)
            faded.text(headingLayout(scale: scale), at: Point(x: area.x + inset, y: area.y + inset), color: GlassStyle.label(tone: tone.value))
        }
    }
}

/// Five stars in ten half steps: the focused preview fills up to it, with a bar under the step it rests on.
@MainActor
final class StarRowView: View {
    var onCommit: ((Int) -> Void)?
    private var value: Int
    private var hoverValue: Int?

    init(halfStars: Int) {
        value = max(halfStars, 1)
        super.init()
    }

    private var starSide: Float { Theme.current.metrics.tv(92) }
    private var gap: Float { Theme.current.metrics.tv(14) }
    var preferredWidth: Float { starSide * 5 + gap * 4 }
    var preferredHeight: Float { starSide + Theme.current.metrics.tv(24) }

    override var canBecomeFocused: Bool { true }
    override var isPointerInteractive: Bool { true }
    override func focusDidChange(focused: Bool, animated: Bool) { setNeedsDisplay() }

    private var shown: Int { hoverValue ?? value }

    override func keyPressed(_ event: KeyEvent) -> Bool {
        switch event.key {
        case .left:
            value = max(1, value - 1)
        case .right:
            value = min(10, value + 1)
        default:
            return false
        }
        setNeedsDisplay()
        return true
    }

    override func activate() {
        onCommit?(value)
    }

    /// The half step under `point`: the left half of a star is its odd step.
    private func step(at point: Point) -> Int {
        let pitch = starSide + gap
        let star = min(max(Int(point.x / pitch), 0), 4)
        let within = point.x - Float(star) * pitch
        return star * 2 + (within < starSide / 2 ? 1 : 2)
    }

    override func pointerMoved(to point: Point) {
        hoverValue = step(at: point)
        setNeedsDisplay()
    }

    override func pointerExited() {
        hoverValue = nil
        setNeedsDisplay()
    }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard button == .primary else { return false }
        value = step(at: point)
        onCommit?(value)
        return true
    }

    override func draw(_ context: inout DrawContext) {
        let palette = Theme.current.palette
        for star in 0..<5 {
            let rect = Rect(x: Float(star) * (starSide + gap), y: 0, width: starSide, height: starSide)
            let filled = shown - star * 2
            context.symbol("star", in: rect, color: palette.labelTertiary)
            if filled >= 2 {
                context.symbol("star.fill", in: rect, color: palette.accent)
            } else if filled == 1 {
                context.clipped(to: Rect(x: rect.x, y: rect.y, width: rect.width / 2, height: rect.height)) { half in
                    half.symbol("star.fill", in: rect, color: palette.accent)
                }
            }
        }
        if isFocused || hoverValue != nil {
            let index = shown - 1
            let half = starSide / 2
            let x = Float(index / 2) * (starSide + gap) + Float(index % 2) * half
            context.fill(Rect(x: x + 3, y: preferredHeight - Theme.current.metrics.tv(6), width: half - 6, height: Theme.current.metrics.tv(6)),
                         radius: 3, color: palette.accent)
        }
    }
}

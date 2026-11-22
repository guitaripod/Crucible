import Foundation
import Kiln

/// A note about a feature over a dimmed window, in the alert's glass: a tag and a title, an opening line, what the feature
/// does as points each beside its symbol, a closing paragraph and buttons. What a Beta tag opens.
@MainActor
public final class FeatureNoteView: View {
    public struct Point: Sendable {
        public var symbol: Symbol
        public var text: String

        public init(symbol: Symbol, text: String) {
            self.symbol = symbol
            self.text = text
        }
    }

    private let tag: String
    private let heading: String
    private let intro: String
    private let points: [Point]
    private let footer: String
    private let actions: [AlertView.Action]
    private var buttons: [ButtonView] = []
    private var appear = Animated(0)
    private var tone = GlassTone()
    private weak var returnFocus: View?

    public init(tag: String, title: String, intro: String, points: [Point], footer: String, actions: [AlertView.Action]) {
        self.tag = tag
        heading = title
        self.intro = intro
        self.points = points
        self.footer = footer
        self.actions = actions
        super.init()
        for (index, action) in actions.enumerated() {
            let button = ButtonView(style: .glass, title: action.title)
            button.onPress = { [weak self] in self?.choose(index) }
            buttons.append(button)
            addSubview(button)
        }
    }

    public override var accessibilityRole: AccessibilityRole { .dialog }
    public override var accessibilityLabel: String? { heading }
    public override var accessibilityHint: String? { ([intro] + points.map(\.text) + [footer]).joined(separator: " ") }
    public override var preferredFocusView: View? { buttons.last }
    public override var isFocusScope: Bool { true }
    public override var isPointerInteractive: Bool { true }
    public override var cursor: Cursor { .default }

    public func present(in window: Window) {
        returnFocus = window.focusedView
        window.contentView.addSubview(self)
        frame = window.contentView.bounds
        appear.set(1, animation: .spring(response: 0.3, dampingFraction: 0.9))
        startAnimating()
        window.focus.setVisible(true)
        window.focus.focus(preferredFocusView, animated: false)
    }

    public func dismiss() {
        guard superview != nil else { return }
        if let focus = returnFocus, focus.window != nil { window?.focus.focus(focus, animated: false) }
        removeFromSuperview()
    }

    private func choose(_ index: Int) {
        guard actions.indices.contains(index) else { return }
        dismiss()
        actions[index].handler?()
    }

    public override func keyPressed(_ event: KeyEvent) -> Bool {
        guard event.key == .escape || event.key == .back else { return false }
        dismiss()
        return true
    }

    public override func pointerPressed(_ button: MouseButton, at point: Kiln.Point) -> Bool {
        if !panel.contains(point) { dismiss() }
        return true
    }

    public override func scrolled(_ event: ScrollEvent) -> Bool { true }

    // MARK: Layout

    private var metrics: Metrics { Theme.current.metrics }
    private var inset: Float { metrics.tv(48) }
    private var gap: Float { metrics.tv(18) }
    private var panelWidth: Float { min(metrics.tv(1000), frame.width - metrics.sideMargin * 2) }
    private var textWidth: Float { panelWidth - inset * 2 }
    private var symbolSide: Float { metrics.tv(40) }
    private var rasterScale: Float { window?.scale ?? 1 }

    private func tagLayout() -> TextLayout {
        var font = Theme.current.type.badge
        font.letterSpacing = 1.5
        return TextLayout(tag, font: font, scale: rasterScale)
    }

    private func titleLayout() -> TextLayout {
        TextLayout(heading, font: Theme.current.type.title3, maxWidth: textWidth, maxLines: 2, scale: rasterScale)
    }

    private func bodyLayout(_ text: String, width: Float) -> TextLayout {
        TextLayout(text, font: Theme.current.type.callout, maxWidth: width, maxLines: 8, scale: rasterScale)
    }

    private var pointWidth: Float { textWidth - symbolSide - metrics.tv(20) }

    private var contentHeight: Float {
        var height = tagLayout().size.height + metrics.tv(12) + gap + titleLayout().size.height + gap + bodyLayout(intro, width: textWidth).size.height + gap
        for point in points { height += max(bodyLayout(point.text, width: pointWidth).size.height, symbolSide) + gap }
        height += bodyLayout(footer, width: textWidth).size.height + gap * 2 + metrics.primaryControlHeight
        return height
    }

    private var panel: Rect {
        let height = inset * 2 + contentHeight
        return Rect(x: ((frame.width - panelWidth) / 2).rounded(), y: max(((frame.height - height) / 2).rounded(), metrics.tv(30)), width: panelWidth, height: height)
    }

    public override func layoutSubviews() {
        let area = panel
        let widths = buttons.map { max($0.sizeThatFits(Size(width: 10_000, height: metrics.primaryControlHeight)).width, metrics.tv(240)) }
        var x = area.maxX - inset - widths.reduce(0, +) - gap * Float(max(widths.count - 1, 0))
        let y = area.maxY - inset - metrics.primaryControlHeight
        for (button, width) in zip(buttons, widths) {
            button.frame = Rect(x: x, y: y, width: width, height: metrics.primaryControlHeight)
            x += width + gap
        }
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [appear.advance(dt), tone.advance(dt)].contains(true)
        for button in buttons { button.alpha = appear.value }
        setNeedsDisplay()
        return moving
    }

    public override func draw(_ context: inout DrawContext) {
        let palette = Theme.current.palette
        let area = panel
        context.fill(bounds, color: Color.black.withSRGBAlpha(0.55 * appear.value))
        if tone.update(context, rect: area) { startAnimating() }
        context.faded(appear.value) { faded in
            faded.transformed(scale: 0.94 + 0.06 * appear.value, about: area.center) { inner in
                GlassStyle.capsule(in: area, radius: metrics.radiusL, light: Kiln.Point(x: area.midX, y: area.minY - area.height), floating: true, tone: tone.value,
                                   context: &inner)
                let label = GlassStyle.label(tone: tone.value)
                let secondary = GlassStyle.secondaryLabel(tone: tone.value)
                var y = area.y + inset
                let badge = tagLayout()
                let badgeRect = Rect(x: area.x + inset, y: y, width: badge.size.width + metrics.tv(28), height: badge.size.height + metrics.tv(12))
                inner.fill(badgeRect, radius: badgeRect.height / 2, color: palette.accent)
                inner.text(badge, at: Kiln.Point(x: badgeRect.minX + metrics.tv(14), y: badgeRect.minY + metrics.tv(6)), color: palette.onAccent)
                y = badgeRect.maxY + gap
                let title = titleLayout()
                inner.text(title, at: Kiln.Point(x: area.x + inset, y: y), color: label)
                y += title.size.height + gap
                let opening = bodyLayout(intro, width: textWidth)
                inner.text(opening, at: Kiln.Point(x: area.x + inset, y: y), color: secondary)
                y += opening.size.height + gap
                for point in points {
                    let text = bodyLayout(point.text, width: pointWidth)
                    let rowHeight = max(text.size.height, symbolSide)
                    let well = Rect(x: area.x + inset, y: y + (rowHeight - symbolSide) / 2, width: symbolSide, height: symbolSide)
                    inner.fill(well, radius: metrics.radiusXS, color: palette.accent.withSRGBAlpha(0.18))
                    inner.symbol(point.symbol, in: well.insetBy(metrics.tv(8), metrics.tv(8)), color: palette.accent)
                    inner.text(text, at: Kiln.Point(x: well.maxX + metrics.tv(20), y: y + (rowHeight - text.size.height) / 2), color: label)
                    y += rowHeight + gap
                }
                let closing = bodyLayout(footer, width: textWidth)
                inner.text(closing, at: Kiln.Point(x: area.x + inset, y: y), color: secondary)
            }
        }
    }
}

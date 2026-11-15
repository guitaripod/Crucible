import Foundation
import Kiln

/// Every keyboard shortcut at a glance (the iPad's Command-key overlay): the screen dims behind a glass panel of groups in
/// columns, each line an action and its keys as keycaps. Escape, Return or a click outside closes it; the arrows and the
/// wheel scroll it in a window too short for all of it.
@MainActor
public final class ShortcutsPanel: View {
    public struct Shortcut: Hashable, Sendable {
        public var title: String
        /// Each way to do it, as the desktop writes the keys ("Ctrl+F", "Space").
        public var keys: [String]

        public init(_ title: String, keys: [String]) {
            self.title = title
            self.keys = keys
        }
    }

    public struct Group: Hashable, Sendable {
        public var title: String
        public var shortcuts: [Shortcut]

        public init(_ title: String, shortcuts: [Shortcut]) {
            self.title = title
            self.shortcuts = shortcuts
        }
    }

    public var onDismiss: (() -> Void)?
    private let heading: String
    private let groups: [Group]
    private var appear = Animated(0)
    private var tone = GlassTone()
    private var offset: Float = 0
    private weak var returnFocus: View?

    public init(title: String, groups: [Group]) {
        heading = title
        self.groups = groups.filter { !$0.shortcuts.isEmpty }
        super.init()
    }

    public func present(in window: Window) {
        returnFocus = window.focusedView
        window.contentView.addSubview(self)
        frame = window.contentView.bounds
        appear.set(1, animation: .spring(response: 0.3, dampingFraction: 0.9))
        startAnimating()
        window.focus.focus(self, animated: false)
    }

    public func dismiss() {
        guard superview != nil else { return }
        if let focus = returnFocus, focus.window != nil { window?.focus.focus(focus, animated: false) }
        removeFromSuperview()
        onDismiss?()
    }

    public override var canBecomeFocused: Bool { true }
    public override var isFocusScope: Bool { true }
    public override var isPointerInteractive: Bool { true }
    public override var cursor: Cursor { .default }

    public override func keyPressed(_ event: KeyEvent) -> Bool {
        switch event.key {
        case .escape, .back, .return, .keypadEnter, .space:
            dismiss()
        case .down, .pageDown:
            scroll(by: Theme.current.metrics.tv(event.key == .down ? 120 : 600))
        case .up, .pageUp:
            scroll(by: -Theme.current.metrics.tv(event.key == .up ? 120 : 600))
        default:
            break
        }
        return true
    }

    public override func scrolled(_ event: ScrollEvent) -> Bool {
        scroll(by: event.dy)
        return true
    }

    public override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        if !panel.contains(point) { dismiss() }
        return true
    }

    private func scroll(by delta: Float) {
        offset = min(max(0, offset + delta), maximumOffset)
        setNeedsDisplay()
    }

    // MARK: Layout

    private var inset: Float { Theme.current.metrics.tv(48) }
    private var columnGap: Float { Theme.current.metrics.tv(64) }
    private var rowGap: Float { Theme.current.metrics.tv(14) }
    private var groupGap: Float { Theme.current.metrics.tv(40) }

    private var panelWidth: Float {
        min(Theme.current.metrics.tv(2000), frame.width - Theme.current.metrics.sideMargin * 2)
    }

    private var columnCount: Int {
        let metrics = Theme.current.metrics
        return max(1, min(3, Int((panelWidth - inset * 2 + columnGap) / (metrics.tv(560) + columnGap))))
    }

    private var columnWidth: Float {
        let count = Float(columnCount)
        return ((panelWidth - inset * 2 - columnGap * (count - 1)) / count).rounded(.down)
    }

    private func headingLayout(scale: Float) -> TextLayout {
        TextLayout(heading, font: Theme.current.type.title3, maxWidth: panelWidth - inset * 2, maxLines: 1, scale: scale)
    }

    private func keycap(_ text: String, scale: Float) -> TextLayout {
        TextLayout(text, font: Theme.current.type.caption1, maxLines: 1, scale: scale)
    }

    private func keysWidth(_ shortcut: Shortcut, scale: Float) -> Float {
        let metrics = Theme.current.metrics
        return shortcut.keys.reduce(Float(0)) { $0 + keycap($1, scale: scale).size.width + metrics.tv(24) } + Float(max(shortcut.keys.count - 1, 0)) * metrics.tv(10)
    }

    private func rowHeight(_ shortcut: Shortcut, scale: Float) -> Float {
        let title = TextLayout(shortcut.title, font: Theme.current.type.callout, maxWidth: max(columnWidth - keysWidth(shortcut, scale: scale) - Theme.current.metrics.tv(20), 40),
                               maxLines: 2, scale: scale)
        return max(title.size.height, keycap("M", scale: scale).size.height + Theme.current.metrics.tv(10))
    }

    private func groupHeight(_ group: Group, scale: Float) -> Float {
        let title = TextLayout(group.title, font: Theme.current.type.headline, maxWidth: columnWidth, maxLines: 1, scale: scale)
        return title.size.height + rowGap + group.shortcuts.reduce(Float(0)) { $0 + rowHeight($1, scale: scale) + rowGap }
    }

    /// The groups in columns, each placed in whichever column is shortest so far, with where each starts.
    private func columns(scale: Float) -> [[(group: Group, y: Float)]] {
        var placed = Array(repeating: [(group: Group, y: Float)](), count: columnCount)
        var heights = Array(repeating: Float(0), count: columnCount)
        for group in groups {
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            placed[column].append((group, heights[column]))
            heights[column] += groupHeight(group, scale: scale) + groupGap
        }
        return placed
    }

    private func contentHeight(scale: Float) -> Float {
        columns(scale: scale).map { column in column.last.map { $0.y + groupHeight($0.group, scale: scale) } ?? 0 }.max() ?? 0
    }

    private var panel: Rect {
        let metrics = Theme.current.metrics
        let scale = window?.scale ?? 1
        let natural = inset * 2 + headingLayout(scale: scale).size.height + groupGap + contentHeight(scale: scale)
        let height = min(natural, frame.height - metrics.tv(80))
        return Rect(x: ((frame.width - panelWidth) / 2).rounded(), y: ((frame.height - height) / 2).rounded(), width: panelWidth, height: height)
    }

    private var maximumOffset: Float {
        let scale = window?.scale ?? 1
        let natural = inset * 2 + headingLayout(scale: scale).size.height + groupGap + contentHeight(scale: scale)
        return max(0, natural - panel.height)
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [appear.advance(dt), tone.advance(dt)].contains(true)
        setNeedsDisplay()
        return moving
    }

    public override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let metrics = Theme.current.metrics
        let area = panel
        context.fill(bounds, color: Color.black.withSRGBAlpha(0.55 * appear.value))
        if tone.update(context, rect: area) { startAnimating() }
        context.faded(appear.value) { faded in
            faded.transformed(scale: 0.96 + 0.04 * appear.value, about: area.center) { inner in
                GlassStyle.capsule(in: area, radius: metrics.radiusL, light: Point(x: area.midX, y: area.minY - area.height), floating: true,
                                   tone: tone.value, context: &inner)
                inner.clipped(to: area) { clipped in
                    drawContent(in: area, scale: scale, context: &clipped)
                }
            }
        }
    }

    private func drawContent(in area: Rect, scale: Float, context: inout DrawContext) {
        let label = GlassStyle.label(tone: tone.value)
        let secondary = GlassStyle.secondaryLabel(tone: tone.value)
        let title = headingLayout(scale: scale)
        let top = area.y + inset - offset
        context.text(title, at: Point(x: area.x + inset, y: top), color: label)
        let contentTop = top + title.size.height + groupGap
        for (index, column) in columns(scale: scale).enumerated() {
            let x = area.x + inset + Float(index) * (columnWidth + columnGap)
            for placed in column {
                drawGroup(placed.group, at: Point(x: x, y: contentTop + placed.y), label: label, secondary: secondary, scale: scale, context: &context)
            }
        }
    }

    private func drawGroup(_ group: Group, at origin: Point, label: Color, secondary: Color, scale: Float, context: inout DrawContext) {
        let metrics = Theme.current.metrics
        let heading = TextLayout(group.title, font: Theme.current.type.headline, maxWidth: columnWidth, maxLines: 1, scale: scale)
        context.text(heading, at: origin, color: Theme.current.palette.accentText)
        var y = origin.y + heading.size.height + rowGap
        for shortcut in group.shortcuts {
            let keys = keysWidth(shortcut, scale: scale)
            let height = rowHeight(shortcut, scale: scale)
            let title = TextLayout(shortcut.title, font: Theme.current.type.callout, maxWidth: max(columnWidth - keys - metrics.tv(20), 40), maxLines: 2,
                                   scale: scale)
            context.text(title, at: Point(x: origin.x, y: y + ((height - title.size.height) / 2).rounded()), color: secondary)
            var x = origin.x + columnWidth - keys
            for key in shortcut.keys {
                let text = keycap(key, scale: scale)
                let cap = Rect(x: x, y: y + ((height - text.size.height - metrics.tv(10)) / 2).rounded(), width: text.size.width + metrics.tv(24),
                               height: text.size.height + metrics.tv(10))
                context.fill(cap, radius: metrics.tv(10), color: label.withAlpha(0.12))
                context.stroke(cap, radius: metrics.tv(10), width: 1, color: label.withAlpha(0.18))
                context.text(text, at: Point(x: cap.x + metrics.tv(12), y: cap.y + metrics.tv(5)), color: label)
                x = cap.maxX + metrics.tv(10)
            }
            y += height + rowGap
        }
    }
}

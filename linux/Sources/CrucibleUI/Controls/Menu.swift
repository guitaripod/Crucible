import Foundation
import Kiln

/// A menu (the tvOS long-press menu, Audio and Subtitles, a card's right click): a glass panel of rows that grows out of
/// what opened it, takes the keyboard while open, and closes on a choice, Escape or a click outside, giving focus back.
@MainActor
public final class MenuView: View {
    public struct Item: Hashable, Sendable {
        public var id: String
        public var title: String
        public var detail: String?
        public var symbol: Symbol?
        public var isChecked: Bool
        public var isDestructive: Bool
        /// The item's keyboard shortcut, on the trailing edge as desktop menus show it ("Ctrl+R").
        public var shortcut: String?

        public init(id: String, title: String, detail: String? = nil, symbol: Symbol? = nil, isChecked: Bool = false, isDestructive: Bool = false,
                    shortcut: String? = nil) {
            self.id = id
            self.title = title
            self.detail = detail
            self.symbol = symbol
            self.isChecked = isChecked
            self.isDestructive = isDestructive
            self.shortcut = shortcut
        }
    }

    public var onSelect: ((Item) -> Void)?
    public var onDismiss: (() -> Void)?
    private let header: String?
    private let rows: [MenuRowView]
    private let anchor: Rect
    private var appear = Animated(0)
    private weak var returnFocus: View?
    private var tone = GlassTone()

    /// A menu of `items` opening from `anchor` (window points).
    public init(title: String? = nil, items: [Item], anchor: Rect) {
        header = title
        self.anchor = anchor
        rows = items.map(MenuRowView.init)
        super.init()
        for row in rows {
            row.onPress = { [weak self] item in self?.choose(item) }
            addSubview(row)
        }
    }

    /// Shows the menu over everything in `window`.
    public func present(in window: Window) {
        returnFocus = window.focusedView
        window.contentView.addSubview(self)
        frame = window.contentView.bounds
        appear.set(1, animation: .spring(response: 0.3, dampingFraction: 0.85))
        startAnimating()
        window.focus.setVisible(true)
        window.focus.focus(rows.first(where: { $0.item.isChecked }) ?? rows.first, animated: false)
    }

    public func dismiss() {
        guard superview != nil else { return }
        if let focus = returnFocus, focus.window != nil { window?.focus.focus(focus, animated: false) }
        removeFromSuperview()
        onDismiss?()
    }

    private func choose(_ item: Item) {
        dismiss()
        onSelect?(item)
    }

    public override var preferredFocusView: View? { rows.first }
    public override var isFocusScope: Bool { true }
    public override var isPointerInteractive: Bool { true }
    public override var cursor: Cursor { .default }

    public override func keyPressed(_ event: KeyEvent) -> Bool {
        if event.key == .escape || event.key == .back {
            dismiss()
            return true
        }
        if event.key == .tab || event.key == .leftTab { return true }
        return false
    }

    public override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        if !panel.contains(point) { dismiss() }
        return true
    }

    public override func scrolled(_ event: ScrollEvent) -> Bool { true }

    private var rowHeight: Float { Theme.current.metrics.tv(76) }
    private var headerHeight: Float { header == nil ? 0 : Theme.current.metrics.tv(64) }

    private var panel: Rect {
        let metrics = Theme.current.metrics
        let scale = window?.scale ?? 1
        let widest = rows.map { $0.preferredWidth(scale: scale) }.max() ?? 0
        let width = min(max(widest, metrics.tv(420)), frame.width - metrics.sideMargin)
        let height = headerHeight + Float(rows.count) * rowHeight + metrics.tv(24)
        var x = anchor.minX
        var y = anchor.maxY + metrics.tv(12)
        if y + height > frame.height - metrics.tv(20) { y = anchor.minY - height - metrics.tv(12) }
        if x + width > frame.width - metrics.tv(20) { x = frame.width - width - metrics.tv(20) }
        return Rect(x: max(metrics.tv(20), x), y: max(metrics.tv(20), y), width: width, height: height)
    }

    public override func layoutSubviews() {
        let area = panel
        let inset = Theme.current.metrics.tv(12)
        for (index, row) in rows.enumerated() {
            row.frame = Rect(x: area.x + inset, y: area.y + inset + headerHeight + Float(index) * rowHeight, width: area.width - inset * 2, height: rowHeight)
        }
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [appear.advance(dt), tone.advance(dt)].contains(true)
        setNeedsDisplay()
        return moving
    }

    public override func draw(_ context: inout DrawContext) {
        let area = panel
        let grow = 0.92 + 0.08 * appear.value
        let pivot = Point(x: anchor.midX, y: anchor.midY < area.midY ? area.minY : area.maxY)
        if tone.update(context, rect: area) { startAnimating() }
        context.faded(appear.value) { faded in
            faded.transformed(scale: grow, about: pivot) { inner in
                GlassStyle.capsule(in: area, radius: Theme.current.metrics.radiusL, light: Point(x: area.midX, y: area.minY - area.height), floating: true,
                                   tone: tone.value, context: &inner)
                if let header, let scale = window?.scale {
                    let layout = TextLayout(header, font: Theme.current.type.caption1, maxWidth: area.width - Theme.current.metrics.tv(48), scale: scale)
                    inner.text(layout, at: Point(x: area.x + Theme.current.metrics.tv(28), y: area.y + Theme.current.metrics.tv(24)),
                               color: GlassStyle.secondaryLabel(tone: tone.value))
                }
            }
        }
        for row in rows {
            row.alpha = appear.value
            row.tone = tone.value
        }
    }
}

/// One row of a menu: a checkmark when chosen, the title and its detail, the item's shortcut and symbol on the trailing
/// edge as tvOS and desktop menus draw them, the light plate under focus or the pointer.
@MainActor
final class MenuRowView: View {
    let item: MenuView.Item
    var onPress: ((MenuView.Item) -> Void)?
    var tone: Float = 0
    private var lit = Animated(0)

    init(item: MenuView.Item) {
        self.item = item
        super.init()
    }

    override var canBecomeFocused: Bool { true }
    override var accessibilityLabel: String? { item.title }

    func preferredWidth(scale: Float) -> Float {
        let metrics = Theme.current.metrics
        let title = TextLayout(item.title, font: Theme.current.type.control, scale: scale).size.width
        let detail = item.detail.map { TextLayout($0, font: Theme.current.type.cardSubtitle, scale: scale).size.width } ?? 0
        let symbol = item.symbol == nil ? 0 : metrics.tv(56)
        let shortcut = item.shortcut.map { TextLayout($0, font: Theme.current.type.cardSubtitle, scale: scale).size.width + metrics.tv(40) } ?? 0
        return (max(title, detail) + metrics.tv(140) + symbol + shortcut).rounded(.up)
    }

    private func update() {
        lit.set(isFocused || isHovered ? 1 : 0, animation: .focus)
        startAnimating()
    }

    override func focusDidChange(focused: Bool, animated: Bool) { update() }
    override func pointerEntered() {
        window?.focus.focus(self, animated: true, reveal: false)
        update()
    }
    override func pointerExited() { update() }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool { button == .primary }

    override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        if button == .primary && inside { onPress?(item) }
    }

    override func activate() { onPress?(item) }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = lit.advance(dt)
        setNeedsDisplay()
        return moving
    }

    override func draw(_ context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        guard let scale = window?.scale else { return }
        if lit.value > 0.01 {
            context.fill(bounds, radius: metrics.radiusM, color: theme.palette.focusFill.withAlpha(lit.value))
        }
        let base = item.isDestructive ? theme.palette.destructive : GlassStyle.label(tone: tone)
        let color = base.mixed(with: theme.palette.onFocusFill, amount: lit.value)
        let secondary = GlassStyle.secondaryLabel(tone: tone).mixed(with: theme.palette.onFocusFillSecondary, amount: lit.value)
        let check = metrics.tv(28)
        if item.isChecked {
            context.symbol("checkmark", in: Rect(x: metrics.tv(20), y: bounds.midY - check / 2, width: check, height: check), color: color)
        }
        let x = metrics.tv(64)
        var trailing = metrics.tv(20)
        if let symbol = item.symbol {
            let side = metrics.tv(30)
            context.symbol(symbol, in: Rect(x: bounds.width - metrics.tv(24) - side, y: bounds.midY - side / 2, width: side, height: side), color: color)
            trailing += metrics.tv(56)
        }
        if let shortcut = item.shortcut {
            let keys = TextLayout(shortcut, font: theme.type.cardSubtitle, maxLines: 1, scale: scale)
            let keysY = ((bounds.height - keys.size.height) / 2 * scale).rounded() / scale
            context.text(keys, at: Point(x: bounds.width - trailing - keys.size.width, y: keysY), color: secondary)
            trailing += keys.size.width + metrics.tv(40)
        }
        let title = TextLayout(item.title, font: theme.type.control, maxWidth: bounds.width - x - trailing, scale: scale)
        let detail = item.detail.map { TextLayout($0, font: theme.type.cardSubtitle, maxWidth: bounds.width - x - trailing, scale: scale) }
        let total = title.size.height + (detail.map { $0.size.height } ?? 0)
        var y = ((bounds.height - total) / 2 * scale).rounded() / scale
        context.text(title, at: Point(x: x, y: y), color: color)
        y += title.size.height
        if let detail { context.text(detail, at: Point(x: x, y: y), color: secondary) }
    }
}

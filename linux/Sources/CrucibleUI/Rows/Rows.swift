import Foundation
import Kiln

/// View data of a settings-style row (`TVRowItem`): icon well, title, subtitle, value and an accessory. A toggle is a
/// row whose value reads On or Off and flips on Select, as on tvOS.
public struct RowItem: Hashable, Sendable {
    public enum Accessory: Hashable, Sendable { case none, chevron, checkmark }

    public var id: String
    public var title: String
    public var subtitle: String?
    public var value: String?
    public var symbol: Symbol?
    public var accessory: Accessory
    public var isDestructive: Bool
    public var isEnabled: Bool
    public var isStatic: Bool

    public init(id: String, title: String, subtitle: String? = nil, value: String? = nil, symbol: Symbol? = nil, accessory: Accessory = .none,
                isDestructive: Bool = false, isEnabled: Bool = true, isStatic: Bool = false) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.symbol = symbol
        self.accessory = accessory
        self.isDestructive = isDestructive
        self.isEnabled = isEnabled
        self.isStatic = isStatic
    }
}

/// A list row (`TVRowContentView`): bare text on the screen at rest, a light plate with dark text while focused, lifted
/// by `rowScale` and dipping while pressed. The pointer shows a faint plate.
@MainActor
public final class RowView: View {
    public var item: RowItem { didSet { if item != oldValue { superview?.setNeedsLayout(); setNeedsDisplay() } } }
    public var onSelect: ((RowItem) -> Void)?

    private var focus = Animated(0)
    private var hover = Animated(0)
    private var press = Animated(0)
    private var pressedByPointer = false

    public init(item: RowItem) {
        self.item = item
        super.init()
    }

    public override var canBecomeFocused: Bool { item.isEnabled && !item.isStatic }
    public override var accessibilityLabel: String? { [item.title, item.subtitle, item.value].compactMap { $0 }.joined(separator: ", ") }
    public override var overdraw: Float { Theme.current.metrics.focusShadowRadius * 2 }

    private var rasterScale: Float { window?.scale ?? 1 }

    private var textWidth: Float {
        let metrics = Theme.current.metrics
        var width = frame.width - metrics.rowInset * 2
        if item.symbol != nil { width -= metrics.rowIconWell + metrics.tv(32) }
        if item.accessory != .none || item.value != nil { width -= metrics.symbolAccessory + metrics.tv(32) }
        if let value = item.value { width -= TextLayout(value, font: Theme.current.type.callout, scale: rasterScale).size.width + metrics.tv(32) }
        return max(width, 40)
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        let type = Theme.current.type
        var height = TextLayout(item.title, font: type.rowTitle, maxWidth: textWidth, scale: rasterScale).size.height
        if let subtitle = item.subtitle, !subtitle.isEmpty {
            height += 2 + TextLayout(subtitle, font: type.cardSubtitle, maxWidth: textWidth, maxLines: 2, scale: rasterScale).size.height
        }
        return Size(width: size.width, height: max(metrics.rowHeight, height + metrics.tv(24)))
    }

    private func update() {
        let focused = isFocused && (window?.isFocusVisible ?? false)
        focus.set(focused ? 1 : 0, animation: .timed(duration: Durations.focus, curve: .easeInOut))
        hover.set(isHovered && !focused ? 1 : 0, animation: .focus)
        startAnimating()
    }

    public override func focusDidChange(focused: Bool, animated: Bool) { update() }
    public override func focusVisibilityDidChange(_ visible: Bool) { if isFocused { update() } }
    public override func pointerEntered() { update() }

    public override func pointerExited() {
        pressedByPointer = false
        press.set(0, animation: .press)
        update()
    }

    public override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard button == .primary, canBecomeFocused else { return false }
        pressedByPointer = true
        press.set(1, animation: .press)
        startAnimating()
        return true
    }

    public override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        guard button == .primary else { return }
        press.set(0, animation: .press)
        startAnimating()
        if pressedByPointer && inside {
            window?.focus.focus(self, animated: true, reveal: false)
            onSelect?(item)
        }
        pressedByPointer = false
    }

    public override func activate() {
        press.reset(1)
        press.set(0, animation: .press)
        startAnimating()
        onSelect?(item)
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [focus.advance(dt), hover.advance(dt), press.advance(dt)].contains(true)
        setNeedsDisplay()
        return moving
    }

    public override func draw(_ context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        let palette = theme.palette
        let type = theme.type
        let rect = bounds
        let lift = 1 + (metrics.rowScale(width: rect.width) - 1) * focus.value
        let scale = lift * (1 - (1 - metrics.pressedScale) * press.value)
        context.faded(item.isEnabled ? 1 : 0.45) { faded in
            faded.transformed(scale: scale, about: rect.center) { inner in
                if focus.value > 0.01 {
                    inner.shadow(rect, radius: metrics.radiusM, blur: metrics.focusShadowRadius, offsetY: metrics.focusShadowOffset,
                                 opacity: metrics.focusShadowOpacity * focus.value)
                    inner.fill(rect, radius: metrics.radiusM, color: palette.focusFill.withAlpha(focus.value))
                }
                if hover.value > 0.01 {
                    inner.fill(rect, radius: metrics.radiusM, color: palette.label.withAlpha(0.07 * hover.value))
                }
                let primary = (item.isDestructive ? palette.destructive : palette.label).mixed(with: palette.onFocusFill, amount: focus.value)
                let secondary = palette.labelSecondary.mixed(with: palette.onFocusFillSecondary, amount: focus.value)
                var x = metrics.rowInset
                if let symbol = item.symbol {
                    let well = Rect(x: x, y: rect.midY - metrics.rowIconWell / 2, width: metrics.rowIconWell, height: metrics.rowIconWell)
                    inner.fill(well, radius: metrics.radiusS, color: palette.accentTint.mixed(with: palette.onFocusFill.withAlpha(0.08), amount: focus.value))
                    let glyph = metrics.symbolRow
                    inner.symbol(symbol, in: Rect(x: well.midX - glyph / 2, y: well.midY - glyph / 2, width: glyph, height: glyph),
                                 color: item.isDestructive ? palette.destructive : palette.accentText)
                    x = well.maxX + metrics.tv(32)
                }
                let title = TextLayout(item.title, font: type.rowTitle, maxWidth: textWidth, scale: rasterScale)
                var subtitle: TextLayout?
                if let text = item.subtitle, !text.isEmpty {
                    subtitle = TextLayout(text, font: type.cardSubtitle, maxWidth: textWidth, maxLines: 2, scale: rasterScale)
                }
                let blockHeight = title.size.height + (subtitle.map { $0.size.height + 2 } ?? 0)
                var y = ((rect.height - blockHeight) / 2 * rasterScale).rounded() / rasterScale
                inner.text(title, at: Point(x: x, y: y), color: primary)
                y += title.size.height + 2
                if let subtitle { inner.text(subtitle, at: Point(x: x, y: y), color: secondary) }
                var trailing = rect.width - metrics.rowInset
                let accessorySize = metrics.symbolAccessory
                switch item.accessory {
                case .chevron:
                    inner.symbol("chevron.right", in: Rect(x: trailing - accessorySize, y: rect.midY - accessorySize / 2, width: accessorySize,
                                                           height: accessorySize), color: secondary)
                    trailing -= accessorySize + metrics.tv(32)
                case .checkmark:
                    inner.symbol("checkmark", in: Rect(x: trailing - accessorySize, y: rect.midY - accessorySize / 2, width: accessorySize,
                                                       height: accessorySize), color: palette.accentText.mixed(with: palette.onFocusFill, amount: focus.value))
                    trailing -= accessorySize + metrics.tv(32)
                case .none:
                    if item.value != nil { trailing -= accessorySize + metrics.tv(32) }
                }
                if let value = item.value, !value.isEmpty {
                    let layout = TextLayout(value, font: type.callout, scale: rasterScale)
                    let valueY = ((rect.height - layout.size.height) / 2 * rasterScale).rounded() / rasterScale
                    inner.text(layout, at: Point(x: trailing - layout.size.width, y: valueY), color: secondary)
                }
            }
        }
    }
}

/// A vertical list of rows in a centred readable column, as tvOS Settings lays them out.
@MainActor
public final class RowListView: View {
    public private(set) var items: [RowItem] = []
    public var onSelect: ((RowItem) -> Void)?
    public var columnWidth: Float?
    /// Starts the column at the screen's margin, in line with a grid below it, instead of centring it.
    public var isLeadingAligned = false { didSet { setNeedsLayout() } }
    private var rows: [String: RowView] = [:]

    public override var remembersFocus: Bool { true }
    public override var preferredFocusView: View? { items.first { $0.isEnabled && !$0.isStatic }.flatMap { rows[$0.id] } }

    public func setItems(_ newItems: [RowItem]) {
        items = newItems
        var next: [String: RowView] = [:]
        for item in newItems {
            let row = rows[item.id] ?? RowView(item: item)
            row.item = item
            row.onSelect = { [weak self] item in self?.onSelect?(item) }
            if row.superview == nil { addSubview(row) }
            next[item.id] = row
        }
        for (id, row) in rows where next[id] == nil { row.removeFromSuperview() }
        rows = next
        setNeedsLayout()
    }

    private var column: Rect {
        let metrics = Theme.current.metrics
        let width = min(columnWidth ?? metrics.wideColumn, frame.width - metrics.sideMargin * 2)
        let x = isLeadingAligned ? metrics.sideMargin : ((frame.width - width) / 2).rounded()
        return Rect(x: x, y: 0, width: width, height: frame.height)
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        let width = min(columnWidth ?? metrics.wideColumn, size.width - metrics.sideMargin * 2)
        let heights = items.compactMap { rows[$0.id]?.sizeThatFits(Size(width: width, height: 0)).height }
        let total = heights.reduce(0, +) + Float(max(heights.count - 1, 0)) * metrics.rowSpacing + metrics.tv(24)
        return Size(width: size.width, height: total)
    }

    public override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let area = column
        var y: Float = 0
        for item in items {
            guard let row = rows[item.id] else { continue }
            let height = row.sizeThatFits(Size(width: area.width, height: 0)).height
            row.frame = Rect(x: area.x, y: y, width: area.width, height: height)
            y += height + metrics.rowSpacing
        }
    }
}

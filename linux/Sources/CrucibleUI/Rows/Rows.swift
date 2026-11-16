import Foundation
import Kiln

/// View data of a settings-style row (`TVRowItem`): icon well, title, subtitle, value and an accessory. A toggle is a
/// row whose value reads On or Off and flips on Select, as on tvOS.
public struct RowItem: Hashable, Sendable {
    public enum Accessory: Hashable, Sendable {
        case none, chevron, checkmark
        /// A switch, on or off, that the row's activation flips (a desk's settings).
        case toggle(Bool)
    }

    public var id: String
    public var title: String
    public var subtitle: String?
    public var value: String?
    public var symbol: Symbol?
    public var accessory: Accessory
    public var isDestructive: Bool
    public var isEnabled: Bool
    public var isStatic: Bool
    /// A service's official mark (`trakt`, `seerr`) filling the icon well in place of the symbol.
    public var brand: String?

    /// A setting that is on or off: a switch on a desk, "On" or "Off" as the value on a couch, as tvOS Settings shows it.
    @MainActor
    public static func onOff(id: String, title: String, subtitle: String? = nil, isOn: Bool, symbol: Symbol? = nil, isEnabled: Bool = true) -> RowItem {
        if Theme.current.density == .desk {
            return RowItem(id: id, title: title, subtitle: subtitle, symbol: symbol, accessory: .toggle(isOn), isEnabled: isEnabled)
        }
        return RowItem(id: id, title: title, subtitle: subtitle, value: Strings.lookup(isOn ? "On" : "Off"), symbol: symbol, isEnabled: isEnabled)
    }

    public init(id: String, title: String, subtitle: String? = nil, value: String? = nil, symbol: Symbol? = nil, accessory: Accessory = .none,
                isDestructive: Bool = false, isEnabled: Bool = true, isStatic: Bool = false, brand: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.symbol = symbol
        self.accessory = accessory
        self.isDestructive = isDestructive
        self.isEnabled = isEnabled
        self.isStatic = isStatic
        self.brand = brand
    }
}

/// A list row (`TVRowContentView`): bare text on the screen at rest, a light plate with dark text while focused, lifted
/// by `rowScale` and dipping while pressed. The pointer shows a faint plate.
@MainActor
public final class RowView: View {
    public var item: RowItem {
        didSet {
            guard item != oldValue else { return }
            laidOut = nil
            superview?.setNeedsLayout()
            setNeedsDisplay()
        }
    }
    public var onSelect: ((RowItem) -> Void)?
    /// Asked for the row's menu (right-click or the Menu key) with where to anchor it in the window; returns whether a
    /// menu opened.
    public var onContextMenu: ((RowItem, Rect) -> Bool)?
    /// The row took the focus.
    public var onFocus: ((RowItem) -> Void)?

    private var focus = Animated(0)
    private var hover = Animated(0)
    private var press = Animated(0)
    private var pressedByPointer = false

    public init(item: RowItem) {
        self.item = item
        super.init()
    }

    public override var canBecomeFocused: Bool { item.isEnabled && !item.isStatic }
    /// The row whose page shows beside the list (a desk's two panes), tinted in the accent.
    public var isSelected = false { didSet { if isSelected != oldValue { setNeedsDisplay() } } }
    public override var accessibilityIsSelected: Bool? { isSelected ? true : nil }
    public override var accessibilityLabel: String? { [item.title, item.value].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ") }
    public override var accessibilityValue: String? {
        if case .toggle(let isOn) = item.accessory { return Strings.lookup(isOn ? "On" : "Off") }
        return nil
    }

    /// A switch's track.
    static var switchSize: Size { Size(width: Theme.current.metrics.tv(88), height: Theme.current.metrics.tv(50)) }

    /// A switch in `rect`: the accent track with the knob at its end when on, a muted one with the knob at its start off.
    static func drawSwitch(_ isOn: Bool, in rect: Rect, context: inout DrawContext) {
        let palette = Theme.current.palette
        context.fill(rect, radius: rect.height / 2, color: isOn ? palette.accent : palette.label.withAlpha(0.22))
        let inset = rect.height * 0.1
        let knob = rect.height - inset * 2
        let x = isOn ? rect.maxX - inset - knob : rect.minX + inset
        context.shadow(Rect(x: x, y: rect.minY + inset, width: knob, height: knob), radius: knob / 2, blur: 3, offsetY: 1, opacity: 0.3)
        context.fill(Rect(x: x, y: rect.minY + inset, width: knob, height: knob), radius: knob / 2, color: .white)
    }
    public override var accessibilityHint: String? { item.subtitle }
    public override var overdraw: Float { Theme.current.metrics.focusShadowRadius * 2 }

    private var rasterScale: Float { window?.scale ?? 1 }

    /// The row's title, subtitle and value laid out for one width.
    private struct Texts {
        let title: TextLayout
        let subtitle: TextLayout?
        let value: TextLayout?
    }

    private var laidOut: (width: Float, scale: Float, font: Font, texts: Texts)?

    /// The texts for a row `width` points wide, kept until the item, the width, the scale or the type changes: rows
    /// draw every frame of a focus move. A value takes at most two fifths of the row, on up to two lines, so a long one
    /// (Back 10 Seconds · Ahead 10 Seconds) leaves the title and subtitle their room.
    private func texts(width: Float) -> Texts {
        let type = Theme.current.type
        let scale = rasterScale
        if let laidOut, laidOut.width == width, laidOut.scale == scale, laidOut.font == type.rowTitle { return laidOut.texts }
        let metrics = Theme.current.metrics
        var value: TextLayout?
        if let text = item.value, !text.isEmpty {
            let cap = max(40, (width - metrics.rowInset * 2) * 0.4)
            let natural = TextLayout(text, font: type.callout, maxWidth: cap, maxLines: 2, scale: scale)
            value = natural.lineCount > 1
                ? TextLayout(text, font: type.callout, maxWidth: natural.size.width + 1, maxLines: 2, alignment: .trailing, scale: scale) : natural
        }
        var textWidth = width - metrics.rowInset * 2
        if item.symbol != nil || item.brand != nil { textWidth -= metrics.rowIconWell + metrics.tv(32) }
        if case .toggle = item.accessory {
            textWidth -= RowView.switchSize.width + metrics.tv(32)
        } else if item.accessory != .none || item.value != nil {
            textWidth -= metrics.symbolAccessory + metrics.tv(32)
        }
        if let value { textWidth -= value.size.width + metrics.tv(32) }
        textWidth = max(textWidth, 40)
        let subtitle = item.subtitle.flatMap { $0.isEmpty ? nil : TextLayout($0, font: type.cardSubtitle, maxWidth: textWidth, maxLines: 2, scale: scale) }
        let texts = Texts(title: TextLayout(item.title, font: type.rowTitle, maxWidth: textWidth, scale: scale), subtitle: subtitle, value: value)
        laidOut = (width, scale, type.rowTitle, texts)
        return texts
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        let texts = texts(width: size.width)
        var height = texts.title.size.height
        if let subtitle = texts.subtitle { height += 2 + subtitle.size.height }
        height = max(height, texts.value?.size.height ?? 0)
        return Size(width: size.width, height: max(metrics.rowHeight, height + metrics.tv(24)))
    }

    private func update() {
        let focused = isFocused && (window?.isFocusVisible ?? false)
        focus.set(focused ? 1 : 0, animation: .timed(duration: Durations.focus, curve: .easeInOut))
        hover.set(isHovered && !focused ? 1 : 0, animation: .focus)
        startAnimating()
    }

    public override func focusDidChange(focused: Bool, animated: Bool) {
        update()
        if focused { onFocus?(item) }
    }
    public override func focusVisibilityDidChange(_ visible: Bool) { if isFocused { update() } }
    public override func pointerEntered() { update() }

    public override func pointerExited() {
        pressedByPointer = false
        press.set(0, animation: .press)
        update()
    }

    public override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        if button == .secondary, canBecomeFocused, let onContextMenu {
            window?.focus.focus(self, animated: true, reveal: false)
            let origin = frameInWindow.origin
            return onContextMenu(item, Rect(x: origin.x + point.x, y: origin.y + point.y, width: 1, height: 1))
        }
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

    public override func showContextMenu(at point: Point?) -> Bool {
        let frame = frameInWindow
        let anchor = point.map { Rect(x: frame.x + $0.x, y: frame.y + $0.y, width: 1, height: 1) }
            ?? Rect(x: frame.maxX - Theme.current.metrics.tv(500), y: frame.maxY, width: 1, height: 1)
        return onContextMenu?(item, anchor) ?? false
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
                if isSelected && focus.value < 0.99 {
                    inner.fill(rect, radius: metrics.radiusM, color: palette.accent.withAlpha(0.2 * (1 - focus.value)))
                }
                if hover.value > 0.01 {
                    inner.fill(rect, radius: metrics.radiusM, color: palette.label.withAlpha(0.07 * hover.value))
                }
                let primary = (item.isDestructive ? palette.destructive : palette.label).mixed(with: palette.onFocusFill, amount: focus.value)
                let secondary = palette.labelSecondary.mixed(with: palette.onFocusFillSecondary, amount: focus.value)
                var x = metrics.rowInset
                if item.symbol != nil || item.brand != nil {
                    let well = Rect(x: x, y: rect.midY - metrics.rowIconWell / 2, width: metrics.rowIconWell, height: metrics.rowIconWell)
                    if let brand = item.brand, let gpu = window?.gpu, let mark = BrandMarks.texture(brand, gpu: gpu) {
                        inner.image(mark, in: well, radius: metrics.radiusS, fit: true)
                    } else if let symbol = item.symbol {
                        inner.fill(well, radius: metrics.radiusS, color: palette.accentTint.mixed(with: palette.onFocusFill.withAlpha(0.08), amount: focus.value))
                        let glyph = metrics.symbolRow
                        inner.symbol(symbol, in: Rect(x: well.midX - glyph / 2, y: well.midY - glyph / 2, width: glyph, height: glyph),
                                     color: item.isDestructive ? palette.destructive : palette.accentText.mixed(with: Palette.light.accentText, amount: focus.value))
                    }
                    x = well.maxX + metrics.tv(32)
                }
                let texts = texts(width: rect.width)
                let title = texts.title
                let subtitle = texts.subtitle
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
                case .toggle(let isOn):
                    let size = RowView.switchSize
                    RowView.drawSwitch(isOn, in: Rect(x: trailing - size.width, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                                       context: &inner)
                    trailing -= size.width + metrics.tv(32)
                case .none:
                    if item.value != nil { trailing -= accessorySize + metrics.tv(32) }
                }
                if let layout = texts.value {
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
    /// The menu for a row (right-click or the Menu key), given where to anchor it in the window; returns whether one opened.
    public var onContextMenu: ((RowItem, Rect) -> Bool)?
    /// A row took the focus.
    public var onFocus: ((RowItem) -> Void)?
    public var columnWidth: Float?
    /// The row whose page shows beside the list (a desk's two panes).
    public var selectedID: String? { didSet { rows.forEach { $0.value.isSelected = $0.key == selectedID } } }
    /// Starts the column at the screen's margin, in line with a grid below it, instead of centring it.
    public var isLeadingAligned = false { didSet { setNeedsLayout() } }
    private var rows: [String: RowView] = [:]

    public override var remembersFocus: Bool { true }
    public override var preferredFocusView: View? { items.first { $0.isEnabled && !$0.isStatic }.flatMap { rows[$0.id] } }

    /// The row showing the item `id`, for a screen that puts the focus on a particular one.
    public func row(id: String) -> View? {
        rows[id]
    }

    public func setItems(_ newItems: [RowItem]) {
        items = newItems
        var next: [String: RowView] = [:]
        for item in newItems {
            let row = rows[item.id] ?? RowView(item: item)
            row.item = item
            row.isSelected = item.id == selectedID
            row.onSelect = { [weak self] item in self?.onSelect?(item) }
            row.onFocus = { [weak self] item in self?.onFocus?(item) }
            row.onContextMenu = { [weak self] item, anchor in self?.onContextMenu?(item, anchor) ?? false }
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

import Foundation
import Kiln

/// View data of a settings-style row (`TVRowItem`): icon well, title, subtitle, value and an accessory. A toggle is a
/// row whose value reads On or Off and flips on Select, as on tvOS.
public struct RowItem: Hashable, Sendable {
    public enum Accessory: Hashable, Sendable {
        case none, chevron, checkmark
        /// A switch, on or off, that the row's activation flips (a desk's settings).
        case toggle(Bool)
        /// A desk's choice set in place: its options side by side where they fit in two fifths of the row, otherwise a
        /// pop-up button naming the chosen one that opens them as a dropdown.
        case choices([String], selected: Int?)
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

    /// A setting with a few options: chosen in place on a desk (`Accessory.choices`), the chosen one as the value with a
    /// chevron that opens them on a couch.
    @MainActor
    public static func choice(id: String, title: String, subtitle: String? = nil, options: [String], selected: Int?, symbol: Symbol? = nil,
                              isEnabled: Bool = true) -> RowItem {
        if Theme.current.density == .desk {
            return RowItem(id: id, title: title, subtitle: subtitle, symbol: symbol, accessory: .choices(options, selected: selected), isEnabled: isEnabled)
        }
        let value = selected.flatMap { options.indices.contains($0) ? options[$0] : nil }
        return RowItem(id: id, title: title, subtitle: subtitle, value: value, symbol: symbol, accessory: .chevron, isEnabled: isEnabled)
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
            laidOutChoices = nil
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
    /// A click on a choice row's control: the option clicked among those side by side, or nil for the pop-up button, with
    /// where the button sits in the window for the dropdown to hang from.
    public var onChoose: ((RowItem, Int?, Rect) -> Void)?
    /// The row is one of a card's (a desk's settings): its plates sit inset with the card's smaller corners, and focus
    /// does not lift it out of the card.
    public var isInGroup = false { didSet { if isInGroup != oldValue { setNeedsDisplay() } } }

    private var focus = Animated(0)
    private var hover = Animated(0)
    private var press = Animated(0)
    private var pressedByPointer = false
    /// The part of a choice control the primary button went down on, which a release there chooses.
    private var pressedZone: ChoiceZone?
    /// The option under the pointer among those side by side.
    private var hoveredOption: Int?
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
        if case .choices(let options, let selected?) = item.accessory, options.indices.contains(selected) { return options[selected] }
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

    /// A part of a choice control.
    private enum ChoiceZone: Equatable {
        case option(Int)
        case popUp
    }

    /// A choice control laid out for one width: its options side by side, or the pop-up button.
    private struct ChoiceControl {
        let frame: Rect
        let options: [TextLayout]
        let selectedOptions: [TextLayout]
        let segments: [Rect]
        let popUp: TextLayout?

        var isPopUp: Bool { popUp != nil }
    }

    private var laidOutChoices: (width: Float, scale: Float, control: ChoiceControl)?

    private static var choiceHeight: Float { Theme.current.metrics.tv(56) }

    /// The choice control for a row `width` wide, flush with the row's trailing inset and centred on it: the options side
    /// by side, each segment as wide as its label (never narrower than a short word's), when up to four fit in two fifths
    /// of the row, otherwise a pop-up button.
    private func choiceControl(width: Float) -> ChoiceControl? {
        guard case .choices(let options, let selected) = item.accessory, !options.isEmpty else { return nil }
        let scale = rasterScale
        if let laidOutChoices, laidOutChoices.width == width, laidOutChoices.scale == scale { return laidOutChoices.control }
        let metrics = Theme.current.metrics
        let type = Theme.current.type
        let height = Self.choiceHeight
        let trailing = width - metrics.rowInset
        let plain = options.map { TextLayout($0, font: type.body, maxLines: 1, scale: scale) }
        let bold = options.map { TextLayout($0, font: type.cardTitle, maxLines: 1, scale: scale) }
        let pad = metrics.tv(36)
        let widths = bold.map { max($0.size.width + pad, metrics.tv(110)) }
        let inset = metrics.tv(5)
        let total = widths.reduce(0, +) + inset * 2
        let control: ChoiceControl
        if total <= max(width * 0.4, metrics.tv(420)), options.count <= 4 {
            let frame = Rect(x: trailing - total, y: 0, width: total, height: height)
            var x = frame.x + inset
            let segments = widths.map { segmentWidth in
                defer { x += segmentWidth }
                return Rect(x: x, y: inset, width: segmentWidth, height: height - inset * 2)
            }
            control = ChoiceControl(frame: frame, options: plain, selectedOptions: bold, segments: segments, popUp: nil)
        } else {
            let title = selected.flatMap { options.indices.contains($0) ? options[$0] : nil } ?? ""
            let glyph = metrics.symbolAccessory
            let cap = max(metrics.tv(160), width * 0.4 - glyph - pad * 1.5)
            let layout = TextLayout(title, font: type.callout, maxWidth: cap, maxLines: 1, scale: scale)
            let buttonWidth = layout.size.width + glyph + pad * 1.5
            let frame = Rect(x: trailing - buttonWidth, y: 0, width: buttonWidth, height: height)
            control = ChoiceControl(frame: frame, options: [], selectedOptions: [], segments: [], popUp: layout)
        }
        laidOutChoices = (width, scale, control)
        return control
    }

    /// The control's frame placed on the row's middle.
    private func choiceFrame(_ control: ChoiceControl) -> Rect {
        Rect(x: control.frame.x, y: ((bounds.height - control.frame.height) / 2).rounded(), width: control.frame.width, height: control.frame.height)
    }

    /// Which part of the choice control `point` (row points) is on; a pop-up row answers for the whole row.
    private func choiceZone(at point: Point) -> ChoiceZone? {
        guard let control = choiceControl(width: bounds.width) else { return nil }
        if control.isPopUp { return .popUp }
        let top = choiceFrame(control).y
        for (index, segment) in control.segments.enumerated() {
            let placed = Rect(x: segment.x, y: segment.y + top, width: segment.width, height: segment.height)
            if placed.contains(point) { return .option(index) }
        }
        return nil
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
        } else if let control = choiceControl(width: width) {
            textWidth -= control.frame.width + metrics.tv(32)
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
        pressedZone = nil
        press.set(0, animation: .press)
        if hoveredOption != nil {
            hoveredOption = nil
            setNeedsDisplay()
        }
        update()
    }

    public override func pointerMoved(to point: Point) {
        guard case .option(let index)? = choiceZone(at: point) else {
            if hoveredOption != nil {
                hoveredOption = nil
                setNeedsDisplay()
            }
            return
        }
        guard hoveredOption != index else { return }
        hoveredOption = index
        setNeedsDisplay()
    }

    public override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        if button == .secondary, canBecomeFocused, let onContextMenu {
            window?.focus.focus(self, animated: true, reveal: false)
            let origin = frameInWindow.origin
            return onContextMenu(item, Rect(x: origin.x + point.x, y: origin.y + point.y, width: 1, height: 1))
        }
        guard button == .primary, canBecomeFocused else { return false }
        if case .choices = item.accessory {
            pressedZone = choiceZone(at: point)
            window?.focus.focus(self, animated: true, reveal: false)
            if pressedZone == .popUp {
                press.set(1, animation: .press)
                startAnimating()
            }
            setNeedsDisplay()
            return true
        }
        pressedByPointer = true
        press.set(1, animation: .press)
        startAnimating()
        return true
    }

    public override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        guard button == .primary else { return }
        press.set(0, animation: .press)
        startAnimating()
        if let zone = pressedZone {
            pressedZone = nil
            setNeedsDisplay()
            guard inside, choiceZone(at: point) == zone, let control = choiceControl(width: bounds.width) else { return }
            let frame = frameInWindow
            let placed = choiceFrame(control)
            let anchor = Rect(x: frame.x + placed.x, y: frame.y + placed.y, width: placed.width, height: placed.height)
            switch zone {
            case .option(let index): onChoose?(item, index, anchor)
            case .popUp: onChoose?(item, nil, anchor)
            }
            return
        }
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
        let lift = isInGroup ? 1 : 1 + (metrics.rowScale(width: rect.width) - 1) * focus.value
        let pressDip = isInGroup ? 1 - (1 - metrics.pressedScale) * 0.4 * press.value : 1 - (1 - metrics.pressedScale) * press.value
        let scale = lift * pressDip
        let plate = isInGroup ? Rect(x: rect.x + metrics.tv(8), y: rect.y + metrics.tv(4), width: rect.width - metrics.tv(16), height: rect.height - metrics.tv(8)) : rect
        let plateRadius = isInGroup ? metrics.radiusS : metrics.radiusM
        context.faded(item.isEnabled ? 1 : 0.45) { faded in
            faded.transformed(scale: scale, about: rect.center) { inner in
                if focus.value > 0.01 {
                    if !isInGroup {
                        inner.shadow(rect, radius: metrics.radiusM, blur: metrics.focusShadowRadius, offsetY: metrics.focusShadowOffset,
                                     opacity: metrics.focusShadowOpacity * focus.value)
                    }
                    inner.fill(plate, radius: plateRadius, color: palette.focusFill.withAlpha(focus.value))
                }
                if isSelected && focus.value < 0.99 {
                    inner.fill(plate, radius: plateRadius, color: palette.accent.withAlpha(0.2 * (1 - focus.value)))
                }
                if hover.value > 0.01 {
                    inner.fill(plate, radius: plateRadius, color: palette.label.withAlpha(0.07 * hover.value))
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
                case .choices(_, let selected):
                    if let control = choiceControl(width: rect.width) {
                        drawChoices(control, selected: selected, context: &inner)
                        trailing -= control.frame.width + metrics.tv(32)
                    }
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

extension RowView {
    /// A choice control: the options side by side in a recessed track, the chosen one on a raised plate in the accent's
    /// text colour and the one under the pointer lit; or the pop-up button, the chosen option beside up and down chevrons.
    /// On the focused row's light plate it takes the plate's dark ink.
    private func drawChoices(_ control: ChoiceControl, selected: Int?, context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        let palette = theme.palette
        let amount = focus.value
        let ink = palette.label.mixed(with: palette.onFocusFill, amount: amount)
        let secondary = palette.labelSecondary.mixed(with: palette.onFocusFillSecondary, amount: amount)
        let frame = choiceFrame(control)
        if let layout = control.popUp {
            let pressed = pressedZone == .popUp
            context.fill(frame, radius: metrics.radiusS, color: ink.withAlpha(pressed ? 0.16 : hover.value > 0.01 ? 0.11 : 0.08))
            context.stroke(frame, radius: metrics.radiusS, width: 1, color: ink.withAlpha(0.14))
            let pad = metrics.tv(22)
            let glyph = metrics.symbolAccessory
            let textY = frame.y + ((frame.height - layout.size.height) / 2 * rasterScale).rounded() / rasterScale
            context.text(layout, at: Point(x: frame.x + pad, y: textY), color: ink)
            context.symbol("chevron.up.chevron.down", in: Rect(x: frame.maxX - pad * 0.7 - glyph, y: frame.midY - glyph / 2, width: glyph, height: glyph),
                           color: secondary)
            return
        }
        context.fill(frame, radius: metrics.radiusS, color: ink.withAlpha(0.08))
        for (index, segment) in control.segments.enumerated() {
            let placed = Rect(x: segment.x, y: segment.y + frame.y, width: segment.width, height: segment.height)
            let chosen = index == selected
            if chosen {
                let raised = (palette.appearance == .light ? Color.white : palette.surfaceHigh).mixed(with: .white, amount: amount)
                context.shadow(placed, radius: metrics.radiusS - metrics.tv(4), blur: 4, offsetY: 1, opacity: 0.25)
                context.fill(placed, radius: metrics.radiusS - metrics.tv(4), color: raised)
            } else if hoveredOption == index || pressedZone == .option(index) {
                context.fill(placed, radius: metrics.radiusS - metrics.tv(4), color: ink.withAlpha(pressedZone == .option(index) ? 0.14 : 0.08))
            }
            let layout = chosen ? control.selectedOptions[index] : control.options[index]
            let origin = Point(x: (placed.midX - layout.size.width / 2).rounded(), y: placed.y + ((placed.height - layout.size.height) / 2 * rasterScale).rounded() / rasterScale)
            let color = chosen ? palette.accentText.mixed(with: Palette.light.accentText, amount: amount) : secondary
            context.text(layout, at: origin, color: color)
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
    /// A click on a choice row's control (`RowView.onChoose`).
    public var onChoose: ((RowItem, Int?, Rect) -> Void)?
    public var columnWidth: Float?
    /// The rows on one card with hairlines between them (a desk's settings), instead of each on its own.
    public var isGrouped = false {
        didSet {
            guard isGrouped != oldValue else { return }
            rows.values.forEach { $0.isInGroup = isGrouped }
            setNeedsLayout()
            setNeedsDisplay()
        }
    }
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
            row.onChoose = { [weak self] item, index, anchor in self?.onChoose?(item, index, anchor) }
            row.isInGroup = isGrouped
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

    /// The room between rows, and around them inside a card.
    private var spacing: Float { isGrouped ? 0 : Theme.current.metrics.rowSpacing }
    private var cardPadding: Float { isGrouped ? Theme.current.metrics.tv(6) : 0 }

    public override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        let width = min(columnWidth ?? metrics.wideColumn, size.width - metrics.sideMargin * 2)
        let heights = items.compactMap { rows[$0.id]?.sizeThatFits(Size(width: width, height: 0)).height }
        let total = heights.reduce(0, +) + Float(max(heights.count - 1, 0)) * spacing + cardPadding * 2 + metrics.tv(24)
        return Size(width: size.width, height: total)
    }

    public override func layoutSubviews() {
        let area = column
        var y = cardPadding
        for item in items {
            guard let row = rows[item.id] else { continue }
            let height = row.sizeThatFits(Size(width: area.width, height: 0)).height
            row.frame = Rect(x: area.x, y: y, width: area.width, height: height)
            y += height + spacing
        }
        if isGrouped { setNeedsDisplay() }
    }

    /// A card's surface under its rows, with a hairline between each two from the text's edge to the trailing inset.
    public override func draw(_ context: inout DrawContext) {
        guard isGrouped, !items.isEmpty else { return }
        let metrics = Theme.current.metrics
        let palette = Theme.current.palette
        let placed = items.compactMap { rows[$0.id] }
        guard let first = placed.first, let last = placed.last else { return }
        let card = Rect(x: first.frame.x, y: first.frame.y - cardPadding, width: first.frame.width, height: last.frame.maxY - first.frame.y + cardPadding * 2)
        context.fill(card, radius: metrics.radiusM, color: palette.surface)
        let scale = window?.scale ?? 1
        let hairline = 1 / scale
        for (index, row) in placed.enumerated() where index > 0 {
            let leading = row.item.symbol != nil || row.item.brand != nil ? metrics.rowInset + metrics.rowIconWell + metrics.tv(32) : metrics.rowInset
            let y = ((row.frame.y) * scale).rounded() / scale - hairline / 2
            context.fill(Rect(x: card.x + leading, y: y, width: card.width - leading - metrics.rowInset, height: hairline), color: palette.separator)
        }
    }
}

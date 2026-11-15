import Foundation
import Kiln

/// Liquid Glass recipes for controls, with the opaque raised surface under Reduce Transparency.
@MainActor
public enum GlassStyle {
    /// Text on glass of `tone` (0 dark glass, 1 light glass): light labels on dark glass, dark on light.
    public static func label(tone: Float) -> Color {
        Color(hex: 0xF6F3EF).mixed(with: Color(hex: 0x1A1816), amount: tone)
    }

    public static func secondaryLabel(tone: Float) -> Color {
        Color(hex: 0xF6F3EF, srgbAlpha: 0.68).mixed(with: Color(hex: 0x1A1816, srgbAlpha: 0.66), amount: tone)
    }

    /// A glass capsule (or rounded rectangle) filling `rect`, lit from `light`.
    public static func capsule(in rect: Rect, radius: Float? = nil, light: Point, press: Float = 0, pill: Rect? = nil,
                               floating: Bool = false, tone: Float? = nil, context: inout DrawContext) {
        let theme = Theme.current
        let cornerRadius = radius ?? rect.height / 2
        if theme.reduceTransparency {
            context.fill(rect, radius: cornerRadius, color: theme.palette.surfaceRaised)
            if let pill { context.fill(pill, radius: pill.height / 2, color: theme.palette.surfaceHigh) }
            return
        }
        var element = LiquidGlass(
            primary: .init(centerX: rect.midX, centerY: rect.midY, halfWidth: rect.width / 2, halfHeight: rect.height / 2, radius: cornerRadius),
            lightX: light.x, lightY: light.y
        )
        let metrics = theme.metrics
        element.rimWidth = min(metrics.tv(22), rect.height * 0.32)
        element.refraction = min(metrics.tv(18), rect.height * 0.22)
        element.press = press
        element.tone = tone
        element.shadowOpacity = floating ? 0.28 : 0.12
        element.shadowOffsetY = floating ? metrics.tv(10) : metrics.tv(3)
        element.shadowRadius = floating ? metrics.tv(26) : metrics.tv(8)
        if let pill {
            element.pill = .init(centerX: pill.midX, centerY: pill.midY, halfWidth: pill.width / 2, halfHeight: pill.height / 2, radius: pill.height / 2)
        }
        context.glass(element)
    }
}

/// Light or dark glass for one element, flipped with hysteresis from the luminance behind it, so the glass and its label
/// change together and never flicker over moving video.
@MainActor
public struct GlassTone {
    public private(set) var animated = Animated(0)
    private var isLight = false

    public init() {}

    public var value: Float { animated.value }

    /// Reads what lies under `rect`; returns whether the tone flipped (the owner then animates).
    public mutating func update(_ context: DrawContext, rect: Rect) -> Bool {
        guard let luminance = context.backdropLuminance(of: rect) else { return false }
        let light = isLight ? luminance > 0.28 : luminance > 0.42
        guard light != isLight else { return false }
        isLight = light
        animated.set(light ? 1 : 0, animation: .fade)
        return true
    }

    public mutating func advance(_ dt: Float) -> Bool { animated.advance(dt) }
}

/// A button (`TVButton`): primary is the filled ember pill, glass the Liquid Glass capsule, plain a tinted text button,
/// and a chip a glass or ember capsule that shows a selection. Focused glass turns into the light pill with dark text
/// that tvOS 26 draws; the pointer lifts it and the light follows the pointer across the glass.
@MainActor
public final class ButtonView: View {
    public enum Style: Hashable, Sendable {
        case primary, glass, plain
        case chip(selected: Bool)
    }

    public var style: Style { didSet { if style != oldValue { setNeedsLayout(); setNeedsDisplay() } } }
    public var title: String? { didSet { if title != oldValue { superview?.setNeedsLayout(); setNeedsDisplay() } } }
    public var symbol: Symbol? { didSet { if symbol != oldValue { superview?.setNeedsLayout(); setNeedsDisplay() } } }
    public var symbolTrailing: Bool
    /// Drawn faint while not selected (a season the server lacks).
    public var isDimmed = false { didSet { setNeedsDisplay() } }
    public var isEnabled = true { didSet { setNeedsDisplay() } }
    public var onPress: (() -> Void)?
    public var onContextMenu: ((Point?) -> Void)?

    private var lift = Animated(0)
    private var tone = GlassTone()
    private var focus = Animated(0)
    private var hover = Animated(0)
    private var press = Animated(0)
    private var light = Point(x: 0, y: 0)
    private var pressedByPointer = false

    public init(style: Style, title: String?, symbol: Symbol? = nil, symbolTrailing: Bool = false) {
        self.style = style
        self.title = title
        self.symbol = symbol
        self.symbolTrailing = symbolTrailing
        super.init()
    }

    public override var canBecomeFocused: Bool { isEnabled }
    public override var accessibilityLabel: String? { title }
    public override var overdraw: Float { Theme.current.metrics.tv(40) }

    private var font: Font {
        switch style {
        case .primary, .glass, .plain: Theme.current.type.control
        case .chip: Theme.current.type.cardTitle
        }
    }

    private var height: Float {
        let metrics = Theme.current.metrics
        switch style {
        case .primary, .glass: return metrics.primaryControlHeight
        case .chip: return metrics.chipHeight
        case .plain: return metrics.plainControlHeight
        }
    }

    private var inset: Float {
        let metrics = Theme.current.metrics
        switch style {
        case .primary, .glass: return metrics.controlInset
        case .chip: return metrics.chipInset
        case .plain: return metrics.plainControlInset
        }
    }

    private var rasterScale: Float { window?.scale ?? 1 }

    private var titleLayout: TextLayout? {
        guard let title, !title.isEmpty else { return nil }
        return TextLayout(title, font: font, maxWidth: max(frame.width - inset * 2 - symbolWidth, 1), scale: rasterScale)
    }

    private var symbolSize: Float { font.size * 1.05 }
    private var symbolWidth: Float { symbol == nil ? 0 : symbolSize + (title == nil ? 0 : Theme.current.metrics.tv(16)) }

    public override func sizeThatFits(_ size: Size) -> Size {
        let text = title.map { TextLayout($0, font: font, scale: rasterScale).size.width } ?? 0
        let width = (text + symbolWidth + inset * 2).rounded(.up)
        return Size(width: title == nil ? height : max(width, height), height: height)
    }

    // MARK: Interaction

    private var isLifted: Bool { (isFocused && (window?.isFocusVisible ?? false)) || isHovered }

    /// Keyboard focus turns glass into the light pill; the pointer only lifts it and lights the glass under it, so the
    /// pill never chases the mouse.
    private func updateLift() {
        let focused = isFocused && (window?.isFocusVisible ?? false)
        lift.set(isLifted ? 1 : 0, animation: .focus)
        focus.set(focused ? 1 : 0, animation: .focus)
        hover.set(isHovered && !focused ? 1 : 0, animation: .focus)
        startAnimating()
    }

    public override func focusDidChange(focused: Bool, animated: Bool) { updateLift() }
    public override func focusVisibilityDidChange(_ visible: Bool) { if isFocused { updateLift() } }
    public override func pointerEntered() { updateLift() }

    public override func pointerExited() {
        pressedByPointer = false
        press.set(0, animation: .press)
        updateLift()
    }

    public override func pointerMoved(to point: Point) {
        light = point
        setNeedsDisplay()
    }

    public override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard isEnabled else { return true }
        if button == .secondary, let onContextMenu {
            onContextMenu(point)
            return true
        }
        guard button == .primary else { return false }
        pressedByPointer = true
        press.set(1, animation: .press)
        startAnimating()
        return true
    }

    public override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        guard button == .primary else { return }
        press.set(0, animation: .press)
        startAnimating()
        if pressedByPointer && inside && isEnabled { onPress?() }
        pressedByPointer = false
    }

    public override func activate() {
        guard isEnabled else { return }
        press.reset(1)
        press.set(0, animation: .press)
        startAnimating()
        onPress?()
    }

    public override func showContextMenu(at point: Point?) -> Bool {
        guard let onContextMenu else { return false }
        onContextMenu(point)
        return true
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [lift.advance(dt), focus.advance(dt), hover.advance(dt), press.advance(dt), tone.advance(dt)].contains(true)
        setNeedsDisplay()
        return moving
    }

    // MARK: Drawing

    public override func draw(_ context: inout DrawContext) {
        let palette = Theme.current.palette
        let metrics = Theme.current.metrics
        let rect = bounds
        let scale = (1 + (metrics.focusScale - 1) * lift.value) * (1 - (1 - metrics.pressedScale) * press.value)
        let lightPoint = isHovered ? light : Point(x: rect.midX, y: rect.minY - rect.height)
        let faded: Float = !isEnabled ? 0.4 : (isDimmed && style != .chip(selected: true)) ? 0.5 : 1
        context.faded(faded) { inner in
            inner.transformed(scale: scale, about: rect.center) { drawn in
                let foreground: Color
                switch style {
                case .primary, .chip(selected: true):
                    if lift.value > 0.01 {
                        drawn.shadow(rect, radius: rect.height / 2, blur: metrics.focusShadowRadius * 0.6, offsetY: metrics.focusShadowOffset * 0.5,
                                     opacity: 0.4 * lift.value)
                    }
                    drawn.fill(rect, radius: rect.height / 2, color: palette.accent)
                    drawn.glow(in: rect, radius: rect.height / 2, center: lightPoint, glowRadius: rect.width * 0.8,
                               color: Color.white.withAlpha(0.18 * lift.value + 0.1 * press.value))
                    foreground = palette.onAccent
                case .glass, .chip(selected: false):
                    if tone.update(drawn, rect: rect) { startAnimating() }
                    GlassStyle.capsule(in: rect, light: lightPoint, press: press.value + 0.5 * hover.value, tone: tone.value, context: &drawn)
                    if focus.value > 0.01 {
                        drawn.fill(rect, radius: rect.height / 2, color: palette.focusFill.withAlpha(focus.value))
                    }
                    foreground = GlassStyle.label(tone: tone.value).mixed(with: palette.onFocusFill, amount: focus.value)
                case .plain:
                    if lift.value > 0.01 {
                        drawn.fill(rect, radius: rect.height / 2, color: palette.label.withAlpha(0.12 * lift.value))
                    }
                    foreground = palette.accentText
                }
                drawLabel(in: rect, color: foreground, context: &drawn)
            }
        }
    }

    private func drawLabel(in rect: Rect, color: Color, context: inout DrawContext) {
        let layout = titleLayout
        let textWidth = layout?.size.width ?? 0
        let total = textWidth + symbolWidth
        var x = ((rect.width - total) / 2 * rasterScale).rounded() / rasterScale
        let gap = Theme.current.metrics.tv(16)
        if let symbol, !symbolTrailing {
            context.symbol(symbol, in: Rect(x: x, y: rect.midY - symbolSize / 2, width: symbolSize, height: symbolSize), color: color)
            x += symbolSize + (layout == nil ? 0 : gap)
        }
        if let layout {
            let y = ((rect.height - layout.size.height) / 2 * rasterScale).rounded() / rasterScale
            context.text(layout, at: Point(x: x, y: y), color: color)
            x += layout.size.width + gap
        }
        if let symbol, symbolTrailing {
            let small = symbolSize * 0.8
            context.symbol(symbol, in: Rect(x: x, y: rect.midY - small / 2, width: small, height: small), color: color)
        }
    }
}

/// A row of chips (filters, seasons, recent searches) that scrolls sideways and keeps the focused chip in view.
@MainActor
public final class ChipRowView: View {
    public struct Chip: Hashable, Sendable {
        public var id: String
        public var title: String
        public var symbol: Symbol?
        public var isSelected: Bool
        public var isDimmed: Bool

        public init(id: String, title: String, symbol: Symbol? = nil, isSelected: Bool = false, isDimmed: Bool = false) {
            self.id = id
            self.title = title
            self.symbol = symbol
            self.isSelected = isSelected
            self.isDimmed = isDimmed
        }
    }

    public var onSelect: ((Chip) -> Void)?
    public let scroller = ScrollView(axis: .horizontal)
    private var chips: [Chip] = []
    private var buttons: [String: ButtonView] = [:]

    public override init(frame: Rect = .zero) {
        super.init(frame: frame)
        scroller.showsIndicator = false
        addSubview(scroller)
    }

    public override var remembersFocus: Bool { true }
    public override var preferredFocusView: View? {
        chips.first(where: \.isSelected).flatMap { buttons[$0.id] } ?? chips.first.flatMap { buttons[$0.id] }
    }

    public func setChips(_ newChips: [Chip]) {
        chips = newChips
        var next: [String: ButtonView] = [:]
        for chip in newChips {
            let button = buttons[chip.id] ?? ButtonView(style: .chip(selected: chip.isSelected), title: chip.title, symbol: chip.symbol)
            button.style = .chip(selected: chip.isSelected)
            button.title = chip.title
            button.symbol = chip.symbol
            button.isDimmed = chip.isDimmed
            button.onPress = { [weak self] in self?.onSelect?(chip) }
            if button.superview == nil { scroller.addSubview(button) }
            next[chip.id] = button
        }
        for (id, button) in buttons where next[id] == nil { button.removeFromSuperview() }
        buttons = next
        setNeedsLayout()
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: Theme.current.metrics.chipHeight + Theme.current.metrics.tv(48))
    }

    public override func layoutSubviews() {
        let metrics = Theme.current.metrics
        scroller.frame = bounds
        scroller.revealInsets = EdgeInsets(leading: metrics.sideMargin, trailing: metrics.sideMargin)
        var x = metrics.sideMargin
        let y = (frame.height - metrics.chipHeight) / 2
        for chip in chips {
            guard let button = buttons[chip.id] else { continue }
            let size = button.sizeThatFits(Size(width: 1000, height: metrics.chipHeight))
            button.frame = Rect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + metrics.tv(24)
        }
        scroller.contentLength = x - metrics.tv(24) + metrics.sideMargin
    }
}

import Foundation
import Kiln

/// The Statistics colours (`StatsStyle`): the accent and its brighter peak, the six-step heat ramp, the orange family for
/// categories and the ramp a heat strip draws on the ember gradient. Alphas are the Apple TV's, tuned for sRGB blending.
@MainActor
public enum StatsStyle {
    public static var accent: Color { Theme.current.palette.accent }
    public static let accentBright = Color(hex: 0xFFB340)

    /// Six-stop heat ramp; level 0 is an empty day.
    public static func heat(_ level: Int) -> Color {
        let palette = Theme.current.palette
        switch max(0, min(5, level)) {
        case 0: return palette.surfaceHigh
        case 1: return palette.accent.withSRGBAlpha(0.28)
        case 2: return palette.accent.withSRGBAlpha(0.46)
        case 3: return palette.accent.withSRGBAlpha(0.66)
        case 4: return palette.accent.withSRGBAlpha(0.86)
        default: return accentBright
        }
    }

    /// Distinct orange-family tints for donut slices and other categories.
    public static func categorical(_ index: Int) -> Color {
        let colors: [Color] = [
            Theme.current.palette.accent,
            Color(srgbRed: 1.0, green: 0.72, blue: 0.20),
            Color(srgbRed: 0.95, green: 0.44, blue: 0.13),
            Color(srgbRed: 1.0, green: 0.85, blue: 0.35),
            Color(srgbRed: 0.83, green: 0.33, blue: 0.20),
            Color(srgbRed: 0.99, green: 0.58, blue: 0.36),
            Color(srgbRed: 0.72, green: 0.45, blue: 0.20),
            Color(srgbRed: 1.0, green: 0.67, blue: 0.50),
        ]
        return colors[((index % colors.count) + colors.count) % colors.count]
    }

    /// Six steps for a heat strip on the ember gradient; index 0 is an empty day.
    public static let emberStripRamp: [Color] = [
        Color.white.withSRGBAlpha(0.14),
        Color(srgbRed: 1, green: 0.72, blue: 0.30).withSRGBAlpha(0.38),
        Color(srgbRed: 1, green: 0.72, blue: 0.30).withSRGBAlpha(0.56),
        Color(srgbRed: 1, green: 0.75, blue: 0.35).withSRGBAlpha(0.76),
        Color(srgbRed: 1, green: 0.78, blue: 0.43).withSRGBAlpha(0.92),
        Color(hex: 0xFFE0A6),
    ]

    /// The coverage that gives `color` the look of `alpha` under sRGB blending, for alphas baked into a shape.
    static func coverage(_ alpha: Float, of color: Color) -> Float {
        color.withSRGBAlpha(alpha).alpha
    }

    /// Cubic ease-out, the curve the Apple TV charts grow on.
    static func easeOut(_ t: Float) -> Float {
        let clamped = min(1, max(0, t))
        return 1 - pow(1 - clamped, 3)
    }
}

/// A Statistics card that takes focus (`TVStatsPanel`), so the keyboard can walk the whole page: a surface with a hairline,
/// an optional headline and trailing accessory, and one content view. Focus lifts it, raises the surface and lays a sheen
/// over it; Return or a click runs `onSelect` when there is one, and a right-click or the Menu key `onContextMenu`.
@MainActor
public final class StatsPanelView: View {
    public var onSelect: (() -> Void)?
    /// The panel's menu (right-click or the Menu key), with the pointer's place in the window when it came from a click.
    public var onContextMenu: ((Point?) -> Void)?

    public let content: View
    private let title: String?
    private let accessory: View?
    private let isFlush: Bool
    private var focus = Animated(0)

    /// `flush` drops the inner margins, for content with its own (a tile, a Wrapped card).
    public init(title: String? = nil, accessory: View? = nil, content: View, flush: Bool = false) {
        self.title = title
        self.accessory = accessory
        self.content = content
        isFlush = flush
        super.init()
        addSubview(content)
        if let accessory { addSubview(accessory) }
    }

    public override var canBecomeFocused: Bool { true }
    public override var cursor: Cursor { onSelect == nil ? .default : .pointer }

    private var inset: Float { isFlush ? 0 : Theme.current.metrics.tv(40) }
    private var spacing: Float { Theme.current.metrics.tv(28) }

    private func titleLayout(width: Float) -> TextLayout? {
        guard let title, !title.isEmpty else { return nil }
        return TextLayout(title, font: Theme.current.type.headline, maxWidth: width, maxLines: 2, scale: window?.scale ?? 1)
    }

    private func headerHeight(width: Float) -> Float {
        guard let layout = titleLayout(width: width) else { return 0 }
        let accessoryHeight = accessory?.sizeThatFits(Size(width: width, height: 0)).height ?? 0
        return max(layout.size.height, accessoryHeight) + spacing
    }

    /// A flush panel is as wide as its content asks to be; the others fill the width given.
    public override func sizeThatFits(_ size: Size) -> Size {
        let inner = size.width - inset * 2
        let body = content.sizeThatFits(Size(width: inner, height: size.height))
        return Size(width: isFlush ? body.width : size.width, height: inset * 2 + headerHeight(width: inner) + body.height)
    }

    public override func layoutSubviews() {
        let inner = frame.width - inset * 2
        let header = headerHeight(width: inner)
        if let accessory {
            let size = accessory.sizeThatFits(Size(width: inner, height: 0))
            let titleHeight = max(header - spacing, 0)
            accessory.frame = Rect(x: inset + inner - size.width, y: inset + ((titleHeight - size.height) / 2).rounded(), width: size.width, height: size.height)
        }
        content.frame = Rect(x: inset, y: inset + header, width: inner, height: max(0, frame.height - inset * 2 - header))
    }

    public override func activate() {
        onSelect?()
    }

    public override func showContextMenu(at point: Point?) -> Bool {
        guard let onContextMenu else { return false }
        onContextMenu(point.map { transformToWindow.apply($0) })
        return true
    }

    public override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard button == .secondary, let onContextMenu else { return button == .primary && onSelect != nil }
        window?.focus.focus(self, animated: true, reveal: false)
        onContextMenu(transformToWindow.apply(point))
        return true
    }

    public override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        if button == .primary, inside { onSelect?() }
    }

    public override func focusDidChange(focused: Bool, animated: Bool) { update() }
    public override func focusVisibilityDidChange(_ visible: Bool) { if isFocused { update() } }

    private func update() {
        let shown = isFocused && (window?.isFocusVisible ?? false)
        focus.set(shown ? 1 : 0, animation: .focus)
        startAnimating()
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = focus.advance(dt)
        let metrics = Theme.current.metrics
        let growth = min(metrics.focusScale, 1 + 2 * metrics.tv(18) / max(frame.width, 1))
        scale = 1 + (growth - 1) * focus.value
        setNeedsDisplay()
        return moving
    }

    public override func draw(_ context: inout DrawContext) {
        let theme = Theme.current
        let palette = theme.palette
        let radius = theme.metrics.radiusM
        if focus.value > 0.001 {
            context.shadow(bounds, radius: radius, blur: theme.metrics.focusShadowRadius, offsetY: theme.metrics.focusShadowOffset,
                           opacity: theme.metrics.focusShadowOpacity * focus.value)
        }
        context.fill(bounds, radius: radius, color: palette.surface)
        if focus.value > 0.001 { context.fill(bounds, radius: radius, color: palette.surfaceHigh.withAlpha(focus.value)) }
        context.stroke(bounds, radius: radius, width: 1, color: palette.separator)
        if let layout = titleLayout(width: frame.width - inset * 2) {
            context.text(layout, at: Point(x: inset, y: inset), color: palette.label)
        }
    }

    public override func drawOverlay(_ context: inout DrawContext) {
        guard focus.value > 0.001 else { return }
        context.gradient(bounds, axis: .diagonal, stops: [(0, Color.white.withSRGBAlpha(0.16 * focus.value)), (0.8, Color.white.withAlpha(0))],
                         radius: Theme.current.metrics.radiusM)
    }
}

import Foundation
import Kiln

/// The ember gradient behind the hero and the Year in Review card: dark brown at the top left to burnt orange at the bottom
/// right.
@MainActor
enum Ember {
    static func fill(_ rect: Rect, radius: Float, in context: inout DrawContext) {
        let palette = Theme.current.palette
        context.gradient(rect, axis: .diagonal, stops: [(0, palette.emberTop), (0.55, palette.emberMid), (1, palette.emberBottom)], radius: radius)
    }
}

/// The last 78 days as a three-row strip of ember squares, one column per week-third (`HeatStripView`). With `cellWidth`
/// the strip has that width; without one the columns share whatever width it is given.
@MainActor
public final class HeatStripView: View {
    public static let rows = 3
    public static let columns = 26

    public var levels: [Int] = [] { didSet { setNeedsDisplay() } }
    private let cellWidth: Float?
    private let cellHeight: Float
    private let gap: Float
    private let corner: Float

    /// The hero's strip: square cells.
    public static func hero() -> HeatStripView {
        let metrics = Theme.current.metrics
        return HeatStripView(cellWidth: metrics.tv(26), cellHeight: metrics.tv(26), gap: metrics.tv(7), corner: metrics.tv(6))
    }

    /// The Year in Review card's strip: flat cells across the card.
    public static func card() -> HeatStripView {
        let metrics = Theme.current.metrics
        return HeatStripView(cellWidth: nil, cellHeight: metrics.tv(14), gap: metrics.tv(5), corner: metrics.tv(3))
    }

    init(cellWidth: Float?, cellHeight: Float, gap: Float, corner: Float) {
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.gap = gap
        self.corner = corner
        super.init()
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        let rows = Float(Self.rows)
        let height = rows * cellHeight + (rows - 1) * gap
        guard let cellWidth else { return Size(width: size.width, height: height) }
        let columns = Float(Self.columns)
        return Size(width: columns * cellWidth + (columns - 1) * gap, height: height)
    }

    public override func draw(_ context: inout DrawContext) {
        let columns = Float(Self.columns)
        let width = cellWidth ?? (frame.width - (columns - 1) * gap) / columns
        guard width > 0 else { return }
        let ramp = StatsStyle.emberStripRamp
        for (index, level) in levels.enumerated() {
            let column = Float(index / Self.rows)
            let row = Float(index % Self.rows)
            let cell = Rect(x: column * (width + gap), y: row * (cellHeight + gap), width: width, height: cellHeight)
            context.fill(cell, radius: corner, color: ramp[max(0, min(ramp.count - 1, level))])
        }
    }
}

/// The ember hero of Statistics (`StatsHeroView`): the verdict eyebrow, a huge figure that counts up with its unit, two
/// quiet lines, and the heat strip of the last 78 days on the right. It takes focus so the keyboard can start the page
/// there; focus shows as an accent rim around it.
@MainActor
public final class StatsHeroView: View {
    private var eyebrow = ""
    private var value = 0
    private var unit = ""
    private var detail = ""
    private var since = ""
    private var startValue = 0
    private var count = Animated(1)
    private var rim = Animated(0)
    private let strip = HeatStripView.hero()

    public init() {
        super.init()
        addSubview(strip)
    }

    public override var canBecomeFocused: Bool { true }
    public override var accessibilityRole: AccessibilityRole { .label }
    public override var accessibilityExposesChildren: Bool { false }
    public override var accessibilityLabel: String? {
        [eyebrow, "\(value) \(unit)", detail, since].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Fills the hero; with `animate` the figure counts up from where it stood over about a second.
    public func configure(eyebrow: String, value: Int, unit: String, detail: String, since: String, stripLevels: [Int], animate: Bool) {
        self.eyebrow = eyebrow
        startValue = animate ? 0 : value
        self.value = value
        self.unit = unit
        self.detail = detail
        self.since = since
        strip.levels = stripLevels
        if animate && value != 0 {
            count.reset(0)
            count.set(1, animation: .timed(duration: 0.9, curve: .linear))
            startAnimating()
        } else {
            count.reset(1)
        }
        superview?.setNeedsLayout()
        setNeedsLayout()
        setNeedsDisplay()
    }

    private var metrics: Metrics { Theme.current.metrics }
    private var inset: Float { metrics.tv(48) }
    private var rasterScale: Float { window?.scale ?? 1 }

    private var numberFont: Font {
        var font = Font(size: metrics.tv(150), weight: .heavy)
        font.monospacedDigits = true
        return font
    }

    private static let grouping: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        return formatter
    }()

    private var shownValue: Int {
        startValue + Int((Float(value - startValue) * StatsStyle.easeOut(count.value)).rounded())
    }

    private func textWidth(_ width: Float) -> Float {
        let stripWidth = strip.sizeThatFits(Size(width: width, height: 0)).width
        return max(metrics.tv(400), width - inset * 2 - stripWidth - metrics.tv(48))
    }

    private struct Lines {
        var eyebrow: TextLayout?
        var number: TextLayout
        var numberWidth: Float
        var unit: TextLayout?
        var detail: TextLayout?
        var since: TextLayout?
    }

    private func lines(width: Float) -> Lines {
        let type = Theme.current.type
        let column = textWidth(width)
        var eyebrowFont = type.caption2
        eyebrowFont.letterSpacing = 1
        let widest = Self.grouping.string(from: NSNumber(value: value)) ?? "\(value)"
        let shown = Self.grouping.string(from: NSNumber(value: shownValue)) ?? "\(shownValue)"
        return Lines(
            eyebrow: eyebrow.isEmpty ? nil : TextLayout(eyebrow.uppercased(), font: eyebrowFont, maxWidth: column, maxLines: 2, scale: rasterScale),
            number: TextLayout(count.value < 1 ? shown : widest, font: numberFont, scale: rasterScale),
            numberWidth: TextLayout(widest, font: numberFont, scale: rasterScale).size.width,
            unit: unit.isEmpty ? nil : TextLayout(unit, font: Font(size: metrics.tv(52), weight: .semibold), scale: rasterScale),
            detail: detail.isEmpty ? nil : TextLayout(detail, font: type.subheadline, maxWidth: column, maxLines: 3, scale: rasterScale),
            since: since.isEmpty ? nil : TextLayout(since, font: type.footnote, maxWidth: column, maxLines: 2, scale: rasterScale)
        )
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        let text = lines(width: size.width)
        var height = inset * 2 + text.number.size.height
        if let eyebrow = text.eyebrow { height += eyebrow.size.height + metrics.tv(14) }
        for line in [text.detail, text.since].compactMap({ $0 }) { height += line.size.height + metrics.tv(6) }
        let stripHeight = strip.sizeThatFits(Size(width: size.width, height: 0)).height + inset * 2
        return Size(width: size.width, height: max(height, stripHeight))
    }

    public override func layoutSubviews() {
        let size = strip.sizeThatFits(Size(width: frame.width, height: 0))
        strip.frame = Rect(x: frame.width - inset - size.width, y: ((frame.height - size.height) / 2).rounded(), width: size.width, height: size.height)
    }

    public override func focusDidChange(focused: Bool, animated: Bool) { updateRim() }
    public override func focusVisibilityDidChange(_ visible: Bool) { if isFocused { updateRim() } }

    private func updateRim() {
        rim.set(isFocused && (window?.isFocusVisible ?? false) ? 1 : 0, animation: .focus)
        startAnimating()
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [count.advance(dt), rim.advance(dt)].contains(true)
        setNeedsDisplay()
        return moving
    }

    public override func draw(_ context: inout DrawContext) {
        let palette = Theme.current.palette
        let radius = metrics.radiusL
        Ember.fill(bounds, radius: radius, in: &context)
        context.stroke(bounds, radius: radius, width: metrics.tv(2), color: palette.artHairline)
        let text = lines(width: frame.width)
        var y = inset
        if let eyebrow = text.eyebrow {
            context.text(eyebrow, at: Point(x: inset, y: y), color: palette.emberEyebrow)
            y += eyebrow.size.height + metrics.tv(14)
        }
        context.text(text.number, at: Point(x: inset, y: y), color: palette.onArt)
        if let unit = text.unit {
            let x = inset + max(text.numberWidth, text.number.size.width) + metrics.tv(16)
            context.text(unit, at: Point(x: x, y: y + text.number.baseline - unit.baseline), color: palette.onArtMuted)
        }
        y += text.number.size.height
        if let detail = text.detail {
            y += metrics.tv(6)
            context.text(detail, at: Point(x: inset, y: y), color: palette.onArtMuted)
            y += detail.size.height
        }
        if let since = text.since {
            y += metrics.tv(6)
            context.text(since, at: Point(x: inset, y: y), color: Color.white.withSRGBAlpha(0.65))
        }
    }

    public override func drawOverlay(_ context: inout DrawContext) {
        guard rim.value > 0.001 else { return }
        let outset = metrics.tv(14)
        context.stroke(bounds.insetBy(-outset, -outset), radius: metrics.radiusL + outset, width: metrics.tv(3),
                       color: Theme.current.palette.accent.withAlpha(rim.value))
    }

    public override var overdraw: Float { metrics.tv(20) }
}

/// "less ▪▪▪ more" beside the Activity card's title (`StatsHeatLegendView`).
@MainActor
public final class StatsHeatLegendView: View {
    private var swatch: Float { Theme.current.metrics.tv(20) }

    private func captions() -> (less: TextLayout, more: TextLayout) {
        let font = Theme.current.type.footnote
        let scale = window?.scale ?? 1
        return (TextLayout(Strings.text("less"), font: font, scale: scale), TextLayout(Strings.text("more"), font: font, scale: scale))
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        let text = captions()
        let width = text.less.size.width + text.more.size.width + swatch * 3 + metrics.tv(4) * 2 + metrics.tv(12) * 2
        return Size(width: width, height: max(swatch, text.less.size.height))
    }

    public override func draw(_ context: inout DrawContext) {
        let metrics = Theme.current.metrics
        let text = captions()
        let secondary = Theme.current.palette.labelSecondary
        var x: Float = 0
        context.text(text.less, at: Point(x: x, y: ((frame.height - text.less.size.height) / 2).rounded()), color: secondary)
        x += text.less.size.width + metrics.tv(12)
        for level in [0, 2, 5] {
            context.fill(Rect(x: x, y: ((frame.height - swatch) / 2).rounded(), width: swatch, height: swatch), radius: metrics.tv(4), color: StatsStyle.heat(level))
            x += swatch + metrics.tv(4)
        }
        x += metrics.tv(12) - metrics.tv(4)
        context.text(text.more, at: Point(x: x, y: ((frame.height - text.more.size.height) / 2).rounded()), color: secondary)
    }
}

/// The Year in Review card on You (`YearInReviewCardView`): the caption, a Statistics link, this year's figure with its
/// unit, a line of detail and the heat strip of the last 78 days, on the ember gradient. It takes focus and lifts; Return
/// runs `onSelect`.
@MainActor
public final class YearInReviewCardView: View {
    public var onSelect: (() -> Void)?

    private var caption = ""
    private var primary = ""
    private var unit = ""
    private var detail = ""
    private let strip = HeatStripView.card()
    private var focus = Animated(0)

    public init() {
        super.init()
        addSubview(strip)
    }

    public override var canBecomeFocused: Bool { true }
    public override var accessibilityExposesChildren: Bool { false }
    public override var accessibilityLabel: String? {
        [caption, "\(primary) \(unit)", detail].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    public func configure(caption: String, primary: String, unit: String, detail: String, strip levels: [Int]) {
        self.caption = caption
        self.primary = primary
        self.unit = unit
        self.detail = detail
        strip.levels = levels
        superview?.setNeedsLayout()
        setNeedsLayout()
        setNeedsDisplay()
    }

    private var metrics: Metrics { Theme.current.metrics }
    private var inset: Float { metrics.tv(32) }

    private struct Lines {
        var caption: TextLayout
        var link: TextLayout
        var primary: TextLayout
        var unit: TextLayout?
        var detail: TextLayout?
    }

    private func lines(width: Float) -> Lines {
        let scale = window?.scale ?? 1
        let column = width - inset * 2
        var captionFont = Font(size: metrics.tv(23), weight: .bold)
        captionFont.letterSpacing = 1.5
        return Lines(
            caption: TextLayout(caption, font: captionFont, maxWidth: column * 0.6, scale: scale),
            link: TextLayout(Strings.text("Statistics"), font: Font(size: metrics.tv(25), weight: .regular), scale: scale),
            primary: TextLayout(primary, font: Font(size: metrics.tv(76), weight: .heavy), scale: scale),
            unit: unit.isEmpty ? nil : TextLayout(unit, font: Font(size: metrics.tv(48), weight: .semibold), scale: scale),
            detail: detail.isEmpty ? nil : TextLayout(detail, font: Font(size: metrics.tv(31), weight: .regular), maxWidth: column, maxLines: 2, scale: scale)
        )
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        let text = lines(width: size.width)
        var height = inset + max(text.caption.size.height, text.link.size.height) + metrics.tv(16) + text.primary.size.height
        if let detail = text.detail { height += metrics.tv(16) + detail.size.height }
        height += metrics.tv(24) + strip.sizeThatFits(Size(width: size.width - inset * 2, height: 0)).height + metrics.tv(32)
        return Size(width: size.width, height: height)
    }

    public override func layoutSubviews() {
        let height = strip.sizeThatFits(Size(width: frame.width - inset * 2, height: 0)).height
        strip.frame = Rect(x: inset, y: frame.height - metrics.tv(32) - height, width: frame.width - inset * 2, height: height)
    }

    public override func activate() { onSelect?() }
    public override func focusDidChange(focused: Bool, animated: Bool) { update() }
    public override func focusVisibilityDidChange(_ visible: Bool) { if isFocused { update() } }

    private func update() {
        focus.set(isFocused && (window?.isFocusVisible ?? false) ? 1 : 0, animation: .focus)
        startAnimating()
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = focus.advance(dt)
        scale = 1 + (metrics.rowScale(width: frame.width) - 1) * focus.value
        setNeedsDisplay()
        return moving
    }

    public override func draw(_ context: inout DrawContext) {
        let palette = Theme.current.palette
        let radius = metrics.radiusM
        if focus.value > 0.001 {
            context.shadow(bounds, radius: radius, blur: metrics.focusShadowRadius, offsetY: metrics.focusShadowOffset,
                           opacity: metrics.focusShadowOpacity * focus.value)
        }
        Ember.fill(bounds, radius: radius, in: &context)
        context.stroke(bounds, radius: radius, width: 1, color: palette.artHairline)
        let text = lines(width: frame.width)
        let topRow = max(text.caption.size.height, text.link.size.height)
        context.text(text.caption, at: Point(x: inset, y: inset + ((topRow - text.caption.size.height) / 2).rounded()), color: palette.emberEyebrow)
        let chevron = metrics.tv(22)
        let linkX = frame.width - inset - chevron - metrics.tv(8) - text.link.size.width
        context.text(text.link, at: Point(x: linkX, y: inset + ((topRow - text.link.size.height) / 2).rounded()), color: palette.onArtSecondary)
        context.symbol("chevron.right", in: Rect(x: frame.width - inset - chevron, y: inset + ((topRow - chevron) / 2).rounded(), width: chevron, height: chevron),
                       color: palette.onArtSecondary)
        var y = inset + topRow + metrics.tv(16)
        context.text(text.primary, at: Point(x: inset, y: y), color: palette.onArt)
        if let unit = text.unit {
            context.text(unit, at: Point(x: inset + text.primary.size.width + metrics.tv(16), y: y + text.primary.baseline - unit.baseline), color: palette.onArtMuted)
        }
        y += text.primary.size.height
        if let detail = text.detail {
            context.text(detail, at: Point(x: inset, y: y + metrics.tv(16)), color: Color.white.withSRGBAlpha(0.82))
        }
    }

    public override func drawOverlay(_ context: inout DrawContext) {
        guard focus.value > 0.001 else { return }
        context.gradient(bounds, axis: .diagonal, stops: [(0, Color.white.withSRGBAlpha(0.16 * focus.value)), (0.8, Color.white.withAlpha(0))],
                         radius: metrics.radiusM)
    }

    public override var overdraw: Float { metrics.focusShadowRadius * 2 }
}

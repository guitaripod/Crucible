import Foundation

/// A type recipe in points: Inter at a size and weight, as `Theme.Font` and `TVFont` name them.
public struct Font: Hashable, Sendable {
    public enum Weight: Int, Sendable {
        case regular = 400, medium = 500, semibold = 600, bold = 700, heavy = 800
    }

    public var size: Float
    public var weight: Weight
    public var italic = false
    public var letterSpacing: Float = 0
    public var monospacedDigits = false

    public init(size: Float, weight: Weight = .regular) {
        self.size = size
        self.weight = weight
    }

    /// How Inter's optical size follows the point size: 1 at a desk, lower on a TV, where 29 point body text is read
    /// from across the room as 17 point text is at arm's length.
    nonisolated(unsafe) public static var opticalScale: Float = 1

    var opticalSize: Double { Double(min(max(size * Self.opticalScale, 14), 32)) }
}

/// Text measured for a width and line limit at the window's scale; draws itself through the renderer's texture cache.
@MainActor
public struct TextLayout {
    public let text: String
    public let font: Font
    public let maxWidth: Float
    public let maxLines: Int
    public let alignment: TextStyle.Alignment
    public let scale: Float
    let style: TextStyle
    let metrics: TextMetrics

    /// Lays out `text` no wider than `maxWidth` points (0 for unbounded) in at most `maxLines` lines (0 for any), ending
    /// in an ellipsis when cut.
    public init(_ text: String, font: Font, maxWidth: Float = 0, maxLines: Int = 1, alignment: TextStyle.Alignment = .leading, scale: Float) {
        self.text = text
        self.font = font
        self.maxWidth = maxWidth
        self.maxLines = maxLines
        self.alignment = alignment
        self.scale = scale
        var style = TextStyle(sizePixels: Double(font.size * scale), weight: font.weight.rawValue, opticalSize: font.opticalSize,
                              maxWidthPixels: maxWidth > 0 ? Int((maxWidth * scale).rounded(.down)) : 0, maxLines: maxLines, alignment: alignment)
        style.italic = font.italic
        style.letterSpacingPixels = Double(font.letterSpacing * scale)
        self.style = style
        metrics = text.isEmpty ? TextMetrics(width: 0, height: 0, lines: 0, baseline: 0, truncated: false) : TextRenderer.measure(text, style: style)
    }

    /// The size in points (whole pixels at this scale).
    public var size: Size { Size(width: Float(metrics.width) / scale, height: Float(metrics.height) / scale) }

    /// The first line's baseline, in points from the top.
    public var baseline: Float { Float(metrics.baseline) / scale }

    public var lineCount: Int { metrics.lines }

    public var isTruncated: Bool { metrics.truncated }

    func texture(renderer: TextRenderer) -> Texture? {
        guard !text.isEmpty else { return nil }
        return (try? renderer.texture(for: text, style: style))?.texture
    }

}

/// One run of text: a label, title or caption.
@MainActor
open class Label: View {
    public var text: String { didSet { if text != oldValue { invalidate() } } }
    public var font: Font { didSet { if font != oldValue { invalidate() } } }
    public var color: Color { didSet { if color != oldValue { setNeedsDisplay() } } }
    public var maxLines: Int { didSet { if maxLines != oldValue { invalidate() } } }
    public var alignment: TextStyle.Alignment = .leading { didSet { if alignment != oldValue { invalidate() } } }

    private var cached: TextLayout?

    public init(_ text: String = "", font: Font, color: Color, maxLines: Int = 1) {
        self.text = text
        self.font = font
        self.color = color
        self.maxLines = maxLines
        super.init()
    }

    private func invalidate() {
        cached = nil
        superview?.setNeedsLayout()
        setNeedsDisplay()
    }

    private var rasterScale: Float { window?.scale ?? 1 }

    /// The layout for `width` points, reused while text, font, width and scale stay the same.
    public func layout(width: Float) -> TextLayout {
        if let cached, cached.maxWidth == width, cached.scale == rasterScale { return cached }
        let layout = TextLayout(text, font: font, maxWidth: width, maxLines: maxLines, alignment: alignment, scale: rasterScale)
        cached = layout
        return layout
    }

    open override func sizeThatFits(_ size: Size) -> Size {
        guard !text.isEmpty else { return .zero }
        return layout(width: size.width).size
    }

    open override func draw(_ context: inout DrawContext) {
        guard !text.isEmpty, frame.width > 0 else { return }
        let laidOut = layout(width: frame.width)
        var x: Float = 0
        switch alignment {
        case .leading: x = 0
        case .center: x = ((frame.width - laidOut.size.width) / 2 * rasterScale).rounded() / rasterScale
        case .trailing: x = frame.width - laidOut.size.width
        }
        if alignment != .leading && laidOut.lineCount > 1 { x = 0 }
        context.text(laidOut, at: Point(x: x, y: 0), color: color)
    }

    open override var accessibilityLabel: String? { text }
}

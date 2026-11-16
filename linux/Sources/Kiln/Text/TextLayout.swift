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
    var style: TextStyle
    let metrics: TextMetrics

    /// Lays out `text` no wider than `maxWidth` points (0 for unbounded) in at most `maxLines` lines (0 for any), ending
    /// in an ellipsis when cut. `markup` reads `text` as Pango markup; `inColor` draws in colour, which text with emoji in
    /// it does by itself.
    public init(_ text: String, font: Font, maxWidth: Float = 0, maxLines: Int = 1, alignment: TextStyle.Alignment = .leading, scale: Float,
                markup: Bool = false, inColor: Bool = false) {
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
        style.markup = markup
        style.inColor = inColor || Self.hasColorGlyphs(text)
        self.style = style
        metrics = text.isEmpty ? TextMetrics(width: 0, height: 0, lines: 0, baseline: 0, truncated: false) : TextRenderer.measure(text, style: style)
    }

    /// The same layout drawing only the characters in `ranges` (UTF-16 offsets, as `NSRange` gives them), for tinting a
    /// search match over the full text; nil when nothing matches.
    public func showingOnly(utf16 ranges: [(location: Int, length: Int)]) -> TextLayout? {
        let utf16 = Array(text.utf16)
        let bytes = ranges.compactMap { range -> Range<Int>? in
            guard range.length > 0, range.location >= 0, range.location + range.length <= utf16.count else { return nil }
            let prefix = String(decoding: utf16[0..<range.location], as: UTF16.self).utf8.count
            let match = String(decoding: utf16[range.location..<(range.location + range.length)], as: UTF16.self).utf8.count
            return prefix..<(prefix + match)
        }
        guard !bytes.isEmpty else { return nil }
        var shown = self
        shown.style.visibleByteRanges = bytes
        return shown
    }

    /// The size in points (whole pixels at this scale).
    public var size: Size { Size(width: Float(metrics.width) / scale, height: Float(metrics.height) / scale) }

    /// The first line's baseline, in points from the top.
    public var baseline: Float { Float(metrics.baseline) / scale }

    public var lineCount: Int { metrics.lines }

    public var isTruncated: Bool { metrics.truncated }

    /// Where the caret stands before the character at `index` of `text` (a UTF-8 byte offset): its top left and height, in
    /// points from the layout's top left.
    public func caret(atUTF8 index: Int) -> Rect {
        let caret = TextRenderer.caret(text, style: style, byteIndex: index)
        return Rect(x: Float(caret.x) / scale, y: Float(caret.y) / scale, width: 0, height: Float(caret.height) / scale)
    }

    /// What a selection of the UTF-8 bytes `range` of `text` paints: a rectangle or more for every line it touches, in points
    /// from the layout's top left.
    public func rects(forUTF8 range: Range<Int>) -> [Rect] {
        TextRenderer.rects(text, style: style, start: range.lowerBound, end: range.upperBound).map {
            Rect(x: Float($0.x) / scale, y: Float($0.y) / scale, width: Float($0.width) / scale, height: Float($0.height) / scale)
        }
    }

    /// The UTF-8 byte offset into `text` of the character boundary nearest `point` (in points from the layout's top left).
    public func utf8Index(at point: Point) -> Int {
        TextRenderer.index(text, style: style, x: Int((point.x * scale).rounded()), y: Int((point.y * scale).rounded()))
    }

    /// Whether the layout draws in colour (`inColor`) rather than as a coverage mask.
    public var isInColor: Bool { style.inColor }

    /// The style this layout's text takes rasterised at `pixelScale` pixels per point (a lifted card's or row's), with the
    /// same text and line breaks: glyph widths do not grow exactly with the size, so the width gets a little slack, or a
    /// title that just fit would be cut short with an ellipsis while lifted.
    func style(atScale pixelScale: Float) -> TextStyle {
        var scaled = style
        let factor = Double(pixelScale / scale)
        scaled.sizePixels *= factor
        scaled.letterSpacingPixels *= factor
        let width = maxWidth * pixelScale
        scaled.maxWidthPixels = maxWidth > 0 ? Int(width.rounded(.up) + 2 + width * 0.01) : 0
        return scaled
    }

    func texture(renderer: TextRenderer) -> Texture? {
        guard !text.isEmpty else { return nil }
        return (try? renderer.texture(for: text, style: style))?.texture
    }

    func colorTexture(renderer: TextRenderer, color: Color) -> Texture? {
        guard !text.isEmpty else { return nil }
        return try? renderer.colorTexture(for: text, style: style, color: color)
    }

    /// Whether `text` has a character the colour emoji font draws (an emoji shown as one, or one asked for with the emoji
    /// variation selector), so the layout draws in colour instead of as a silhouette; plain text stays a coverage mask.
    nonisolated static func hasColorGlyphs(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where scalar.value >= 0x2000 {
            if scalar.value == 0xFE0F || scalar.properties.isEmojiPresentation { return true }
        }
        return false
    }

    /// `text` with the characters Pango markup gives meaning to (`&`, `<`, `>`, quotes) written as entities.
    public nonisolated static func escapingMarkup(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
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

    /// Read as a heading (a shelf's or a section's title), so a screen reader can jump between them.
    public var isHeading = false

    open override var accessibilityRole: AccessibilityRole { text.isEmpty ? .none : isHeading ? .heading : .label }
}

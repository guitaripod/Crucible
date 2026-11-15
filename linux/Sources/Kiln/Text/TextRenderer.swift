import CKilnText
import Foundation

/// How a run of text is set: Inter at a pixel size and weight, wrapped to a width, cut to a number of lines with a tail
/// ellipsis, as the tvOS type recipes ask (`TVFont`).
public struct TextStyle: Hashable, Sendable {
    public enum Alignment: Int32, Sendable { case leading = 0, center = 1, trailing = 2 }

    public var sizePixels: Double
    public var weight: Int
    public var italic = false
    public var maxWidthPixels = 0
    public var maxLines = 0
    public var alignment: Alignment = .leading
    public var letterSpacingPixels = 0.0
    /// Inter's optical size axis (14 for text up to 32 for display): the point size the style was designed at.
    public var opticalSize: Double

    public init(sizePixels: Double, weight: Int, opticalSize: Double, maxWidthPixels: Int = 0, maxLines: Int = 0, alignment: Alignment = .leading) {
        self.sizePixels = sizePixels
        self.weight = weight
        self.opticalSize = opticalSize
        self.maxWidthPixels = maxWidthPixels
        self.maxLines = maxLines
        self.alignment = alignment
    }
}

public struct TextMetrics: Sendable {
    public let width: Int
    public let height: Int
    public let lines: Int
    public let baseline: Int
    public let truncated: Bool
}

/// Lays text out with Pango and rasterises it into 8-bit coverage textures, cached by text and style, so a label is
/// rendered once and drawn as a tinted quad every frame after.
@MainActor
public final class TextRenderer {
    /// Upright text is set in static cuts of Inter, Text below the middle of its optical-size axis and Display from
    /// there (as SF switches from Text to Display), because Cairo re-applies a variable font's coordinates whenever text
    /// switches between instances, which cost half a millisecond a label. Italics keep the variable font.
    static func family(for style: TextStyle) -> (name: String, opticalSize: Double) {
        if style.italic { return ("Inter Variable", style.opticalSize) }
        return (style.opticalSize >= 23 ? "Kiln Inter Display" : "Kiln Inter", 0)
    }

    private struct Key: Hashable {
        let text: String
        let style: TextStyle
    }

    private let gpu: GPU
    private var cache: [Key: (texture: Texture, metrics: TextMetrics, frame: Int)] = [:]
    private var frame = 0

    public init(gpu: GPU) {
        self.gpu = gpu
        Self.registerFonts()
    }

    private static let fontsRegistered: Bool = {
        guard let directory = Bundle.module.url(forResource: "Fonts", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return false }
        return files.filter { $0.pathExtension == "ttf" }.allSatisfy { kiln_text_register_font($0.path) }
    }()

    public static func registerFonts() {
        _ = fontsRegistered
    }

    /// Loads every font in `fonts` at `scale` and rasterises its common glyphs, one font per main-queue turn, so the
    /// first screens draw their labels without stopping for font matching (about 2 ms a font) or cold glyph caches.
    public static func warmUp(_ fonts: [Font], scale: Float) {
        var pending = Array(Set(fonts))
        func next() {
            guard let font = pending.popLast() else { return }
            let layout = TextLayout(warmUpSample, font: font, scale: scale)
            let stride = (layout.metrics.width + 3) & ~3
            if layout.metrics.width > 0, layout.metrics.height > 0 {
                var pixels = [UInt8](repeating: 0, count: stride * layout.metrics.height)
                _ = withRawStyle(layout.style) { raw in
                    warmUpSample.withCString {
                        kiln_text_render($0, &raw, &pixels, Int32(layout.metrics.width), Int32(layout.metrics.height), Int32(stride))
                    }
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { next() } }
        }
        next()
    }

    private static let warmUpSample = "AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz 0123456789 ·:–…&'’!?,."

    private struct MeasureKey: Hashable {
        let text: String
        let style: TextStyle
    }

    private static var measured: [MeasureKey: TextMetrics] = [:]

    /// Lays `text` out and returns its size, from a cache of recent layouts: views measure their text every layout and
    /// often every frame, and Pango's shaping is the expensive part.
    public static func measure(_ text: String, style: TextStyle) -> TextMetrics {
        let key = MeasureKey(text: text, style: style)
        if let hit = measured[key] { return hit }
        if measured.count > 8192 { measured.removeAll(keepingCapacity: true) }
        let result = layOut(text, style: style)
        measured[key] = result
        return result
    }

    private static func layOut(_ text: String, style: TextStyle) -> TextMetrics {
        registerFonts()
        return withRawStyle(style) { raw in
            let measured = text.withCString { kiln_text_measure($0, &raw) }
            return TextMetrics(width: Int(measured.width), height: Int(measured.height), lines: Int(measured.lines),
                               baseline: Int(measured.baseline), truncated: measured.truncated)
        }
    }

    /// The text's coverage texture and metrics, from the cache when this text and style were drawn recently.
    public func texture(for text: String, style: TextStyle) throws(RenderError) -> (texture: Texture, metrics: TextMetrics)? {
        let key = Key(text: text, style: style)
        if let cached = cache[key] {
            cache[key]?.frame = frame
            return (cached.texture, cached.metrics)
        }
        let started = Window.now()
        let metrics = Self.measure(text, style: style)
        guard metrics.width > 0, metrics.height > 0 else { return nil }
        FrameTrace.rasterised += 1
        let stride = (metrics.width + 3) & ~3
        var pixels = [UInt8](repeating: 0, count: stride * metrics.height)
        let rendered = Self.withRawStyle(style) { raw in
            text.withCString { kiln_text_render($0, &raw, &pixels, Int32(metrics.width), Int32(metrics.height), Int32(stride)) }
        }
        let rasterised = Window.now()
        FrameTrace.rasterTime += rasterised - started
        guard rendered else { return nil }
        let texture = try gpu.texture(width: metrics.width, height: metrics.height, format: .r8, renderable: false)
        _ = pixels.withUnsafeBytes { texture.upload($0.baseAddress!, rowBytes: stride) }
        FrameTrace.textureTime += Window.now() - rasterised
        cache[key] = (texture, metrics, frame)
        return (texture, metrics)
    }

    /// Drops labels not drawn for a few seconds of frames; called once per frame.
    public func endFrame() {
        frame += 1
        guard frame % 600 == 0 else { return }
        cache = cache.filter { frame - $0.value.frame < 600 }
    }

    private static func withRawStyle<R>(_ style: TextStyle, _ body: (inout kiln_text_style) -> R) -> R {
        let face = family(for: style)
        return face.name.withCString { family in
            var raw = kiln_text_style(
                family: family,
                size_px: style.sizePixels,
                optical_size: face.opticalSize,
                weight: Int32(style.weight),
                italic: style.italic,
                max_width_px: Int32(style.maxWidthPixels),
                max_lines: Int32(style.maxLines),
                alignment: style.alignment.rawValue,
                letter_spacing_px: style.letterSpacingPixels
            )
            return body(&raw)
        }
    }
}

import CKilnImage
import Foundation

/// An SF Symbol name as Core and the Apple TV screens use it (`"play.fill"`), drawn from the open Lucide icon the map
/// in `Resources/Symbols/map.json` names for it.
public struct Symbol: Hashable, Sendable, ExpressibleByStringLiteral {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    public init(stringLiteral value: String) {
        name = value
    }
}

/// Reads the symbol map and rasterises its icons with librsvg into coverage textures at the pixel size they are drawn
/// at, so they are sharp at every density, cached like text.
@MainActor
public final class SymbolRenderer {
    struct Entry: Decodable {
        let icon: String
        let fill: Bool
        let knockout: Bool
        let glyph: String?

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer().decode(String.self) {
                icon = single
                fill = false
                knockout = false
                glyph = nil
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            icon = try container.decode(String.self, forKey: .icon)
            fill = try container.decodeIfPresent(Bool.self, forKey: .fill) ?? false
            knockout = try container.decodeIfPresent(Bool.self, forKey: .knockout) ?? false
            glyph = try container.decodeIfPresent(String.self, forKey: .glyph)
        }

        enum CodingKeys: String, CodingKey { case icon, fill, knockout, glyph }
    }

    private struct Key: Hashable {
        let symbol: Symbol
        let pixelSize: Int
    }

    static let directory = Bundle.module.url(forResource: "Symbols", withExtension: nil)

    /// Every SF Symbol name the map covers.
    static let map: [String: Entry] = {
        guard let url = directory?.appendingPathComponent("map.json"), let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }()

    public static func has(_ symbol: Symbol) -> Bool { map[symbol.name] != nil }

    private let gpu: GPU
    private var cache: [Key: Texture] = [:]

    public init(gpu: GPU) {
        self.gpu = gpu
    }

    public func texture(for symbol: Symbol, pixelSize: Int) -> Texture? {
        guard pixelSize > 0 else { return nil }
        let key = Key(symbol: symbol, pixelSize: pixelSize)
        if let cached = cache[key] { return cached }
        guard let document = Self.document(for: symbol, pixelSize: pixelSize) else { return nil }
        var stride: Int32 = 0
        var error = [CChar](repeating: 0, count: 128)
        let pixels = document.withUnsafeBytes { buffer in
            kiln_svg_render_mask(buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), buffer.count, Int32(pixelSize), &stride, &error, error.count)
        }
        guard let pixels else { return nil }
        defer { kiln_image_free(pixels) }
        guard let texture = try? gpu.texture(width: pixelSize, height: pixelSize, format: .r8, renderable: false) else { return nil }
        _ = texture.upload(pixels, rowBytes: Int(stride))
        cache[key] = texture
        return texture
    }

    /// The SVG to rasterise: the Lucide icon with its stroke weighted for the size (Lucide draws 2 units on 24 for every
    /// size; small symbols read better a little heavier, large ones lighter), filled for `.fill` names, or a filled disc
    /// with its inner glyph cut out for the badge-like `.circle.fill` names.
    static func document(for symbol: Symbol, pixelSize: Int) -> Data? {
        guard let entry = map[symbol.name], let directory else { return nil }
        guard let source = try? String(contentsOf: directory.appendingPathComponent("\(entry.icon).svg"), encoding: .utf8) else { return nil }
        let strokeWidth = pixelSize <= 20 ? 2.25 : pixelSize >= 64 ? 1.75 : 2.0
        var svg = source.replacingOccurrences(of: "stroke-width=\"2\"", with: "stroke-width=\"\(strokeWidth)\"")
        if entry.fill {
            svg = svg.replacingOccurrences(of: "fill=\"none\"", with: "fill=\"black\"")
        }
        if entry.knockout {
            svg = knockout(svg, glyphSource: entry.glyph.flatMap { try? String(contentsOf: directory.appendingPathComponent("\($0).svg"), encoding: .utf8) },
                           strokeWidth: strokeWidth)
        }
        return Data(svg.utf8)
    }

    /// The icon's first shape filled solid, with the rest of the icon (or another glyph scaled into it) cut through it.
    private static func knockout(_ svg: String, glyphSource: String?, strokeWidth: Double) -> String {
        let shapes = elements(of: svg)
        guard let outline = shapes.first else { return svg }
        let inner: [String]
        if let glyphSource {
            inner = ["<g transform=\"translate(12 12) scale(0.55) translate(-12 -12)\">"] + elements(of: glyphSource) + ["</g>"]
        } else {
            inner = Array(shapes.dropFirst())
        }
        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">
        <defs><mask id="cut" maskUnits="userSpaceOnUse" x="0" y="0" width="24" height="24">
        <rect width="24" height="24" fill="white"/>
        <g fill="none" stroke="black" stroke-width="\(strokeWidth)" stroke-linecap="round" stroke-linejoin="round">\(inner.joined(separator: "\n"))</g>
        </mask></defs>
        <g mask="url(#cut)" fill="black" stroke="black" stroke-width="\(strokeWidth)" stroke-linejoin="round">\(outline)</g>
        </svg>
        """
    }

    /// The drawing elements of a Lucide SVG, one per line in its source.
    private static func elements(of svg: String) -> [String] {
        svg.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            ["<path", "<circle", "<rect", "<line", "<polyline", "<polygon", "<ellipse"].contains { line.hasPrefix($0) }
        }
    }
}

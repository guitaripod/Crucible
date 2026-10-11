#if DEBUG
import CrucibleDesign
import UIKit

/// Draws the gallery's posters, backdrops and avatars at runtime so the design review needs neither
/// assets nor a server. A path such as `fixture://backdrop/salt-flats` selects the kind and the seed.
enum TVGalleryArt {
    static let scheme = "fixture://"

    static let provider: TVImagePipeline.Provider = { path, pixelWidth, kind in
        guard path.hasPrefix(scheme) else { return nil }
        let parts = path.dropFirst(scheme.count).split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let width = CGFloat(max(pixelWidth, 64))
        switch parts[0] {
        case "backdrop": return backdrop(seed: parts[1], size: CGSize(width: width, height: (width * 9 / 16).rounded()))
        case "person": return portrait(seed: parts[1], size: CGSize(width: width, height: width))
        default: return poster(seed: parts[1], size: CGSize(width: width, height: (width * 1.5).rounded()))
        }
    }

    private struct Palette {
        let sky: [UIColor]
        let sun: UIColor
        let ridge: UIColor
        let isBright: Bool
    }

    private static let palettes: [String: Palette] = [
        "salt-flats": Palette(
            sky: [UIColor(hex: 0xFFFFFF), UIColor(hex: 0xF3E9D2), UIColor(hex: 0xE8D9B5)],
            sun: UIColor(hex: 0xFFFDF4),
            ridge: UIColor(hex: 0xF7F1E1),
            isBright: true
        ),
        "lighthouse": Palette(
            sky: [UIColor(hex: 0x16314F), UIColor(hex: 0x3B5F82), UIColor(hex: 0xE9A25A)],
            sun: UIColor(hex: 0xFFD08A),
            ridge: UIColor(hex: 0x0C1A2B),
            isBright: false
        ),
        "orchard": Palette(
            sky: [UIColor(hex: 0x2E4A2B), UIColor(hex: 0x7C9A4E), UIColor(hex: 0xF0C36A)],
            sun: UIColor(hex: 0xFFE9A8),
            ridge: UIColor(hex: 0x1B2D18),
            isBright: false
        ),
        "neon": Palette(
            sky: [UIColor(hex: 0x1A0B33), UIColor(hex: 0x7A1F7A), UIColor(hex: 0xFF5C8A)],
            sun: UIColor(hex: 0xFFB3CC),
            ridge: UIColor(hex: 0x0B0518),
            isBright: false
        ),
        "ember": Palette(
            sky: [UIColor(hex: 0x240A05), UIColor(hex: 0x8A2E10), UIColor(hex: 0xFF9F0A)],
            sun: UIColor(hex: 0xFFD27A),
            ridge: UIColor(hex: 0x120503),
            isBright: false
        ),
    ]

    private static let paletteOrder = ["lighthouse", "orchard", "neon", "ember", "salt-flats"]

    private static func palette(for seed: String) -> Palette {
        if let named = palettes[seed] { return named }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let key = paletteOrder[Int(hash % UInt64(paletteOrder.count - 1))]
        return palettes[key] ?? palettes["lighthouse"]!
    }

    static func backdrop(seed: String, size: CGSize) -> UIImage {
        let palette = palette(for: seed)
        return render(size) { context, rect in
            drawSky(palette, in: context, rect: rect)
            drawSun(palette, in: context, rect: rect, center: CGPoint(x: rect.width * 0.72, y: rect.height * 0.42), radius: rect.height * 0.16)
            drawRidges(palette, in: context, rect: rect)
        }
    }

    static func poster(seed: String, size: CGSize) -> UIImage {
        let palette = palette(for: seed)
        let title = seed.replacingOccurrences(of: "-", with: " ").uppercased()
        return render(size) { context, rect in
            drawSky(palette, in: context, rect: rect)
            drawSun(palette, in: context, rect: rect, center: CGPoint(x: rect.width * 0.5, y: rect.height * 0.36), radius: rect.width * 0.26)
            drawRidges(palette, in: context, rect: rect)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: rect.width * 0.11, weight: .heavy),
                .foregroundColor: palette.isBright ? UIColor(hex: 0x3B2F1C) : UIColor.white,
                .paragraphStyle: paragraph,
                .kern: rect.width * 0.012,
            ]
            let inset = rect.width * 0.1
            title.draw(in: CGRect(x: inset, y: rect.height * 0.7, width: rect.width - 2 * inset, height: rect.height * 0.25), withAttributes: attributes)
        }
    }

    static func portrait(seed: String, size: CGSize) -> UIImage {
        let palette = palette(for: seed)
        let initials = seed.split(separator: "-").compactMap { $0.first }.prefix(2).map(String.init).joined().uppercased()
        return render(size) { context, rect in
            drawSky(palette, in: context, rect: rect)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let font = UIFont.systemFont(ofSize: rect.width * 0.34, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white.withAlphaComponent(0.92), .paragraphStyle: paragraph]
            initials.draw(in: CGRect(x: 0, y: (rect.height - font.lineHeight) / 2, width: rect.width, height: font.lineHeight), withAttributes: attributes)
        }
    }

    private static func render(_ size: CGSize, _ draw: (CGContext, CGRect) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            draw(context.cgContext, CGRect(origin: .zero, size: size))
        }
    }

    private static func drawSky(_ palette: Palette, in context: CGContext, rect: CGRect) {
        let colors = palette.sky.map(\.cgColor) as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1]) else { return }
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: 0), end: CGPoint(x: rect.midX, y: rect.height), options: [])
    }

    private static func drawSun(_ palette: Palette, in context: CGContext, rect: CGRect, center: CGPoint, radius: CGFloat) {
        let colors = [palette.sun.withAlphaComponent(0.95).cgColor, palette.sun.withAlphaComponent(0).cgColor] as CFArray
        guard let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
        context.drawRadialGradient(glow, startCenter: center, startRadius: radius * 0.2, endCenter: center, endRadius: radius * 2.6, options: [])
        context.setFillColor(palette.sun.cgColor)
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func drawRidges(_ palette: Palette, in context: CGContext, rect: CGRect) {
        let layers: [(CGFloat, CGFloat, CGFloat)] = [(0.62, 0.10, 0.5), (0.74, 0.14, 0.8), (0.86, 0.12, 1)]
        for (index, layer) in layers.enumerated() {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 0, y: rect.height))
            let steps = 14
            for step in 0...steps {
                let x = rect.width * CGFloat(step) / CGFloat(steps)
                let wave = sin(CGFloat(step) * 0.9 + CGFloat(index) * 1.7) * 0.5 + sin(CGFloat(step) * 2.3 + CGFloat(index)) * 0.25
                path.addLine(to: CGPoint(x: x, y: rect.height * (layer.0 + layer.1 * wave * 0.5)))
            }
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.close()
            context.setFillColor(palette.ridge.withAlphaComponent(layer.2).cgColor)
            context.addPath(path.cgPath)
            context.fillPath()
        }
    }
}
#endif

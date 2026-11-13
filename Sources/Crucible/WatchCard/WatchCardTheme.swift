import CoreImage.CIFilterBuiltins
import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// The colours of one card look. Fixed values, so the shared image is the same whatever appearance the phone is in.
struct WatchCardPalette {
    let ground: UIColor
    let groundDeep: UIColor
    let ink: UIColor
    let inkSecondary: UIColor
    let inkTertiary: UIColor
    let accent: UIColor
    let hairline: UIColor
    let well: UIColor
    let washAlpha: CGFloat
    let glowAlpha: CGFloat
    let posterShadow: CGFloat
    let isDark: Bool

    var traits: UITraitCollection { UITraitCollection(userInterfaceStyle: isDark ? .dark : .light) }

    static func make(_ style: WatchCardStyle, tone: ArtworkTone?) -> WatchCardPalette {
        switch style {
        case .artwork:
            let tone = tone ?? .neutral
            let ink = UIColor(hex: 0xFBF8F4)
            return WatchCardPalette(
                ground: tone.ground,
                groundDeep: tone.groundDeep,
                ink: ink,
                inkSecondary: ink.withAlphaComponent(0.76),
                inkTertiary: ink.withAlphaComponent(0.52),
                accent: tone.accent,
                hairline: UIColor.white.withAlphaComponent(0.16),
                well: UIColor.white.withAlphaComponent(0.10),
                washAlpha: 0.62,
                glowAlpha: 0.30,
                posterShadow: 0.6,
                isDark: true
            )
        case .ember:
            let ink = UIColor(hex: 0xF6F3EF)
            return WatchCardPalette(
                ground: UIColor(hex: 0x0E0D0C),
                groundDeep: UIColor(hex: 0x0E0D0C),
                ink: ink,
                inkSecondary: ink.withAlphaComponent(0.72),
                inkTertiary: ink.withAlphaComponent(0.48),
                accent: UIColor(hex: 0xFF9F0A),
                hairline: UIColor.white.withAlphaComponent(0.14),
                well: UIColor.white.withAlphaComponent(0.08),
                washAlpha: 0.42,
                glowAlpha: 0.34,
                posterShadow: 0.6,
                isDark: true
            )
        case .paper:
            let ink = UIColor(hex: 0x1C1813)
            return WatchCardPalette(
                ground: UIColor(hex: 0xF5F0E7),
                groundDeep: UIColor(hex: 0xEAE2D5),
                ink: ink,
                inkSecondary: ink.withAlphaComponent(0.70),
                inkTertiary: ink.withAlphaComponent(0.48),
                accent: UIColor(hex: 0xC4470F),
                hairline: ink.withAlphaComponent(0.14),
                well: ink.withAlphaComponent(0.07),
                washAlpha: 0,
                glowAlpha: 0.10,
                posterShadow: 0.28,
                isDark: false
            )
        case .noir:
            return WatchCardPalette(
                ground: UIColor(hex: 0x050505),
                groundDeep: UIColor.black,
                ink: .white,
                inkSecondary: UIColor.white.withAlphaComponent(0.74),
                inkTertiary: UIColor.white.withAlphaComponent(0.50),
                accent: .white,
                hairline: UIColor.white.withAlphaComponent(0.18),
                well: UIColor.white.withAlphaComponent(0.11),
                washAlpha: 0.5,
                glowAlpha: 0,
                posterShadow: 0.7,
                isDark: true
            )
        }
    }
}

/// The type of one card look: SF Rounded for Artwork and Ember, New York for Paper, compressed capitals for Noir. The
/// viewer's own words are always set in New York italic, as a quote.
struct WatchCardType {
    let style: WatchCardStyle

    var uppercasesTitle: Bool { style == .noir }

    func title(_ size: CGFloat) -> UIFont {
        switch style {
        case .artwork, .ember: return Self.designed(.rounded, size, .heavy)
        case .paper: return Self.designed(.serif, size, .bold)
        case .noir: return UIFont.systemFont(ofSize: size * 1.12, weight: .black, width: .compressed)
        }
    }

    func body(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        switch style {
        case .artwork, .ember: return Self.designed(.rounded, size, weight)
        case .paper: return Self.designed(.serif, size, weight == .regular ? .regular : .semibold)
        case .noir: return UIFont.systemFont(ofSize: size, weight: weight)
        }
    }

    func label(_ size: CGFloat) -> UIFont {
        switch style {
        case .artwork, .ember: return Self.designed(.rounded, size, .heavy)
        case .paper: return UIFont.systemFont(ofSize: size, weight: .bold)
        case .noir: return UIFont.systemFont(ofSize: size, weight: .bold, width: .condensed)
        }
    }

    func number(_ size: CGFloat) -> UIFont {
        switch style {
        case .paper: return Self.designed(.serif, size, .bold)
        case .noir: return UIFont.systemFont(ofSize: size, weight: .black, width: .compressed)
        default: return Self.designed(.rounded, size, .heavy)
        }
    }

    func quote(_ size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: .medium)
        guard let serif = base.fontDescriptor.withDesign(.serif),
              let italic = serif.withSymbolicTraits(.traitItalic) else { return base }
        return UIFont(descriptor: italic, size: size)
    }

    func titleKern(_ size: CGFloat) -> CGFloat {
        switch style {
        case .noir: return size * 0.01
        case .paper: return -size * 0.01
        default: return -size * 0.02
        }
    }

    private static func designed(_ design: UIFontDescriptor.SystemDesign, _ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}

/// The colours a card takes from its artwork: the hue that carries the most colour in the poster, laid deep for the
/// ground and bright for the accent. A poster with no colour to speak of gives none.
struct ArtworkTone: Sendable {
    let ground: UIColor
    let groundDeep: UIColor
    let accent: UIColor

    static let neutral = ArtworkTone(ground: UIColor(hex: 0x1A1816), groundDeep: UIColor(hex: 0x0E0D0C), accent: UIColor(hex: 0xFFB340))

    private static let side = 40
    private static let buckets = 24

    init(ground: UIColor, groundDeep: UIColor, accent: UIColor) {
        self.ground = ground
        self.groundDeep = groundDeep
        self.accent = accent
    }

    init?(image: UIImage?) {
        guard let cgImage = image?.cgImage, let pixels = Self.pixels(of: cgImage) else { return nil }
        var weights = [Double](repeating: 0, count: Self.buckets)
        var saturation = [Double](repeating: 0, count: Self.buckets)
        var hueX = [Double](repeating: 0, count: Self.buckets)
        var hueY = [Double](repeating: 0, count: Self.buckets)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let color = UIColor(red: CGFloat(pixels[index]) / 255, green: CGFloat(pixels[index + 1]) / 255, blue: CGFloat(pixels[index + 2]) / 255, alpha: 1)
            var hue: CGFloat = 0, sat: CGFloat = 0, bright: CGFloat = 0, alpha: CGFloat = 0
            color.getHue(&hue, saturation: &sat, brightness: &bright, alpha: &alpha)
            guard sat > 0.22, bright > 0.18, bright < 0.98 else { continue }
            let bucket = min(Self.buckets - 1, Int(hue * CGFloat(Self.buckets)))
            let weight = Double(sat * sat) * Double(min(bright, 0.85))
            weights[bucket] += weight
            saturation[bucket] += Double(sat) * weight
            hueX[bucket] += cos(Double(hue) * 2 * .pi) * weight
            hueY[bucket] += sin(Double(hue) * 2 * .pi) * weight
        }
        let total = weights.reduce(0, +)
        guard let best = weights.indices.max(by: { weights[$0] < weights[$1] }), total > 0,
              weights[best] / Double(Self.side * Self.side * 3 / 2) > 0.004 else { return nil }
        var hue = atan2(hueY[best], hueX[best]) / (2 * .pi)
        if hue < 0 { hue += 1 }
        let sat = min(1, saturation[best] / weights[best])
        self.init(
            ground: UIColor(hue: hue, saturation: min(0.72, sat * 0.85), brightness: 0.20, alpha: 1),
            groundDeep: UIColor(hue: hue, saturation: min(0.8, sat * 0.9), brightness: 0.08, alpha: 1),
            accent: UIColor(hue: hue, saturation: min(0.62, max(0.38, sat * 0.7)), brightness: 1, alpha: 1)
        )
    }

    /// The image drawn small into plain RGBA bytes, enough to read its colours from.
    private static func pixels(of image: CGImage) -> [UInt8]? {
        let width = side, height = side * 3 / 2
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }
}

/// The artwork a card is drawn with, prepared once: the poster, the backdrop blurred for the wash behind everything (in
/// colour, and without it for Noir) and the tone the Artwork look takes from the poster.
struct WatchCardArtwork: Sendable {
    let poster: UIImage?
    let wash: UIImage?
    let monochromeWash: UIImage?
    let tone: ArtworkTone?

    static let empty = WatchCardArtwork(poster: nil, wash: nil, monochromeWash: nil, tone: nil)

    static func prepare(poster: UIImage?, backdrop: UIImage?) async -> WatchCardArtwork {
        await Task.detached(priority: .userInitiated) {
            let source = backdrop ?? poster
            let wash = source.flatMap { blurred($0, saturation: 1.15) }
            let monochrome = source.flatMap { blurred($0, saturation: 0) }
            return WatchCardArtwork(poster: poster, wash: wash, monochromeWash: monochrome, tone: ArtworkTone(image: poster ?? backdrop))
        }.value
    }

    /// The image scaled down to a width a blur hides the detail of, blurred, and given `saturation`.
    private static func blurred(_ image: UIImage, saturation: Double) -> UIImage? {
        guard var input = CIImage(image: image) else { return nil }
        let width = input.extent.width
        if width > 540 {
            input = input.transformed(by: CGAffineTransform(scaleX: 540 / width, y: 540 / width))
        }
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = input.clampedToExtent()
        blur.radius = 16
        let color = CIFilter.colorControls()
        color.inputImage = blur.outputImage
        color.saturation = Float(saturation)
        guard let output = color.outputImage?.cropped(to: input.extent),
              let cgImage = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

import CrucibleDesign
import UIKit

/// The one door every tvOS image goes through. The default provider asks the shared `ImageLoader`;
/// the design gallery swaps in a provider that draws fixtures so it never needs a server.
@MainActor
enum TVImagePipeline {
    enum Kind: Sendable {
        case poster
        case backdrop
    }

    typealias Provider = @Sendable (_ path: String, _ pixelWidth: Int, _ kind: Kind) async -> UIImage?

    static var provider: Provider = { path, pixelWidth, kind in
        switch kind {
        case .poster: await ImageLoader.shared.loadImage(path: path, width: pixelWidth)
        case .backdrop: await ImageLoader.shared.loadBackdrop(path: path, width: pixelWidth)
        }
    }

    static func load(path: String, pointWidth: CGFloat, scale: CGFloat, kind: Kind) async -> UIImage? {
        let width = TVMetrics.pixelWidth(forPoints: pointWidth, scale: scale)
        let ceiling = kind == .poster ? TVMetrics.Backdrop.maximumPosterPixelWidth : TVMetrics.Backdrop.maximumPixelWidth
        return await provider(path, min(width, ceiling), kind)
    }
}

/// Draws the neutral artwork shown while a card's image loads, or when it has none.
@MainActor
enum TVPlaceholder {
    private static var cache: [String: UIImage] = [:]

    /// The placeholder for a card of `size`: an ellipse when `circular`, otherwise a rectangle with `cornerRadius` corners on a
    /// transparent surround, so the focus effect follows the same shape as the artwork that replaces it.
    static func image(symbol: String, size: CGSize, traits: UITraitCollection, circular: Bool = false, cornerRadius: CGFloat = 0) -> UIImage {
        let key = "\(symbol)|\(Int(size.width))x\(Int(size.height))|\(traits.userInterfaceStyle.rawValue)|\(circular)|\(Int(cornerRadius))"
        if let cached = cache[key] { return cached }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        var image = UIImage()
        traits.performAsCurrent {
            image = renderer.image { context in
                let bounds = CGRect(origin: .zero, size: size)
                if circular {
                    UIBezierPath(ovalIn: bounds).addClip()
                } else if cornerRadius > 0 {
                    UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius).addClip()
                }
                Theme.Color.surfaceRaised.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                let configuration = UIImage.SymbolConfiguration(pointSize: min(size.width, size.height) * 0.22, weight: .light)
                guard let glyph = UIImage(systemName: symbol, withConfiguration: configuration)?
                    .withTintColor(Theme.Color.labelTertiary, renderingMode: .alwaysOriginal)
                else { return }
                let origin = CGPoint(x: (size.width - glyph.size.width) / 2, y: (size.height - glyph.size.height) / 2)
                glyph.draw(at: origin)
            }
        }
        cache[key] = image
        return image
    }
}

extension UIImage {
    /// The image drawn whole and centred on a `background` canvas `aspect` tall for its width, as large as the image itself.
    func centered(onAspect aspect: CGFloat, background: UIColor) -> UIImage {
        let canvas = size.height / size.width > aspect
            ? CGSize(width: (size.height / aspect).rounded(), height: size.height)
            : CGSize(width: size.width, height: (size.width * aspect).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            background.setFill()
            context.fill(CGRect(origin: .zero, size: canvas))
            draw(at: CGPoint(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2))
        }
    }

    /// The image cropped from its centre to `aspect` (height over width) and drawn with corners of `cornerRadius` points on a
    /// view `pointWidth` wide, on a transparent surround, at the image's own resolution. The system focus effect zooms the
    /// image it is given; one already in the card's shape looks the same at rest and while it grows, where an image of another
    /// shape spills past the card at rest and is cut back to it once it has focus.
    func shaped(toAspect aspect: CGFloat, cornerRadius: CGFloat, pointWidth: CGFloat) -> UIImage {
        guard size.width > 0, size.height > 0, aspect > 0, pointWidth > 0 else { return self }
        let canvas = size.height / size.width > aspect
            ? CGSize(width: size.width, height: (size.width * aspect).rounded())
            : CGSize(width: (size.height / aspect).rounded(), height: size.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        format.preferredRange = .standard
        let bounds = CGRect(origin: .zero, size: canvas)
        let radius = cornerRadius * canvas.width / pointWidth
        return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            UIBezierPath(roundedRect: bounds, cornerRadius: radius).addClip()
            draw(in: CGRect(
                x: (canvas.width - size.width) / 2,
                y: (canvas.height - size.height) / 2,
                width: size.width,
                height: size.height
            ))
        }
    }

    /// The image clipped to an ellipse with a transparent surround, so the system focus effect can
    /// follow the circle (`UIImageView.masksFocusEffectToContents`).
    func circularCrop() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).addClip()
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

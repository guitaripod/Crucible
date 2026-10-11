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

    static func image(symbol: String, size: CGSize, traits: UITraitCollection, circular: Bool = false) -> UIImage {
        let key = "\(symbol)|\(Int(size.width))x\(Int(size.height))|\(traits.userInterfaceStyle.rawValue)|\(circular)"
        if let cached = cache[key] { return cached }
        let renderer = UIGraphicsImageRenderer(size: size)
        var image = UIImage()
        traits.performAsCurrent {
            image = renderer.image { context in
                if circular { UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).addClip() }
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

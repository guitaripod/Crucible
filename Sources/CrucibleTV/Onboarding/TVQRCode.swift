import CoreImage.CIFilterBuiltins
import UIKit

/// Renders a QR code as sharp, square modules inside a white quiet zone, sized to a whole number of
/// pixels per module so no edge is ever blended.
enum TVQRCode {
    /// Modules of white around the code that the QR specification asks for.
    static let quietZoneModules = 4

    /// An image about `side` points square for `text`, or nil when the text cannot be encoded.
    @MainActor
    static func image(for text: String, side: CGFloat, scale: CGFloat) -> UIImage? {
        guard let modules = moduleImage(for: text) else { return nil }
        let totalModules = modules.width + 2 * quietZoneModules
        let pixelsPerModule = max(1, Int((side * scale / CGFloat(totalModules)).rounded()))
        let sidePixels = pixelsPerModule * totalModules
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: sidePixels, height: sidePixels), format: format)
        let rendered = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: sidePixels, height: sidePixels))
            context.cgContext.interpolationQuality = .none
            let inset = CGFloat(quietZoneModules * pixelsPerModule)
            let codeSide = CGFloat(modules.width * pixelsPerModule)
            context.cgContext.translateBy(x: 0, y: CGFloat(sidePixels))
            context.cgContext.scaleBy(x: 1, y: -1)
            context.cgContext.draw(modules, in: CGRect(x: inset, y: inset, width: codeSide, height: codeSide))
        }
        guard let cgImage = rendered.cgImage else { return nil }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }

    /// One pixel per module, black on white, error correction M.
    private static func moduleImage(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

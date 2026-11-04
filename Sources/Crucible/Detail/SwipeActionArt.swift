import UIKit

/// Renders a swipe action's glyph and caption into one image so the caption can use the
/// on-accent or label colour (UIKit always draws contextual action titles in white).
@MainActor
enum SwipeActionArt {
    static func image(symbol: String, title: String, spokenTitle: String, color: UIColor, traits: UITraitCollection) -> UIImage? {
        let resolved = color.resolvedColor(with: traits)
        let font = UIFont.systemFont(ofSize: 12, weight: .bold)
        let glyph = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))?
            .withTintColor(resolved, renderingMode: .alwaysOriginal)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: resolved]
        let textSize = (title as NSString).size(withAttributes: attributes)
        let glyphSize = glyph?.size ?? .zero
        let width = ceil(max(textSize.width, glyphSize.width, 24))
        let spacing: CGFloat = 4
        let height = ceil(glyphSize.height + spacing + textSize.height)
        let format = UIGraphicsImageRendererFormat(for: traits)
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            glyph?.draw(in: CGRect(x: (width - glyphSize.width) / 2, y: 0, width: glyphSize.width, height: glyphSize.height))
            (title as NSString).draw(at: CGPoint(x: (width - textSize.width) / 2, y: glyphSize.height + spacing), withAttributes: attributes)
        }
        let result = image.withRenderingMode(.alwaysOriginal)
        result.accessibilityLabel = spokenTitle
        return result
    }
}

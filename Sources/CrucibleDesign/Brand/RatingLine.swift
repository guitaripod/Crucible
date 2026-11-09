import CrucibleCore
import UIKit

/// Scores drawn inline in a line of text, as on a detail page's meta line: each source's official mark at the height of the
/// text (Plex's star where the source is not named), then the score the way that source writes it.
@MainActor
package enum RatingLine {
    /// One attributed segment per score, in `font` and `color`, ready to be joined with the line's separators.
    package static func segments(_ ratings: [DetailRating], font: UIFont, color: UIColor, traits: UITraitCollection = .current) -> [NSAttributedString] {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        return ratings.map { rating in
            let segment = NSMutableAttributedString()
            if let mark = markImage(rating.mark, font: font, traits: traits) {
                let attachment = NSTextAttachment(image: mark)
                let height = mark.size.height
                attachment.bounds = CGRect(x: 0, y: ((font.capHeight - height) / 2).rounded(), width: mark.size.width, height: height)
                segment.append(NSAttributedString(attachment: attachment))
                segment.append(NSAttributedString(string: "\u{00A0}", attributes: attributes))
            }
            segment.append(NSAttributedString(string: rating.text, attributes: attributes))
            return segment
        }
    }

    private static func markImage(_ mark: DetailRating.Mark, font: UIFont, traits: UITraitCollection) -> UIImage? {
        switch mark {
        case .none:
            return nil
        case .star:
            return UIImage(systemName: "star.fill", withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small))?
                .withTintColor(Theme.Color.accent, renderingMode: .alwaysOriginal)
        case .score(let score):
            let brand = BrandMark(score: score)
            guard let image = brand.image else { return nil }
            let resolved = image.imageAsset?.image(with: traits) ?? image
            return fitted(resolved, height: (font.capHeight * (brand.isWordmark ? 1.35 : 1.5)).rounded())
        }
    }

    /// The mark redrawn at `height`, so the line keeps its own height and the attachment needs no scaling of its own.
    private static func fitted(_ image: UIImage, height: CGFloat) -> UIImage {
        guard image.size.height > 0 else { return image }
        let size = CGSize(width: (height * image.size.width / image.size.height).rounded(), height: height)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysOriginal)
    }
}

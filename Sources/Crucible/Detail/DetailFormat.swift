import CrucibleCore
import CrucibleDesign
import UIKit

extension Theme.Font {
    static var detailTitle: UIFont { scaled(.largeTitle, 34, .heavy) }
    static var eyebrow: UIFont { scaled(.caption2, 11, .bold, maximum: 18) }
    static var episodeTitle: UIFont { scaled(.callout, 16, .semibold) }
    static var chip: UIFont { scaled(.subheadline, 14, .semibold, maximum: 22) }
}

/// The UIKit-bound half of `DetailFormat`; the copy and fact formatting lives in CrucibleCore.
@MainActor
extension DetailFormat {
    static func eyebrow(_ text: String, color: UIColor) -> NSAttributedString {
        NSAttributedString(string: text.uppercased(), attributes: [
            .font: Theme.Font.eyebrow,
            .foregroundColor: color,
            .kern: 1.0,
        ])
    }

    /// "2021 · 2 h 14 m · ★ 8.1 · 92% critics", each score under its source's mark: Plex's own ratings, then Trakt's.
    static func metaLine(_ meta: DetailMeta, traits: UITraitCollection = .current) -> NSAttributedString {
        let font = Theme.Font.subheadline
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.Color.labelSecondary]
        var segments: [NSAttributedString] = meta.leading.map { NSAttributedString(string: $0, attributes: attributes) }
        segments += RatingLine.segments(meta.ratings, font: font, color: Theme.Color.labelSecondary, traits: traits)
        let result = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: " · ", attributes: attributes)) }
            result.append(segment)
        }
        return result
    }
}

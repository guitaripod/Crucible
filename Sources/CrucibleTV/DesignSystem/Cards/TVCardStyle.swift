import CrucibleDesign
import UIKit

/// Geometry and caption rules of one card shape. The five shapes share one content view; the style
/// is the only thing that differs, so spacing, typography and decorations stay identical.
struct TVCardStyle: Hashable, Sendable {
    enum Shape: Hashable, Sendable {
        case rounded
        case circle
    }

    let artworkSize: CGSize
    let itemWidth: CGFloat
    let kind: TVImagePipeline.Kind
    let shape: Shape
    let titleLines: Int
    let showsEyebrow: Bool
    let centersCaption: Bool
    let scrimsArtwork: Bool

    static let poster = TVCardStyle(
        artworkSize: TVMetrics.Card.posterSize,
        itemWidth: TVMetrics.Card.posterSize.width,
        kind: .poster,
        shape: .rounded,
        titleLines: 1,
        showsEyebrow: false,
        centersCaption: false,
        scrimsArtwork: false
    )

    static let landscape = TVCardStyle(
        artworkSize: TVMetrics.Card.landscapeSize,
        itemWidth: TVMetrics.Card.landscapeSize.width,
        kind: .backdrop,
        shape: .rounded,
        titleLines: 1,
        showsEyebrow: false,
        centersCaption: false,
        scrimsArtwork: true
    )

    static let episode = TVCardStyle(
        artworkSize: TVMetrics.Card.landscapeSize,
        itemWidth: TVMetrics.Card.landscapeSize.width,
        kind: .backdrop,
        shape: .rounded,
        titleLines: 2,
        showsEyebrow: true,
        centersCaption: false,
        scrimsArtwork: true
    )

    static let person = TVCardStyle(
        artworkSize: CGSize(width: TVMetrics.Card.personDiameter, height: TVMetrics.Card.personDiameter),
        itemWidth: TVMetrics.Card.personDiameter + 40,
        kind: .poster,
        shape: .circle,
        titleLines: 1,
        showsEyebrow: false,
        centersCaption: true,
        scrimsArtwork: false
    )

    @MainActor
    var captionHeight: CGFloat {
        let spacing = TVMetrics.Card.captionLabelSpacing
        var height = TVFont.cardTitle.lineHeight * CGFloat(titleLines) + spacing + TVFont.cardSubtitle.lineHeight
        if showsEyebrow { height += TVFont.eyebrow.lineHeight + spacing }
        return ceil(height)
    }

    @MainActor
    var itemSize: CGSize {
        CGSize(
            width: itemWidth,
            height: artworkSize.height + TVMetrics.Card.captionSpacing + captionHeight
        )
    }
}

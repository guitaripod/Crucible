import CrucibleCore
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

    /// The card of a grid whose artwork is `aspect` tall for its width, captioned like a poster: the poster itself for
    /// posters, otherwise as wide as covers about a poster's area (never narrower), rounded to whole columns of the grid.
    static func grid(aspect: Double) -> TVCardStyle {
        guard abs(aspect - ArtworkAspect.poster) > 0.005 else { return .poster }
        let gutter = TVMetrics.gutter
        let target = TVMetrics.Card.posterSize.width * max(1, (ArtworkAspect.poster / aspect).squareRoot())
        let columns = max(1, Int(((TVMetrics.gridWidth + gutter) / (target + gutter)).rounded()))
        let width = ((TVMetrics.gridWidth - gutter * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
        return TVCardStyle(
            artworkSize: CGSize(width: width, height: (width * aspect).rounded()),
            itemWidth: width,
            kind: aspect < 1 ? .backdrop : .poster,
            shape: .rounded,
            titleLines: 1,
            showsEyebrow: false,
            centersCaption: false,
            scrimsArtwork: false
        )
    }

    /// How many of these cards a grid row holds.
    var gridColumns: Int {
        max(1, Int(((TVMetrics.gridWidth + TVMetrics.gutter) / (itemWidth + TVMetrics.gutter)).rounded()))
    }

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

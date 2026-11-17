import Foundation
import Kiln

/// A grid of titles while it loads (a collection, a person's films, a playlist): poster blocks laid out exactly as
/// `CardGridView` will lay out its cards, each with a title and a shorter subtitle line under it, as many lines as fill the
/// skeleton.
@MainActor
public final class SkeletonGridView: SkeletonView {
    /// How tall the artwork is for its width, as on the grid it stands in for.
    public var aspect: Float = 1.5 { didSet { setNeedsDisplay() } }

    override func drawBlocks(_ context: inout DrawContext, color: Color) {
        let metrics = Theme.current.metrics
        let width = frame.width - metrics.sideMargin * 2
        guard width > 0 else { return }
        let style = CardStyle.grid(aspect: aspect, width: width)
        let columns = max(1, metrics.gridColumns(itemWidth: style.itemWidth, width: width))
        let caption = metrics.tv(26)
        var y = metrics.shelfTopInset
        while y < frame.height {
            for column in 0..<columns {
                let x = metrics.sideMargin + Float(column) * (style.itemWidth + metrics.gutter)
                let art = Rect(x: x, y: y, width: style.itemWidth, height: style.artworkSize.height)
                context.fill(art, radius: metrics.cardCornerRadius, color: color)
                let title = Rect(x: x, y: art.maxY + metrics.captionSpacing, width: (style.itemWidth * 0.72).rounded(), height: caption)
                context.fill(title, radius: metrics.radiusXS, color: color.multipliedAlpha(0.8))
                context.fill(Rect(x: x, y: title.maxY + metrics.tv(10), width: (style.itemWidth * 0.44).rounded(), height: caption * 0.8),
                             radius: metrics.radiusXS, color: color.multipliedAlpha(0.6))
            }
            y += style.itemSize.height + metrics.gridRowSpacing
        }
    }
}

/// A list of rows while it loads (comments, a member's page): an icon well, a name and two lines of text per row, at the
/// rows' own height and spacing, filling the column.
@MainActor
public final class SkeletonRowsView: SkeletonView {
    /// The width of the rows' column, centred, or the whole width without one.
    public var columnWidth: Float? { didSet { setNeedsDisplay() } }

    override func drawBlocks(_ context: inout DrawContext, color: Color) {
        let metrics = Theme.current.metrics
        let width = min(columnWidth ?? frame.width, frame.width)
        let left = ((frame.width - width) / 2).rounded() + metrics.rowInset
        let textX = left + metrics.rowIconWell + metrics.tv(24)
        let room = width - (textX - ((frame.width - width) / 2).rounded()) - metrics.rowInset
        let fractions: [(title: Float, first: Float, second: Float)] = [(0.42, 0.94, 0.66), (0.3, 0.88, 0.52), (0.36, 0.97, 0.74), (0.26, 0.8, 0.4)]
        let rowHeight = metrics.rowHeight + metrics.tv(48)
        var y = metrics.tv(12)
        var index = 0
        while y + rowHeight <= frame.height, room > 0 {
            let shape = fractions[index % fractions.count]
            context.fill(Rect(x: left, y: y + metrics.tv(8), width: metrics.rowIconWell, height: metrics.rowIconWell), radius: metrics.radiusS, color: color)
            context.fill(Rect(x: textX, y: y + metrics.tv(8), width: (room * shape.title).rounded(), height: metrics.tv(28)), radius: metrics.radiusXS,
                         color: color)
            context.fill(Rect(x: textX, y: y + metrics.tv(56), width: (room * shape.first).rounded(), height: metrics.tv(22)), radius: metrics.radiusXS,
                         color: color.multipliedAlpha(0.7))
            context.fill(Rect(x: textX, y: y + metrics.tv(90), width: (room * shape.second).rounded(), height: metrics.tv(22)), radius: metrics.radiusXS,
                         color: color.multipliedAlpha(0.7))
            y += rowHeight + metrics.rowSpacing
            index += 1
        }
    }
}

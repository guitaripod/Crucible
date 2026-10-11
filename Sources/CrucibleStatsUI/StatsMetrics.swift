import CrucibleDesign
import UIKit

/// A font recipe for the statistics views: dynamic-type scaled, fixed, or fixed with the rounded design.
package enum StatsFont: Sendable {
    case scaled(UIFont.TextStyle, size: CGFloat, weight: UIFont.Weight, maximum: CGFloat? = nil)
    case fixed(size: CGFloat, weight: UIFont.Weight)
    case rounded(size: CGFloat, weight: UIFont.Weight)

    package var uiFont: UIFont {
        switch self {
        case let .scaled(style, size, weight, maximum):
            return Theme.Font.scaled(style, size, weight, maximum: maximum)
        case let .fixed(size, weight):
            return .systemFont(ofSize: size, weight: weight)
        case let .rounded(size, weight):
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
            return UIFont(descriptor: descriptor, size: size)
        }
    }
}

/// Every dimension and font the statistics charts and components draw with. ``phone`` reproduces the
/// iPhone layout exactly; ``tv`` is the 10-foot preset. Views take a value of this type and fall back
/// to ``platform``, so a screen only passes one when it wants something other than its platform's.
package struct StatsMetrics: Sendable {
    package struct Card: Sendable {
        package var inset: CGFloat
        package var spacing: CGFloat
        package var headerSpacing: CGFloat
        package var borderWidth: CGFloat
    }

    package struct RangeControl: Sendable {
        package var font: StatsFont
        package var minHeight: CGFloat
    }

    package struct Hero: Sendable {
        package var inset: CGFloat
        package var borderWidth: CGFloat
        package var stackSpacing: CGFloat
        package var eyebrowSpacing: CGFloat
        package var unitSpacing: CGFloat
        package var odometerFont: StatsFont
        package var unitFont: StatsFont
    }

    package struct HeatLegend: Sendable {
        package var swatch: CGFloat
        package var swatchCorner: CGFloat
        package var spacing: CGFloat
        package var captionGap: CGFloat
    }

    package struct Tile: Sendable {
        package var borderWidth: CGFloat
        package var minHeight: CGFloat
        package var insetVertical: CGFloat
        package var insetHorizontal: CGFloat
        package var captionSpacing: CGFloat
        package var valueSpacing: CGFloat
        package var symbolPointSize: CGFloat
        package var sparklineSize: CGSize
        package var sparklineLineWidth: CGFloat
        package var valueFont: StatsFont
    }

    package struct Heatmap: Sendable {
        package var cellEdge: CGFloat
        package var gap: CGFloat
        package var corner: CGFloat
        package var monthLabelHeight: CGFloat
        package var monthFont: StatsFont
    }

    package struct RankedRow: Sendable {
        package var thumbSize: CGSize
        package var thumbRequestWidth: Int
        package var trackHeight: CGFloat
        package var trackCorner: CGFloat
        package var rowSpacing: CGFloat
        package var titleSpacing: CGFloat
        package var textSpacing: CGFloat
        package var verticalInset: CGFloat
        package var accessorySide: CGFloat
        package var valueFont: StatsFont
    }

    package struct Ring: Sendable {
        package var intrinsicSide: CGFloat
    }

    package struct Clock: Sendable {
        package var intrinsicSide: CGFloat
        package var inset: CGFloat
        package var hairline: CGFloat
    }

    package struct WeekdayChart: Sendable {
        package var intrinsicHeight: CGFloat
        package var labelRowHeight: CGFloat
        package var valueRowHeight: CGFloat
        package var labelOffset: CGFloat
        package var barCorner: CGFloat
        package var minBarWidth: CGFloat
        package var maxBarWidth: CGFloat
        package var hairline: CGFloat
        package var weekdayFont: StatsFont
        package var valueFont: StatsFont
    }

    package struct Trend: Sendable {
        package var compactHeight: CGFloat
        package var axesHeight: CGFloat
        package var lineWidth: CGFloat
        package var dotRadius: CGFloat
        package var dotPadding: CGFloat
        package var dotBorderWidth: CGFloat
        package var dotShadowRadius: CGFloat
        package var axesInsetHorizontal: CGFloat
        package var axesInsetTop: CGFloat
        package var axesInsetBottom: CGFloat
        package var labelGap: CGFloat
        package var labelEdgeMargin: CGFloat
        package var peakFont: StatsFont
    }

    package struct Donut: Sendable {
        package var intrinsicSide: CGFloat
        package var edgePadding: CGFloat
        package var labelSpacing: CGFloat
        package var titleFont: StatsFont
        package var subtitleFont: StatsFont
    }

    package struct BingeTimeline: Sendable {
        package var intrinsicHeight: CGFloat
        package var topInset: CGFloat
        package var axisReserve: CGFloat
        package var axisBottomMargin: CGFloat
        package var axisLineWidth: CGFloat
        package var cardSpacing: CGFloat
        package var minCardWidth: CGFloat
        package var maxCardWidth: CGFloat
        package var pointsPerEpisode: CGFloat
        package var cardInsetHorizontal: CGFloat
        package var cardInsetVertical: CGFloat
        package var cardStackSpacing: CGFloat
        package var cardShadowRadius: CGFloat
        package var cardShadowOffset: CGFloat
        package var labelShadowOpacity: CGFloat
        package var titleFont: StatsFont
        package var episodesFont: StatsFont
        package var captionFont: StatsFont
    }

    package struct WrappedCard: Sendable {
        package var intrinsicHeight: CGFloat
        package var padding: CGFloat
        package var stackSpacing: CGFloat
        package var spacingAfterSymbol: CGFloat
        package var spacingAfterHeadline: CGFloat
        package var symbolPointSize: CGFloat
        package var headlineFont: StatsFont
        package var titleFont: StatsFont
        package var captionFont: StatsFont
    }

    package struct HeatStrip: Sendable {
        package var cellWidth: CGFloat?
        package var cellHeight: CGFloat
        package var gap: CGFloat
        package var corner: CGFloat
    }

    package struct YearCard: Sendable {
        package var inset: CGFloat
        package var stripBottomInset: CGFloat
        package var stripGap: CGFloat
        package var minHeight: CGFloat
        package var afterTopRow: CGFloat
        package var lineSpacing: CGFloat
        package var bigRowSpacing: CGFloat
        package var linkSpacing: CGFloat
        package var chevronPointSize: CGFloat
        package var captionKern: CGFloat
        package var detailLines: Int
        package var captionFont: StatsFont
        package var linkFont: StatsFont
        package var primaryFont: StatsFont
        package var unitFont: StatsFont
        package var detailFont: StatsFont
    }

    package var card: Card
    package var rangeControl: RangeControl
    package var hero: Hero
    package var heatLegend: HeatLegend
    package var tile: Tile
    package var heatmap: Heatmap
    package var rankedRow: RankedRow
    package var ring: Ring
    package var clock: Clock
    package var weekdayChart: WeekdayChart
    package var trend: Trend
    package var donut: Donut
    package var bingeTimeline: BingeTimeline
    package var wrappedCard: WrappedCard
    package var yearStrip: HeatStrip
    package var heroStrip: HeatStrip
    package var yearCard: YearCard

    package static var platform: StatsMetrics {
        #if os(tvOS)
        return tv
        #else
        return phone
        #endif
    }

    /// tvOS has no large-title text style, so the phone hero number names it through here.
    private static var largeTitleStyle: UIFont.TextStyle {
        #if os(tvOS)
        return .title1
        #else
        return .largeTitle
        #endif
    }

    package static let phone = StatsMetrics(
        card: Card(inset: 16, spacing: 12, headerSpacing: 8, borderWidth: 0.5),
        rangeControl: RangeControl(font: .scaled(.subheadline, size: 14, weight: .semibold, maximum: 20), minHeight: 44),
        hero: Hero(
            inset: 18,
            borderWidth: 1,
            stackSpacing: 2,
            eyebrowSpacing: 6,
            unitSpacing: 8,
            odometerFont: .scaled(largeTitleStyle, size: 68, weight: .heavy, maximum: 96),
            unitFont: .scaled(.title2, size: 24, weight: .semibold, maximum: 32)
        ),
        heatLegend: HeatLegend(swatch: 9, swatchCorner: 2, spacing: 2, captionGap: 6),
        tile: Tile(
            borderWidth: 0.5,
            minHeight: 96,
            insetVertical: 14,
            insetHorizontal: 16,
            captionSpacing: 6,
            valueSpacing: 6,
            symbolPointSize: 13,
            sparklineSize: CGSize(width: 64, height: 26),
            sparklineLineWidth: 2,
            valueFont: .scaled(.title1, size: 30, weight: .bold, maximum: 40)
        ),
        heatmap: Heatmap(cellEdge: 12, gap: 3, corner: 2.5, monthLabelHeight: 16, monthFont: .fixed(size: 11, weight: .regular)),
        rankedRow: RankedRow(
            thumbSize: CGSize(width: 36, height: 54),
            thumbRequestWidth: 120,
            trackHeight: 4,
            trackCorner: 2,
            rowSpacing: 12,
            titleSpacing: 8,
            textSpacing: 7,
            verticalInset: 6,
            accessorySide: 30,
            valueFont: .scaled(.subheadline, size: 15, weight: .medium)
        ),
        ring: Ring(intrinsicSide: 46),
        clock: Clock(intrinsicSide: 200, inset: 6, hairline: 1),
        weekdayChart: WeekdayChart(
            intrinsicHeight: 150,
            labelRowHeight: 18,
            valueRowHeight: 15,
            labelOffset: 3,
            barCorner: 6,
            minBarWidth: 6,
            maxBarWidth: 34,
            hairline: 1,
            weekdayFont: .rounded(size: 11, weight: .medium),
            valueFont: .rounded(size: 10, weight: .semibold)
        ),
        trend: Trend(
            compactHeight: 44,
            axesHeight: 160,
            lineWidth: 2,
            dotRadius: 4,
            dotPadding: 4,
            dotBorderWidth: 1.5,
            dotShadowRadius: 3,
            axesInsetHorizontal: 6,
            axesInsetTop: 14,
            axesInsetBottom: 8,
            labelGap: 4,
            labelEdgeMargin: 2,
            peakFont: .fixed(size: 11, weight: .semibold)
        ),
        donut: Donut(
            intrinsicSide: 220,
            edgePadding: 3,
            labelSpacing: 2,
            titleFont: .fixed(size: 22, weight: .bold),
            subtitleFont: .fixed(size: 11, weight: .medium)
        ),
        bingeTimeline: BingeTimeline(
            intrinsicHeight: 136,
            topInset: 4,
            axisReserve: 16,
            axisBottomMargin: 8,
            axisLineWidth: 1,
            cardSpacing: 12,
            minCardWidth: 132,
            maxCardWidth: 220,
            pointsPerEpisode: 10,
            cardInsetHorizontal: 12,
            cardInsetVertical: 10,
            cardStackSpacing: 2,
            cardShadowRadius: 6,
            cardShadowOffset: 2,
            labelShadowOpacity: 0.25,
            titleFont: .fixed(size: 15, weight: .semibold),
            episodesFont: .rounded(size: 20, weight: .bold),
            captionFont: .fixed(size: 11, weight: .medium)
        ),
        wrappedCard: WrappedCard(
            intrinsicHeight: 150,
            padding: 18,
            stackSpacing: 4,
            spacingAfterSymbol: 10,
            spacingAfterHeadline: 2,
            symbolPointSize: 30,
            headlineFont: .rounded(size: 40, weight: .heavy),
            titleFont: .fixed(size: 15, weight: .semibold),
            captionFont: .fixed(size: 12, weight: .regular)
        ),
        yearStrip: HeatStrip(cellWidth: nil, cellHeight: 8, gap: 3, corner: 2),
        heroStrip: HeatStrip(cellWidth: 8, cellHeight: 8, gap: 3, corner: 2),
        yearCard: YearCard(
            inset: 18,
            stripBottomInset: 16,
            stripGap: 12,
            minHeight: 176,
            afterTopRow: 6,
            lineSpacing: 0,
            bigRowSpacing: 6,
            linkSpacing: 2,
            chevronPointSize: 11,
            captionKern: 1.0,
            detailLines: 0,
            captionFont: .scaled(.caption2, size: 11, weight: .bold, maximum: 16),
            linkFont: .scaled(.footnote, size: 13, weight: .regular),
            primaryFont: .scaled(largeTitleStyle, size: 52, weight: .heavy, maximum: 72),
            unitFont: .scaled(.title2, size: 22, weight: .semibold, maximum: 30),
            detailFont: .scaled(.subheadline, size: 14, weight: .regular)
        )
    )

    package static let tv = StatsMetrics(
        card: Card(inset: 40, spacing: 28, headerSpacing: 16, borderWidth: 1),
        rangeControl: RangeControl(font: .scaled(.subheadline, size: 31, weight: .semibold, maximum: 40), minHeight: 80),
        hero: Hero(
            inset: 48,
            borderWidth: 2,
            stackSpacing: 6,
            eyebrowSpacing: 14,
            unitSpacing: 16,
            odometerFont: .scaled(largeTitleStyle, size: 150, weight: .heavy, maximum: 190),
            unitFont: .scaled(.title2, size: 52, weight: .semibold, maximum: 66)
        ),
        heatLegend: HeatLegend(swatch: 20, swatchCorner: 4, spacing: 4, captionGap: 12),
        tile: Tile(
            borderWidth: 1,
            minHeight: 190,
            insetVertical: 28,
            insetHorizontal: 32,
            captionSpacing: 12,
            valueSpacing: 12,
            symbolPointSize: 26,
            sparklineSize: CGSize(width: 140, height: 56),
            sparklineLineWidth: 4,
            valueFont: .scaled(.title1, size: 72, weight: .bold, maximum: 90)
        ),
        heatmap: Heatmap(cellEdge: 24, gap: 6, corner: 5, monthLabelHeight: 36, monthFont: .fixed(size: 23, weight: .regular)),
        rankedRow: RankedRow(
            thumbSize: CGSize(width: 80, height: 120),
            thumbRequestWidth: 240,
            trackHeight: 8,
            trackCorner: 4,
            rowSpacing: 28,
            titleSpacing: 16,
            textSpacing: 14,
            verticalInset: 14,
            accessorySide: 64,
            valueFont: .scaled(.subheadline, size: 35, weight: .medium)
        ),
        ring: Ring(intrinsicSide: 92),
        clock: Clock(intrinsicSide: 440, inset: 12, hairline: 2),
        weekdayChart: WeekdayChart(
            intrinsicHeight: 340,
            labelRowHeight: 40,
            valueRowHeight: 32,
            labelOffset: 6,
            barCorner: 12,
            minBarWidth: 12,
            maxBarWidth: 72,
            hairline: 2,
            weekdayFont: .rounded(size: 25, weight: .medium),
            valueFont: .rounded(size: 23, weight: .semibold)
        ),
        trend: Trend(
            compactHeight: 88,
            axesHeight: 360,
            lineWidth: 5,
            dotRadius: 9,
            dotPadding: 8,
            dotBorderWidth: 3,
            dotShadowRadius: 6,
            axesInsetHorizontal: 12,
            axesInsetTop: 44,
            axesInsetBottom: 16,
            labelGap: 8,
            labelEdgeMargin: 4,
            peakFont: .fixed(size: 25, weight: .semibold)
        ),
        donut: Donut(
            intrinsicSide: 440,
            edgePadding: 6,
            labelSpacing: 4,
            titleFont: .fixed(size: 62, weight: .bold),
            subtitleFont: .fixed(size: 25, weight: .medium)
        ),
        bingeTimeline: BingeTimeline(
            intrinsicHeight: 300,
            topInset: 8,
            axisReserve: 32,
            axisBottomMargin: 16,
            axisLineWidth: 2,
            cardSpacing: 24,
            minCardWidth: 340,
            maxCardWidth: 560,
            pointsPerEpisode: 26,
            cardInsetHorizontal: 28,
            cardInsetVertical: 24,
            cardStackSpacing: 4,
            cardShadowRadius: 14,
            cardShadowOffset: 4,
            labelShadowOpacity: 0.55,
            titleFont: .fixed(size: 31, weight: .semibold),
            episodesFont: .rounded(size: 52, weight: .bold),
            captionFont: .fixed(size: 25, weight: .medium)
        ),
        wrappedCard: WrappedCard(
            intrinsicHeight: 380,
            padding: 40,
            stackSpacing: 8,
            spacingAfterSymbol: 20,
            spacingAfterHeadline: 4,
            symbolPointSize: 60,
            headlineFont: .rounded(size: 88, weight: .heavy),
            titleFont: .fixed(size: 35, weight: .semibold),
            captionFont: .fixed(size: 27, weight: .regular)
        ),
        yearStrip: HeatStrip(cellWidth: nil, cellHeight: 14, gap: 5, corner: 3),
        heroStrip: HeatStrip(cellWidth: 26, cellHeight: 26, gap: 7, corner: 6),
        yearCard: YearCard(
            inset: 32,
            stripBottomInset: 32,
            stripGap: 24,
            minHeight: 0,
            afterTopRow: 16,
            lineSpacing: 16,
            bigRowSpacing: 16,
            linkSpacing: 8,
            chevronPointSize: 22,
            captionKern: 1.5,
            detailLines: 2,
            captionFont: .scaled(.caption2, size: 23, weight: .bold, maximum: 30),
            linkFont: .scaled(.caption1, size: 25, weight: .regular, maximum: 32),
            primaryFont: .scaled(.title1, size: 76, weight: .heavy, maximum: 96),
            unitFont: .scaled(.title3, size: 48, weight: .semibold),
            detailFont: .scaled(.callout, size: 31, weight: .regular)
        )
    )
}

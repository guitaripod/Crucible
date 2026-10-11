import CrucibleDesign
import CrucibleStats
import UIKit

/// The last 78 days as a three-row strip of ember squares, one column per week-third, drawn on the
/// ember gradient. Used by the Year in Review card and, on Apple TV, by the Statistics hero. With a
/// `cellWidth` the strip has that intrinsic width; without one the columns share whatever width the
/// view is given.
package final class HeatStripView: UIView {
    private let strip: StatsMetrics.HeatStrip

    package var levels: [Int] = [] {
        didSet { setNeedsDisplay() }
    }

    package init(strip: StatsMetrics.HeatStrip) {
        self.strip = strip
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
    }

    package convenience init(metrics: StatsMetrics = .platform) {
        self.init(strip: metrics.yearStrip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    package override var intrinsicContentSize: CGSize {
        let rows = CGFloat(YearInReviewSummary.stripRows)
        let height = rows * strip.cellHeight + (rows - 1) * strip.gap
        guard let cellWidth = strip.cellWidth else { return CGSize(width: UIView.noIntrinsicMetric, height: height) }
        let columns = CGFloat(YearInReviewSummary.stripColumns)
        return CGSize(width: columns * cellWidth + (columns - 1) * strip.gap, height: height)
    }

    package override func draw(_ rect: CGRect) {
        let columns = CGFloat(YearInReviewSummary.stripColumns)
        let cellWidth = strip.cellWidth ?? (bounds.width - (columns - 1) * strip.gap) / columns
        guard cellWidth > 0 else { return }
        let ramp = Theme.Color.emberStripRamp
        for (index, level) in levels.enumerated() {
            let column = CGFloat(index / YearInReviewSummary.stripRows)
            let row = CGFloat(index % YearInReviewSummary.stripRows)
            let frame = CGRect(
                x: column * (cellWidth + strip.gap),
                y: row * (strip.cellHeight + strip.gap),
                width: cellWidth,
                height: strip.cellHeight
            )
            ramp[max(0, min(ramp.count - 1, level))].setFill()
            UIBezierPath(roundedRect: frame, cornerRadius: strip.corner).fill()
        }
    }
}

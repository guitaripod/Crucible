import CrucibleDesign
import CrucibleStats
import UIKit

/// The last 78 days as a 26 by 3 strip of ember cells, drawn on the right of the hero the way the
/// You tab's Year in Review card does. Decorative: the heatmap below carries the real information.
final class TVHeatStripView: UIView {
    private static let cell: CGFloat = 26
    private static let gap: CGFloat = 7
    private static let corner: CGFloat = 6

    private static let ramp: [UIColor] = [
        UIColor.white.withAlphaComponent(0.12),
        UIColor(red: 1, green: 0.72, blue: 0.30, alpha: 0.38),
        UIColor(red: 1, green: 0.72, blue: 0.30, alpha: 0.56),
        UIColor(red: 1, green: 0.75, blue: 0.35, alpha: 0.76),
        UIColor(red: 1, green: 0.78, blue: 0.43, alpha: 0.92),
        UIColor(hex: 0xFFE0A6),
    ]

    private let levels: [Int]

    init(levels: [Int]) {
        self.levels = levels
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let columns = CGFloat(YearInReviewSummary.stripColumns)
        let rows = CGFloat(YearInReviewSummary.stripRows)
        return CGSize(
            width: columns * Self.cell + (columns - 1) * Self.gap,
            height: rows * Self.cell + (rows - 1) * Self.gap
        )
    }

    override func draw(_ rect: CGRect) {
        for (index, level) in levels.enumerated() {
            let column = CGFloat(index / YearInReviewSummary.stripRows)
            let row = CGFloat(index % YearInReviewSummary.stripRows)
            let frame = CGRect(
                x: column * (Self.cell + Self.gap),
                y: row * (Self.cell + Self.gap),
                width: Self.cell,
                height: Self.cell
            )
            Self.ramp[max(0, min(Self.ramp.count - 1, level))].setFill()
            UIBezierPath(roundedRect: frame, cornerRadius: Self.corner).fill()
        }
    }
}

import CrucibleDesign
import UIKit

/// A small solid circle that shows a status colour (route quality, connection state).
final class TVStatusDot: UIView {
    private let diameter: CGFloat

    init(color: UIColor, diameter: CGFloat = TVMetrics.Dot.small) {
        self.diameter = diameter
        super.init(frame: .zero)
        backgroundColor = color
        layer.cornerRadius = diameter / 2
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: diameter, height: diameter)
    }

    func setColor(_ color: UIColor) {
        backgroundColor = color
    }
}

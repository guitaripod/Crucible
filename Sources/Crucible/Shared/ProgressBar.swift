import UIKit

final class ProgressBar: UIView {
    var progress: Double = 0 {
        didSet { setNeedsLayout() }
    }

    private let trackLayer = CALayer()
    private let fillLayer = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        trackLayer.backgroundColor = UIColor.white.withAlphaComponent(0.1).cgColor
        trackLayer.cornerRadius = 2
        layer.addSublayer(trackLayer)

        fillLayer.colors = [
            UIColor.systemOrange.cgColor,
            UIColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 1.0).cgColor,
        ]
        fillLayer.startPoint = CGPoint(x: 0, y: 0.5)
        fillLayer.endPoint = CGPoint(x: 1, y: 0.5)
        fillLayer.cornerRadius = 2
        layer.addSublayer(fillLayer)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ProgressBar, _: UITraitCollection) in
            view.trackLayer.backgroundColor = UIColor.white.withAlphaComponent(0.1).cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 4)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        trackLayer.frame = bounds
        let clamped = max(0, min(1, progress))
        fillLayer.frame = CGRect(x: 0, y: 0, width: bounds.width * clamped, height: bounds.height)
    }
}

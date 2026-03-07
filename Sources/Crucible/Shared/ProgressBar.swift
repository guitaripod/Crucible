import UIKit

final class ProgressBar: UIView {
    var progress: Double = 0 {
        didSet { setNeedsLayout() }
    }

    private let trackLayer = CALayer()
    private let fillLayer = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        trackLayer.backgroundColor = UIColor.systemGray5.cgColor
        trackLayer.cornerRadius = 1.5
        layer.addSublayer(trackLayer)
        fillLayer.backgroundColor = UIColor.systemBlue.cgColor
        fillLayer.cornerRadius = 1.5
        layer.addSublayer(fillLayer)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ProgressBar, _: UITraitCollection) in
            view.trackLayer.backgroundColor = UIColor.systemGray5.cgColor
            view.fillLayer.backgroundColor = UIColor.systemBlue.cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 3)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        trackLayer.frame = bounds
        let clamped = max(0, min(1, progress))
        fillLayer.frame = CGRect(x: 0, y: 0, width: bounds.width * clamped, height: bounds.height)
    }
}

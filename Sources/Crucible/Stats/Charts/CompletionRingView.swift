import UIKit

/// Circular progress ring: a faint background track with an accent arc that sweeps
/// clockwise from 12 o'clock. Optionally renders a centred percent label.
final class CompletionRingView: UIView {

    /// Shows a centred percentage label inside the ring when `true` (default `false`).
    var showsPercentLabel: Bool = false {
        didSet {
            guard showsPercentLabel != oldValue else { return }
            percentLabel.isHidden = !showsPercentLabel
        }
    }

    private var progress: Double = 0

    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()

    private let percentLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        label.isHidden = true
        label.text = "0%"
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently

        configureRingLayer(trackLayer)
        configureRingLayer(progressLayer)
        progressLayer.strokeEnd = 0

        layer.addSublayer(trackLayer)
        layer.addSublayer(progressLayer)

        addSubview(percentLabel)
        NSLayoutConstraint.activate([
            percentLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            percentLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            percentLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9),
        ])

        refreshColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _: UITraitCollection) in
            view.refreshColors()
        }
        updatePercentLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    convenience init() { self.init(frame: .zero) }

    override var intrinsicContentSize: CGSize { CGSize(width: 46, height: 46) }

    /// Sets the ring fill to `fraction` (clamped to 0...1). When `animated` and Reduce
    /// Motion is off, the arc eases to its new length; otherwise it snaps.
    func setProgress(_ fraction: Double, animated: Bool) {
        let clamped = normalized(fraction)
        let previous = progress
        progress = clamped
        updatePercentLabel()

        let shouldAnimate = animated
            && !UIAccessibility.isReduceMotionEnabled
            && window != nil
            && abs(clamped - previous) > 0.0001

        if shouldAnimate {
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = previous
            animation.toValue = clamped
            animation.duration = 0.65
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            progressLayer.strokeEnd = CGFloat(clamped)
            progressLayer.add(animation, forKey: "progress")
        } else {
            setStrokeEndWithoutImplicitAnimation(CGFloat(clamped))
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }

        let outerRadius = side / 2
        let radius = outerRadius / 1.07
        let lineWidth = radius * 0.14
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let startAngle = -CGFloat.pi / 2
        let path = UIBezierPath(
            arcCenter: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: startAngle + 2 * .pi,
            clockwise: true
        ).cgPath

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [trackLayer, progressLayer] {
            shape.frame = bounds
            shape.path = path
            shape.lineWidth = lineWidth
        }
        CATransaction.commit()

        percentLabel.font = .systemFont(ofSize: max(9, radius * 0.55), weight: .bold)
    }

    private func configureRingLayer(_ shape: CAShapeLayer) {
        shape.fillColor = UIColor.clear.cgColor
        shape.lineCap = .round
        shape.strokeStart = 0
        shape.strokeEnd = 1
    }

    private func setStrokeEndWithoutImplicitAnimation(_ value: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLayer.removeAnimation(forKey: "progress")
        progressLayer.strokeEnd = value
        CATransaction.commit()
    }

    private func refreshColors() {
        trackLayer.strokeColor = UIColor.label.resolvedColor(with: traitCollection)
            .withAlphaComponent(0.15).cgColor
        progressLayer.strokeColor = StatsStyle.accent.resolvedColor(with: traitCollection).cgColor
        percentLabel.textColor = .label
    }

    private func updatePercentLabel() {
        let percent = Int((progress * 100).rounded())
        percentLabel.text = "\(percent)%"
        accessibilityValue = "\(percent)%"
    }

    private func normalized(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return min(1, max(0, fraction))
    }
}

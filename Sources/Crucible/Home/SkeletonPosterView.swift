import UIKit

/// A poster-shaped shimmer placeholder shown in Home rails on a genuinely-cold first launch
/// (no cached snapshot yet). Matches PosterContentView's card metrics so the hand-off to real
/// content produces no layout jump.
final class ShimmerView: UIView {
    private let highlight = CAGradientLayer()

    private static let baseColor = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.10)
            : UIColor.black.withAlphaComponent(0.08)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Self.baseColor
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true

        highlight.startPoint = CGPoint(x: 0, y: 0.5)
        highlight.endPoint = CGPoint(x: 1, y: 0.5)
        highlight.locations = [0, 0.5, 1]
        layer.addSublayer(highlight)
        applyHighlightColors()

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ShimmerView, _: UITraitCollection) in
            view.applyHighlightColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func applyHighlightColors() {
        let edge = UIColor.clear.cgColor
        let center = traitCollection.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.18).cgColor
            : UIColor.white.withAlphaComponent(0.55).cgColor
        highlight.colors = [edge, center, edge]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        highlight.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startAnimating()
        } else {
            highlight.removeAllAnimations()
            layer.removeAnimation(forKey: "pulse")
        }
    }

    private func startAnimating() {
        if UIAccessibility.isReduceMotionEnabled {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.5
            pulse.toValue = 1.0
            pulse.duration = 1.1
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            layer.add(pulse, forKey: "pulse")
            return
        }
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-1.0, -0.5, 0.0]
        sweep.toValue = [1.0, 1.5, 2.0]
        sweep.duration = 1.3
        sweep.repeatCount = .infinity
        highlight.add(sweep, forKey: "shimmer")
    }
}

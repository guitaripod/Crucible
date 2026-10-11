import CrucibleDesign
import UIKit

/// The loading state of a detail screen: soft blocks where the title, facts, synopsis, button and
/// first shelf will be. They pulse unless Reduce Motion is on.
final class TVDetailSkeletonView: UIView {
    private let blocks = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.Color.canvas
        isAccessibilityElement = true
        accessibilityLabel = "Loading"
        accessibilityIdentifier = "detail.loading"

        blocks.axis = .vertical
        blocks.alignment = .leading
        blocks.spacing = Theme.Space.m
        blocks.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blocks)
        for (width, height) in [(520.0, 64.0), (360.0, 28.0), (900.0, 26.0), (860.0, 26.0), (640.0, 26.0)] {
            blocks.addArrangedSubview(Self.block(width: width, height: height, radius: Theme.Radius.xs))
        }
        blocks.setCustomSpacing(Theme.Space.l, after: blocks.arrangedSubviews[1])
        blocks.setCustomSpacing(Theme.Space.l, after: blocks.arrangedSubviews[4])
        blocks.addArrangedSubview(Self.block(width: 360, height: TVMetrics.Control.primaryHeight, radius: TVMetrics.Control.primaryHeight / 2))

        let shelf = TVSkeletonShelfView(style: .person, count: 8)
        shelf.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shelf)
        NSLayoutConstraint.activate([
            blocks.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            blocks.bottomAnchor.constraint(equalTo: shelf.topAnchor, constant: -Theme.Space.l),
            shelf.leadingAnchor.constraint(equalTo: leadingAnchor),
            shelf.trailingAnchor.constraint(equalTo: trailingAnchor),
            shelf.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            blocks.layer.removeAllAnimations()
        } else {
            startPulsing()
        }
    }

    private func startPulsing() {
        guard !UIAccessibility.isReduceMotionEnabled, blocks.layer.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.55
        pulse.duration = TVMetrics.Duration.skeletonPulse
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        blocks.layer.add(pulse, forKey: "pulse")
    }

    private static func block(width: CGFloat, height: CGFloat, radius: CGFloat) -> UIView {
        let view = UIView()
        view.backgroundColor = Theme.Color.surfaceRaised
        view.layer.cornerRadius = radius
        view.layer.cornerCurve = .continuous
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: width),
            view.heightAnchor.constraint(equalToConstant: height),
        ])
        return view
    }
}

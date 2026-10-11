import CrucibleDesign
import UIKit

/// Placeholder shelf shown while a screen loads: static rounded rectangles in the raised-surface
/// colour that pulse softly. Reduce Motion keeps them still.
final class TVSkeletonShelfView: UIView {
    private let row = UIStackView()
    private let cardSize: CGSize

    init(style: TVCardStyle = .poster, count: Int = 8) {
        cardSize = style.artworkSize
        super.init(frame: .zero)
        row.axis = .horizontal
        row.spacing = TVMetrics.gutter
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        for _ in 0..<count {
            row.addArrangedSubview(makeCard(style))
        }
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: TVMetrics.shelfVerticalInset),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -TVMetrics.shelfVerticalInset),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "Loading"
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        window == nil ? stopPulsing() : startPulsing()
    }

    private func makeCard(_ style: TVCardStyle) -> UIView {
        let card = UIView()
        card.backgroundColor = Theme.Color.surfaceRaised
        card.layer.cornerRadius = style.shape == .circle ? style.artworkSize.width / 2 : TVMetrics.Card.cornerRadius
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: style.artworkSize.width),
            card.heightAnchor.constraint(equalToConstant: style.artworkSize.height),
        ])
        return card
    }

    private func startPulsing() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        row.layer.removeAllAnimations()
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.55
        pulse.duration = TVMetrics.Duration.skeletonPulse
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        row.layer.add(pulse, forKey: "pulse")
    }

    private func stopPulsing() {
        row.layer.removeAllAnimations()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(
            width: UIView.noIntrinsicMetric,
            height: cardSize.height + 2 * TVMetrics.shelfVerticalInset
        )
    }
}

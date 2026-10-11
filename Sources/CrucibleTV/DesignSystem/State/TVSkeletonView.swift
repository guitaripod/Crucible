import CrucibleDesign
import UIKit

/// Placeholder shelf shown while a screen loads: static rounded rectangles in the raised-surface
/// colour that pulse softly. The pulse stops while the view is hidden, under Reduce Motion and under
/// the UI-test switch (`TVMotion`).
final class TVSkeletonShelfView: TVPulsingView {
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

    override var pulsingLayer: CALayer { row.layer }

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

    override var intrinsicContentSize: CGSize {
        CGSize(
            width: UIView.noIntrinsicMetric,
            height: cardSize.height + 2 * TVMetrics.shelfVerticalInset
        )
    }
}

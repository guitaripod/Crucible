import CrucibleDesign
import CrucibleStats
import CrucibleStatsUI
import UIKit

/// The Year in Review card of the You tab: the shared `YearInReviewCardView` on a focusable surface.
/// Select opens Statistics.
final class TVYearCardView: TVFocusableSurface {
    private let card = YearInReviewCardView()

    init() {
        super.init(cornerRadius: Theme.Radius.l)
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.insertSubview(card, at: 0)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        accessibilityIdentifier = "you.yearCard"
        accessibilityHint = "Opens Statistics"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ summary: YearInReviewSummary) {
        card.configure(summary)
        accessibilityLabel = summary.spokenText
    }
}

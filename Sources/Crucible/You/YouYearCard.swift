import CrucibleDesign
import CrucibleStats
import CrucibleStatsUI
import UIKit

typealias YouYearSummary = YearInReviewSummary

struct YouYearCardContentConfiguration: UIContentConfiguration {
    var summary: YouYearSummary

    func makeContentView() -> UIView & UIContentView {
        YouYearCardContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> YouYearCardContentConfiguration {
        self
    }
}

final class YouYearCardContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let card = YearInReviewCardView()

    init(configuration: YouYearCardContentConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        build()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        layer.cornerRadius = Theme.Radius.l
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = Theme.Color.artHairline.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    private func apply() {
        guard let config = configuration as? YouYearCardContentConfiguration else { return }
        card.configure(config.summary)
        accessibilityLabel = config.summary.spokenText
    }
}

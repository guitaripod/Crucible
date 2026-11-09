import CrucibleCore
import CrucibleDesign
import UIKit

/// The top of an integration's settings screen before it is connected: the service's mark, the pitch's headline and the
/// short story of what connecting changes, read by VoiceOver as one element.
struct IntegrationHeroContentConfiguration: UIContentConfiguration {
    var mark: BrandMark
    var headline: String
    var story: String

    func makeContentView() -> UIView & UIContentView {
        IntegrationHeroContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> IntegrationHeroContentConfiguration { self }
}

private final class IntegrationHeroContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let markView = UIImageView()
    private let headlineLabel = UILabel()
    private let storyLabel = UILabel()

    init(configuration: IntegrationHeroContentConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        build()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 16, bottom: 18, trailing: 16)
        markView.contentMode = .scaleAspectFit
        markView.layer.cornerRadius = 12
        markView.layer.cornerCurve = .continuous
        markView.clipsToBounds = true
        markView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            markView.widthAnchor.constraint(equalToConstant: 52),
            markView.heightAnchor.constraint(equalToConstant: 52),
        ])

        headlineLabel.font = Theme.Font.title2
        headlineLabel.textColor = Theme.Color.label
        headlineLabel.numberOfLines = 0
        headlineLabel.adjustsFontForContentSizeCategory = true

        storyLabel.font = Theme.Font.subheadline
        storyLabel.textColor = Theme.Color.labelSecondary
        storyLabel.numberOfLines = 0
        storyLabel.adjustsFontForContentSizeCategory = true

        let stack = UIStackView(arrangedSubviews: [markView, headlineLabel, storyLabel])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: markView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let margins = layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: margins.topAnchor),
            stack.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .header
    }

    private func apply() {
        guard let config = configuration as? IntegrationHeroContentConfiguration else { return }
        markView.image = config.mark.image
        headlineLabel.text = config.headline
        storyLabel.text = config.story
        accessibilityLabel = [config.headline, config.story].joined(separator: ". ")
    }
}

extension IconRowContentConfiguration {
    /// One benefit of an integration's pitch: its symbol in the accent colour, its title and detail, and a Pro badge when it
    /// needs Crucible Pro.
    init(benefit: IntegrationPitch.Benefit) {
        self.init(symbol: benefit.symbol, title: benefit.title, subtitle: benefit.detail)
        symbolColor = Theme.Color.accent
        badge = benefit.needsPro ? IntegrationPitch.proBadge : nil
    }
}

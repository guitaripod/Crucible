import CrucibleDesign
import UIKit

/// The card at the top of the tour: how far along the user is, a bar for it, and a line that says everything here is fictional.
struct DemoProgressContentConfiguration: UIContentConfiguration {
    var progressText: String
    var fraction: Double
    var caption: String

    func makeContentView() -> UIView & UIContentView {
        DemoProgressContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> DemoProgressContentConfiguration {
        self
    }
}

final class DemoProgressContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let progressLabel = UILabel()
    private let bar = ProgressBar()
    private let captionLabel = UILabel()

    init(configuration: DemoProgressContentConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        build()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)

        progressLabel.font = Theme.Font.title2
        progressLabel.textColor = Theme.Color.label
        captionLabel.font = Theme.Font.caption1Regular
        captionLabel.textColor = Theme.Color.labelSecondary
        for label in [progressLabel, captionLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        bar.style = .onSurface

        let stack = UIStackView(arrangedSubviews: [progressLabel, bar, captionLabel])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
        ])
        isAccessibilityElement = true
    }

    private func apply() {
        guard let config = configuration as? DemoProgressContentConfiguration else { return }
        progressLabel.text = config.progressText
        bar.progress = config.fraction
        captionLabel.text = config.caption
        accessibilityLabel = "\(config.progressText). \(config.caption)"
    }
}

import CrucibleDesign
import UIKit

struct YouProfileContentConfiguration: UIContentConfiguration {
    var name: String
    var statusText: String
    var statusColor: UIColor

    func makeContentView() -> UIView & UIContentView {
        YouProfileContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> YouProfileContentConfiguration {
        self
    }
}

final class YouProfileContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let avatar = MonogramView()
    private let nameLabel = UILabel()
    private let statusDot = UIView()
    private let statusLabel = UILabel()

    init(configuration: YouProfileContentConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        build()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)

        nameLabel.font = Theme.Font.title3
        nameLabel.textColor = Theme.Color.label
        nameLabel.numberOfLines = 0
        nameLabel.adjustsFontForContentSizeCategory = true

        statusDot.layer.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
        ])
        statusLabel.font = Theme.Font.footnote
        statusLabel.textColor = Theme.Color.labelSecondary
        statusLabel.numberOfLines = 0
        statusLabel.adjustsFontForContentSizeCategory = true

        let statusRow = UIStackView(arrangedSubviews: [statusDot, statusLabel])
        statusRow.axis = .horizontal
        statusRow.spacing = 6
        statusRow.alignment = .center

        let textStack = UIStackView(arrangedSubviews: [nameLabel, statusRow])
        textStack.axis = .vertical
        textStack.spacing = 2

        let root = UIStackView(arrangedSubviews: [avatar, textStack])
        root.axis = .horizontal
        root.spacing = 12
        root.alignment = .center
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            root.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
        ])
        isAccessibilityElement = true
    }

    private func apply() {
        guard let config = configuration as? YouProfileContentConfiguration else { return }
        avatar.configure(name: config.name)
        nameLabel.text = config.name
        statusLabel.text = config.statusText
        statusDot.backgroundColor = config.statusColor
        accessibilityLabel = "\(config.name), \(config.statusText)"
    }
}

import CrucibleCore
import CrucibleDesign
import UIKit

/// The account at the top of the You tab: a monogram, the account name and one status line for the
/// server with a dot coloured by the connection's health.
final class TVProfilePanelView: TVReadOnlyPanel {
    private let avatar = MonogramView()
    private let nameLabel = UILabel()
    private let statusDot = TVStatusDot(color: Theme.Color.labelTertiary)
    private let statusLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ profile: YouProfile) {
        avatar.configure(name: profile.name)
        nameLabel.text = profile.name
        statusLabel.text = profile.statusText
        statusDot.setColor(profile.tone.color)
        accessibilityLabel = "\(profile.name), \(profile.statusText)"
    }

    private func build() {
        nameLabel.font = Theme.Font.title2
        nameLabel.textColor = Theme.Color.label
        nameLabel.numberOfLines = 2
        nameLabel.adjustsFontSizeToFitWidth = true
        nameLabel.minimumScaleFactor = 0.6

        statusLabel.font = Theme.Font.callout
        statusLabel.textColor = Theme.Color.labelSecondary
        statusLabel.numberOfLines = 2

        let statusRow = UIStackView(arrangedSubviews: [statusDot, statusLabel])
        statusRow.axis = .horizontal
        statusRow.spacing = Theme.Space.xs
        statusRow.alignment = .center

        let text = UIStackView(arrangedSubviews: [nameLabel, statusRow])
        text.axis = .vertical
        text.spacing = Theme.Space.xs
        text.alignment = .leading

        let root = UIStackView(arrangedSubviews: [avatar, text])
        root.axis = .vertical
        root.spacing = Theme.Space.m
        root.alignment = .leading
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        accessibilityIdentifier = "you.profile"
    }
}

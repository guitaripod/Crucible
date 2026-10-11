import CrucibleCore
import CrucibleDesign
import UIKit

/// The account at the top of the You tab: a monogram, the account name and one status line for the
/// server with a dot coloured by the connection's health.
final class TVProfilePanelView: UIView {
    private static let avatarDiameter: CGFloat = 150

    private let avatar = TVMonogramView()
    private let nameLabel = UILabel()
    private let statusDot = UIView()
    private let statusLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ profile: YouProfile) {
        avatar.setInitial(from: profile.name)
        nameLabel.text = profile.name
        statusLabel.text = profile.statusText
        statusDot.backgroundColor = profile.tone.color
        accessibilityLabel = "\(profile.name), \(profile.statusText)"
    }

    private func build() {
        nameLabel.font = Theme.Font.title2
        nameLabel.textColor = Theme.Color.label
        nameLabel.numberOfLines = 2
        nameLabel.adjustsFontSizeToFitWidth = true
        nameLabel.minimumScaleFactor = 0.6

        statusDot.layer.cornerRadius = 8
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 16),
            statusDot.heightAnchor.constraint(equalToConstant: 16),
        ])
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
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            avatar.widthAnchor.constraint(equalToConstant: Self.avatarDiameter),
            avatar.heightAnchor.constraint(equalToConstant: Self.avatarDiameter),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityIdentifier = "you.profile"
    }
}

/// The initial of the account name on the brand ember gradient.
final class TVMonogramView: UIView {
    private let gradient = CAGradientLayer()
    private let initialLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        gradient.colors = [UIColor(hex: 0x2B2455).cgColor, UIColor(hex: 0xB0483F).cgColor, UIColor(hex: 0xF2A057).cgColor]
        gradient.locations = [0, 0.62, 1]
        gradient.startPoint = CGPoint(x: 0.43, y: 0)
        gradient.endPoint = CGPoint(x: 0.57, y: 1)
        layer.insertSublayer(gradient, at: 0)
        layer.masksToBounds = true
        layer.borderWidth = 2
        layer.borderColor = Theme.Color.artHairline.cgColor

        initialLabel.font = Theme.Font.scaled(.title1, 76, .bold, maximum: 90)
        initialLabel.textColor = Theme.Color.onArt
        initialLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(initialLabel)
        NSLayoutConstraint.activate([
            initialLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            initialLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        layer.cornerRadius = bounds.width / 2
    }

    func setInitial(from name: String) {
        initialLabel.text = name.first.map { String($0).uppercased() } ?? "?"
    }
}

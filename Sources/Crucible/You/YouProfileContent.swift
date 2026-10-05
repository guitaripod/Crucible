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

private final class AvatarView: UIView {
    private let gradient = CAGradientLayer()
    private let initialLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        gradient.colors = [UIColor(hex: 0x2B2455).cgColor, UIColor(hex: 0xB0483F).cgColor, UIColor(hex: 0xF2A057).cgColor]
        gradient.locations = [0, 0.62, 1]
        gradient.startPoint = CGPoint(x: 0.43, y: 0)
        gradient.endPoint = CGPoint(x: 0.57, y: 1)
        layer.insertSublayer(gradient, at: 0)
        layer.cornerRadius = 28
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = Theme.Color.artHairline.cgColor
        initialLabel.font = Theme.Font.scaled(.title1, 24, .bold, maximum: 30)
        initialLabel.textColor = Theme.Color.onArt
        initialLabel.adjustsFontForContentSizeCategory = true
        initialLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(initialLabel)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 56),
            heightAnchor.constraint(equalToConstant: 56),
            initialLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            initialLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }

    func setInitial(from name: String) {
        initialLabel.text = name.first.map { String($0).uppercased() } ?? "?"
    }
}

final class YouProfileContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let avatar = AvatarView()
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
        avatar.setInitial(from: config.name)
        nameLabel.text = config.name
        statusLabel.text = config.statusText
        statusDot.backgroundColor = config.statusColor
        accessibilityLabel = "\(config.name), \(config.statusText)"
    }
}

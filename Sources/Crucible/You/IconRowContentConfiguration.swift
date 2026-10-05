import UIKit

/// Grouped-list row: a 32pt neutral icon well, title with optional badge and subtitle, and an optional
/// trailing value. When `menu` is set the whole row is a menu button.
struct IconRowContentConfiguration: UIContentConfiguration {
    var symbol: String
    var title: String
    var subtitle: String?
    var badge: String?
    var value: String?
    var menu: UIMenu?
    var exposesToAccessibility = true

    func makeContentView() -> UIView & UIContentView {
        IconRowContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> IconRowContentConfiguration {
        self
    }
}

final class IconRowContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let wellView = UIView()
    private let wellImage = UIImageView()
    private let titleLabel = UILabel()
    private let badgeLabel = UILabel()
    private let badgeContainer = UIView()
    private let subtitleLabel = UILabel()
    private let valueLabel = UILabel()
    private let menuChevron = UIImageView()
    private let menuButton = UIButton(configuration: .plain())

    init(configuration: IconRowContentConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        build()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)

        wellView.backgroundColor = Theme.Color.surfaceRaised
        wellView.layer.cornerRadius = 9
        wellView.layer.cornerCurve = .continuous
        wellImage.tintColor = Theme.Color.labelSecondary
        wellImage.contentMode = .center
        wellImage.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        wellImage.translatesAutoresizingMaskIntoConstraints = false
        wellView.addSubview(wellImage)
        wellView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            wellView.widthAnchor.constraint(equalToConstant: 32),
            wellView.heightAnchor.constraint(equalToConstant: 32),
            wellImage.centerXAnchor.constraint(equalTo: wellView.centerXAnchor),
            wellImage.centerYAnchor.constraint(equalTo: wellView.centerYAnchor),
        ])

        titleLabel.font = Theme.Font.callout
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true

        badgeLabel.font = Theme.Font.scaled(.caption2, 10, .heavy, maximum: 14)
        badgeLabel.textColor = Theme.Color.onAccent
        badgeLabel.adjustsFontForContentSizeCategory = true
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.backgroundColor = Theme.Color.accent
        badgeContainer.layer.cornerRadius = 5
        badgeContainer.layer.cornerCurve = .continuous
        badgeContainer.addSubview(badgeLabel)
        NSLayoutConstraint.activate([
            badgeLabel.topAnchor.constraint(equalTo: badgeContainer.topAnchor, constant: 2),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeContainer.bottomAnchor, constant: -2),
            badgeLabel.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 6),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -6),
        ])
        badgeContainer.setContentHuggingPriority(.required, for: .horizontal)
        badgeContainer.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.fittingSizeLevel, for: .horizontal)
        let titleRow = UIStackView(arrangedSubviews: [titleLabel, badgeContainer, spacer])
        titleRow.axis = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .center

        subtitleLabel.font = Theme.Font.caption1Regular
        subtitleLabel.textColor = Theme.Color.labelSecondary
        subtitleLabel.numberOfLines = 0
        subtitleLabel.adjustsFontForContentSizeCategory = true

        let textStack = UIStackView(arrangedSubviews: [titleRow, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        valueLabel.font = Theme.Font.subheadline
        valueLabel.textColor = Theme.Color.labelSecondary
        valueLabel.textAlignment = .right
        valueLabel.numberOfLines = 0
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(UILayoutPriority(751), for: .horizontal)

        menuChevron.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        menuChevron.tintColor = Theme.Color.labelTertiary
        menuChevron.setContentHuggingPriority(.required, for: .horizontal)
        menuChevron.setContentCompressionResistancePriority(.required, for: .horizontal)

        let trailing = UIStackView(arrangedSubviews: [valueLabel, menuChevron])
        trailing.axis = .horizontal
        trailing.spacing = 4
        trailing.alignment = .center

        let root = UIStackView(arrangedSubviews: [wellView, textStack, trailing])
        root.axis = .horizontal
        root.spacing = 12
        root.alignment = .center
        root.isUserInteractionEnabled = false
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            root.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
        ])

        menuButton.showsMenuAsPrimaryAction = true
        menuButton.configurationUpdateHandler = { button in
            var config = button.configuration
            config?.background.backgroundColor = button.isHighlighted ? Theme.Color.separator : .clear
            button.configuration = config
        }
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(menuButton)
        NSLayoutConstraint.activate([
            menuButton.topAnchor.constraint(equalTo: topAnchor),
            menuButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            menuButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func apply() {
        guard let config = configuration as? IconRowContentConfiguration else { return }
        wellImage.image = UIImage(systemName: config.symbol)
        titleLabel.text = config.title
        subtitleLabel.text = config.subtitle
        subtitleLabel.isHidden = config.subtitle == nil
        badgeContainer.isHidden = config.badge == nil
        badgeLabel.attributedText = config.badge.map {
            NSAttributedString(string: $0, attributes: [.kern: 0.8])
        }
        valueLabel.text = config.value
        valueLabel.isHidden = config.value == nil
        menuChevron.isHidden = config.menu == nil

        let spoken = [config.title, config.badge, config.subtitle, config.value].compactMap { $0 }.joined(separator: ", ")
        menuButton.menu = config.menu
        menuButton.isHidden = config.menu == nil
        menuButton.isAccessibilityElement = config.menu != nil && config.exposesToAccessibility
        menuButton.accessibilityLabel = spoken
        menuButton.accessibilityHint = "Opens a menu"
        isAccessibilityElement = config.menu == nil && config.exposesToAccessibility
        accessibilityLabel = spoken
    }
}

extension UICollectionViewListCell {
    /// Surface-coloured card background that darkens while pressed, shared by every grouped list.
    func applyThemedBackground() {
        configurationUpdateHandler = { cell, state in
            var background = Theme.groupedCellBackground()
            if state.isHighlighted || state.isSelected {
                background.backgroundColor = Theme.Color.surfaceRaised
            }
            cell.backgroundConfiguration = background
        }
    }
}

extension UICollectionLayoutListConfiguration {
    /// Theme grouped list whose separators start at the text edge of icon-well rows.
    @MainActor static func wellRows() -> UICollectionLayoutListConfiguration {
        var config = Theme.groupedListConfiguration()
        config.headerMode = .none
        config.footerMode = .none
        config.itemSeparatorHandler = { _, separator in
            var separator = separator
            separator.bottomSeparatorInsets.leading = 60
            separator.color = Theme.Color.separator
            return separator
        }
        return config
    }
}

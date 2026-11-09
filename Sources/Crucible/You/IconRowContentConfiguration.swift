import CrucibleDesign
import UIKit

/// Grouped-list row: a 32pt neutral icon well, title with optional badge and subtitle, and an optional
/// value. The value is never cut short: it sits at the trailing edge while it fits there beside a one-line
/// title, and moves under the title and subtitle when it would not or the text is extra large.
/// When `menu` is set the whole row is a menu button.
struct IconRowContentConfiguration: UIContentConfiguration {
    struct Toggle {
        var isOn: Bool
        var isEnabled = true
        var onChange: (Bool) -> Void
    }

    var symbol: String
    /// The symbol's colour, when it carries meaning such as a step that is done.
    var symbolColor: UIColor?
    /// A service's official mark in place of the symbol, filling the icon well.
    var brand: BrandMark?
    var title: String
    var subtitle: String?
    var badge: String?
    var value: String?
    var menu: UIMenu?
    var toggle: Toggle?
    var exposesToAccessibility = true
    /// The row opens a screen or runs an action, so VoiceOver calls it a button.
    var isActionable = false

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
    private let brandView = UIImageView()
    private let wellImage = UIImageView()
    private let titleLabel = UILabel()
    private let badgeLabel = UILabel()
    private let badgeContainer = UIView()
    private let subtitleLabel = UILabel()
    private let valueLabel = UILabel()
    private let menuChevron = UIImageView()
    private let toggleSwitch = UISwitch()
    private let rootStack = UIStackView()
    private let textStack = UIStackView()
    private let trailingStack = UIStackView()
    private let menuButton = UIButton(configuration: .plain())
    private var valueStacked = false

    /// The most of the row's text width a trailing value may take before it moves under the title.
    private static let trailingShare: CGFloat = 0.42

    init(configuration: IconRowContentConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
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
        brandView.contentMode = .scaleAspectFit
        brandView.translatesAutoresizingMaskIntoConstraints = false
        wellView.addSubview(brandView)
        wellView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            wellView.widthAnchor.constraint(equalToConstant: 32),
            wellView.heightAnchor.constraint(equalToConstant: 32),
            wellImage.centerXAnchor.constraint(equalTo: wellView.centerXAnchor),
            wellImage.centerYAnchor.constraint(equalTo: wellView.centerYAnchor),
            brandView.topAnchor.constraint(equalTo: wellView.topAnchor),
            brandView.bottomAnchor.constraint(equalTo: wellView.bottomAnchor),
            brandView.leadingAnchor.constraint(equalTo: wellView.leadingAnchor),
            brandView.trailingAnchor.constraint(equalTo: wellView.trailingAnchor),
        ])

        titleLabel.font = Theme.Font.callout
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

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
        subtitleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        [titleRow, subtitleLabel].forEach(textStack.addArrangedSubview)
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        valueLabel.font = Theme.Font.subheadline
        valueLabel.textColor = Theme.Color.labelSecondary
        valueLabel.textAlignment = .right
        valueLabel.numberOfLines = 1
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        menuChevron.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        menuChevron.tintColor = Theme.Color.labelTertiary
        menuChevron.setContentHuggingPriority(.required, for: .horizontal)
        menuChevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        menuChevron.contentMode = .center
        menuChevron.widthAnchor.constraint(equalToConstant: menuChevron.image?.size.width ?? 12).isActive = true

        toggleSwitch.onTintColor = Theme.Color.accent
        toggleSwitch.setContentHuggingPriority(.required, for: .horizontal)
        toggleSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        toggleSwitch.addAction(UIAction { [weak self] _ in
            guard let self, let toggle = (configuration as? IconRowContentConfiguration)?.toggle else { return }
            Haptics.selection()
            toggle.onChange(toggleSwitch.isOn)
        }, for: .valueChanged)

        let trailing = trailingStack
        [valueLabel, menuChevron, toggleSwitch].forEach(trailing.addArrangedSubview)
        trailing.axis = .horizontal
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailing.spacing = 4
        trailing.alignment = .center

        let root = rootStack
        [wellView, textStack, trailing].forEach { root.addArrangedSubview($0) }
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

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: IconRowContentView, _: UITraitCollection) in
            view.placeValue()
        }
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.isPointerInteractionEnabled = true
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
        wellImage.image = config.brand == nil ? UIImage(systemName: config.symbol) : nil
        wellImage.tintColor = config.symbolColor ?? Theme.Color.labelSecondary
        brandView.image = config.brand?.image
        brandView.isHidden = config.brand == nil
        wellView.backgroundColor = config.brand == nil ? Theme.Color.surfaceRaised : .clear
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
        toggleSwitch.isHidden = config.toggle == nil
        placeValue()
        hideEmptyTrailing()
        rootStack.isUserInteractionEnabled = config.toggle != nil
        if let toggle = config.toggle {
            toggleSwitch.setOn(toggle.isOn, animated: false)
            toggleSwitch.isEnabled = toggle.isEnabled
        }

        let spoken = [config.title, config.badge, config.subtitle, config.value].compactMap { $0 }.joined(separator: ", ")
        menuButton.menu = config.menu
        menuButton.isHidden = config.menu == nil
        menuButton.isAccessibilityElement = config.menu != nil && config.exposesToAccessibility
        menuButton.accessibilityLabel = spoken
        menuButton.accessibilityHint = String(localized: "Opens a menu")
        toggleSwitch.accessibilityLabel = config.title
        toggleSwitch.accessibilityHint = config.subtitle
        isAccessibilityElement = config.menu == nil && config.toggle == nil && config.exposesToAccessibility
        accessibilityElements = config.toggle == nil ? nil : [toggleSwitch]
        accessibilityLabel = spoken
        accessibilityTraits = config.isActionable && config.menu == nil && config.toggle == nil ? .button : []
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeValue()
    }

    /// Puts the value beside the text or under it (`trailingShare`), and has the cell size itself again when that changes.
    private func placeValue() {
        let stacked = valueStacks()
        guard stacked != valueStacked else { return }
        valueStacked = stacked
        valueLabel.removeFromSuperview()
        if stacked {
            textStack.addArrangedSubview(valueLabel)
            valueLabel.textAlignment = .natural
            valueLabel.numberOfLines = 0
        } else {
            trailingStack.insertArrangedSubview(valueLabel, at: 0)
            valueLabel.textAlignment = .right
            valueLabel.numberOfLines = 1
        }
        hideEmptyTrailing()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// A trailing stack with nothing to show leaves the row, so it cannot take the text's width.
    private func hideEmptyTrailing() {
        trailingStack.isHidden = trailingStack.arrangedSubviews.allSatisfy(\.isHidden)
    }

    /// Whether the value would take more than its share of the room the text has, or push the title onto a second line;
    /// both are measured on one line.
    private func valueStacks() -> Bool {
        guard let value = valueLabel.text, !value.isEmpty, !valueLabel.isHidden else { return false }
        if traitCollection.preferredContentSizeCategory.isAccessibilityCategory { return true }
        let width = bounds.width > 0 ? bounds.width : window?.bounds.width ?? 0
        guard width > 0 else { return false }
        var room = width - directionalLayoutMargins.leading - directionalLayoutMargins.trailing - 32 - rootStack.spacing
        if !menuChevron.isHidden { room -= menuChevron.intrinsicContentSize.width + trailingStack.spacing }
        if !toggleSwitch.isHidden { room -= toggleSwitch.intrinsicContentSize.width + trailingStack.spacing }
        let valueWidth = (value as NSString).size(withAttributes: [.font: valueLabel.font as Any]).width.rounded(.up)
        guard valueWidth <= room * Self.trailingShare else { return true }
        var titleWidth = ((titleLabel.text ?? "") as NSString).size(withAttributes: [.font: titleLabel.font as Any]).width.rounded(.up)
        if !badgeContainer.isHidden { titleWidth += badgeContainer.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width + 8 }
        return titleWidth + rootStack.spacing + valueWidth > room
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

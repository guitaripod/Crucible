import CrucibleDesign
import UIKit

/// View data of a settings-style row: icon well, title, optional subtitle, optional value and an
/// accessory. tvOS has no switch control, so a toggle is a row whose value reads On/Off and flips on Select.
struct TVRowItem: Hashable, Sendable {
    enum Accessory: Hashable, Sendable {
        case none
        case chevron
        case checkmark
    }

    var id: String
    var title: String
    var subtitle: String?
    var value: String?
    var symbol: String?
    var accessory: Accessory
    var isDestructive: Bool
    var isEnabled: Bool
    var isStatic: Bool

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        symbol: String? = nil,
        accessory: Accessory = .none,
        isDestructive: Bool = false,
        isEnabled: Bool = true,
        isStatic: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.symbol = symbol
        self.accessory = accessory
        self.isDestructive = isDestructive
        self.isEnabled = isEnabled
        self.isStatic = isStatic
    }
}

struct TVRowConfiguration: UIContentConfiguration, Hashable {
    var item: TVRowItem
    var isFocused = false

    func makeContentView() -> UIView & UIContentView {
        TVRowContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> TVRowConfiguration {
        var copy = self
        copy.isFocused = (state as? UICellConfigurationState)?.isFocused ?? false
        return copy
    }
}

final class TVRowContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let plate = UIView()
    private let iconWell = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let valueLabel = UILabel()
    private let accessoryView = UIImageView()

    init(configuration: TVRowConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        buildHierarchy()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildHierarchy() {
        plate.layer.cornerRadius = Theme.Radius.m
        plate.layer.cornerCurve = .continuous
        plate.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plate)

        iconWell.layer.cornerRadius = Theme.Radius.s
        iconWell.layer.cornerCurve = .continuous
        iconView.contentMode = .center
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: TVMetrics.Symbol.row, weight: .semibold)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconWell.addSubview(iconView)

        titleLabel.font = TVFont.rowTitle
        subtitleLabel.font = TVFont.cardSubtitle
        let text = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        text.axis = .vertical
        text.spacing = 2

        valueLabel.font = Theme.Font.callout
        valueLabel.textAlignment = .right
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        accessoryView.contentMode = .center
        accessoryView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: TVMetrics.Symbol.accessory, weight: .semibold)
        accessoryView.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [iconWell, text, UIView(), valueLabel, accessoryView])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Space.m
        row.insetsLayoutMarginsFromSafeArea = false
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 0, left: TVMetrics.Row.horizontalInset, bottom: 0, right: TVMetrics.Row.horizontalInset)
        row.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(row)

        NSLayoutConstraint.activate([
            plate.topAnchor.constraint(equalTo: topAnchor),
            plate.bottomAnchor.constraint(equalTo: bottomAnchor),
            plate.leadingAnchor.constraint(equalTo: leadingAnchor),
            plate.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: plate.topAnchor),
            row.bottomAnchor.constraint(equalTo: plate.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: plate.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: plate.trailingAnchor),
            plate.heightAnchor.constraint(greaterThanOrEqualToConstant: TVMetrics.Row.height),
            iconWell.widthAnchor.constraint(equalToConstant: TVMetrics.Row.iconWell),
            iconWell.heightAnchor.constraint(equalToConstant: TVMetrics.Row.iconWell),
            iconView.centerXAnchor.constraint(equalTo: iconWell.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconWell.centerYAnchor),
        ])
    }

    private func apply() {
        guard let configuration = configuration as? TVRowConfiguration else { return }
        let item = configuration.item
        let focused = configuration.isFocused
        let primary = focused ? TVColor.onFocusFill : (item.isDestructive ? Theme.Color.destructive : Theme.Color.label)
        let secondary = focused ? TVColor.onFocusFillSecondary : Theme.Color.labelSecondary

        plate.backgroundColor = focused ? TVColor.focusFill : Theme.Color.surfaceRaised
        titleLabel.text = item.title
        titleLabel.textColor = primary
        subtitleLabel.text = item.subtitle
        subtitleLabel.textColor = secondary
        subtitleLabel.isHidden = (item.subtitle ?? "").isEmpty
        valueLabel.text = item.value
        valueLabel.textColor = secondary
        valueLabel.isHidden = (item.value ?? "").isEmpty

        iconWell.isHidden = item.symbol == nil
        iconWell.backgroundColor = focused ? TVColor.onFocusFill.withAlphaComponent(0.08) : Theme.Color.accentTint
        iconView.image = item.symbol.flatMap { UIImage(systemName: $0) }
        iconView.tintColor = item.isDestructive ? Theme.Color.destructive : Theme.Color.accentText

        switch item.accessory {
        case .none:
            accessoryView.isHidden = true
        case .chevron:
            accessoryView.isHidden = false
            accessoryView.image = UIImage(systemName: "chevron.right")
            accessoryView.tintColor = secondary
        case .checkmark:
            accessoryView.isHidden = false
            accessoryView.image = UIImage(systemName: "checkmark")
            accessoryView.tintColor = focused ? TVColor.onFocusFill : Theme.Color.accentText
        }
        alpha = item.isEnabled ? 1 : 0.45
    }
}

/// A focusable list row. Use with `TVRowList.layout()` (a plain cell in a list layout, so tvOS draws
/// no default list highlight behind it); it lifts and scales with the focus
/// animation, like the system Settings rows.
final class TVRowCell: UICollectionViewCell {
    private(set) var item: TVRowItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        clipsToBounds = false
        contentView.clipsToBounds = false
        isAccessibilityElement = true
        TVFocusLift.prepare(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func registration() -> UICollectionView.CellRegistration<TVRowCell, TVRowItem> {
        UICollectionView.CellRegistration<TVRowCell, TVRowItem> { cell, _, item in
            cell.configure(with: item)
        }
    }

    func configure(with item: TVRowItem) {
        self.item = item
        contentConfiguration = TVRowConfiguration(item: item)
        accessibilityLabel = [item.title, item.subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        accessibilityValue = item.value
        if item.isStatic {
            accessibilityTraits = .staticText
        } else {
            accessibilityTraits = item.isEnabled ? .button : [.button, .notEnabled]
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        TVFocusLift.animate(self, focused: context.nextFocusedView === self, with: coordinator)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        TVFocusLift.updateShadowPath(of: self, cornerRadius: Theme.Radius.m)
    }
}

enum TVRowList {
    /// A single-column list of `TVRowCell`s: no separators, 12pt apart, content inset by the screen.
    @MainActor
    static func layout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, environment in
            section(environment: environment)
        }
    }

    @MainActor
    static func section(environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.backgroundColor = .clear
        let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        section.interGroupSpacing = TVMetrics.Row.spacing
        section.contentInsets = NSDirectionalEdgeInsets(top: TVMetrics.shelfVerticalInset, leading: 0, bottom: TVMetrics.shelfVerticalInset, trailing: 0)
        return section
    }
}

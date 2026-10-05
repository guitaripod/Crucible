import UIKit

extension UIStackView {
    /// A vertical or horizontal stack that pins to its container with the given insets.
    @MainActor
    func pin(to container: UIView, insets: NSDirectionalEdgeInsets) {
        translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom),
            leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.leading),
            trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.trailing),
        ])
    }
}

/// The 32pt rounded-square symbol well used by action rows.
@MainActor
final class SymbolWellView: UIView {
    private let imageView = UIImageView()

    init(symbol: String, tint: UIColor = Theme.Color.labelSecondary, size: CGFloat = 32, cornerRadius: CGFloat = 9, pointSize: CGFloat = 16) {
        super.init(frame: .zero)
        backgroundColor = Theme.Color.surfaceRaised
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        imageView.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium))
        imageView.tintColor = tint
        imageView.contentMode = .center
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

struct ServerCardConfiguration: UIContentConfiguration {
    var name: String
    var subtitle: String
    var status: String
    var statusColor: UIColor?

    func makeContentView() -> UIView & UIContentView { ServerCardContentView(configuration: self) }
    func updated(for state: UIConfigurationState) -> ServerCardConfiguration { self }
}

final class ServerCardContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration { didSet { apply() } }

    private let nameLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let statusLabel = UILabel()
    private let dot = UIView()

    init(configuration: ServerCardConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)

        let well = SymbolWellView(symbol: "server.rack", size: 48, cornerRadius: 14, pointSize: 24)

        nameLabel.font = Theme.Font.title3
        nameLabel.textColor = Theme.Color.label
        subtitleLabel.font = Theme.Font.footnote
        subtitleLabel.textColor = Theme.Color.labelSecondary
        for label in [nameLabel, subtitleLabel, statusLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        statusLabel.font = Theme.Font.scaled(.subheadline, 14, .semibold)
        statusLabel.textColor = Theme.Color.label

        let texts = UIStackView(arrangedSubviews: [nameLabel, subtitleLabel])
        texts.axis = .vertical
        texts.spacing = 2

        let top = UIStackView(arrangedSubviews: [well, texts])
        top.spacing = 14
        top.alignment = .center

        dot.layer.cornerRadius = 4.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 9),
            dot.heightAnchor.constraint(equalToConstant: 9),
        ])
        let dotHolder = UIStackView(arrangedSubviews: [dot])
        dotHolder.alignment = .center
        dotHolder.isAccessibilityElement = false

        let statusRow = UIStackView(arrangedSubviews: [dotHolder, statusLabel])
        statusRow.spacing = 8
        statusRow.alignment = .center

        let root = UIStackView(arrangedSubviews: [top, statusRow])
        root.axis = .vertical
        root.spacing = 14
        root.pin(to: self, insets: NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))

        isAccessibilityElement = true
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? ServerCardConfiguration else { return }
        nameLabel.text = config.name
        subtitleLabel.text = config.subtitle
        statusLabel.text = config.status
        dot.backgroundColor = config.statusColor
        dot.superview?.isHidden = config.statusColor == nil
        accessibilityLabel = config.name
        accessibilityValue = "\(config.subtitle). \(config.status)"
    }
}

struct RouteRowConfiguration: UIContentConfiguration {
    var kindTitle: String
    var isInUse: Bool
    var detail: String
    var detailIsMonospaced: Bool
    var latencyText: String
    var showsWarning: Bool
    var isDimmed: Bool

    func makeContentView() -> UIView & UIContentView { RouteRowContentView(configuration: self) }
    func updated(for state: UIConfigurationState) -> RouteRowConfiguration { self }
}

final class RouteRowContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration { didSet { apply() } }

    private let kindLabel = UILabel()
    private let inUseLabel = UILabel()
    private let detailLabel = UILabel()
    private let warningIcon = UIImageView()
    private let latencyLabel = UILabel()
    private let checkIcon = UIImageView()

    init(configuration: RouteRowConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)

        kindLabel.font = Theme.Font.scaled(.body, 16, .semibold)
        kindLabel.textColor = Theme.Color.label
        inUseLabel.font = Theme.Font.scaled(.caption2, 11, .bold, maximum: 15)
        inUseLabel.textColor = Theme.Color.accentText
        inUseLabel.text = "IN USE"
        inUseLabel.setContentHuggingPriority(.required, for: .horizontal)
        inUseLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailLabel.numberOfLines = 0
        detailLabel.textColor = Theme.Color.labelSecondary
        latencyLabel.font = Theme.Font.subheadline
        latencyLabel.setContentHuggingPriority(.required, for: .horizontal)
        latencyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        for label in [kindLabel, inUseLabel, detailLabel, latencyLabel] {
            label.adjustsFontForContentSizeCategory = true
        }

        warningIcon.image = UIImage(systemName: "exclamationmark.triangle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        warningIcon.tintColor = Theme.Color.accentText
        warningIcon.setContentHuggingPriority(.required, for: .horizontal)
        checkIcon.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
        checkIcon.tintColor = Theme.Color.accentText
        checkIcon.setContentHuggingPriority(.required, for: .horizontal)

        let titleRow = UIStackView(arrangedSubviews: [kindLabel, inUseLabel, UIView()])
        titleRow.spacing = 8
        titleRow.alignment = .firstBaseline

        let texts = UIStackView(arrangedSubviews: [titleRow, detailLabel])
        texts.axis = .vertical
        texts.spacing = 2

        let trailing = UIStackView(arrangedSubviews: [warningIcon, latencyLabel, checkIcon])
        trailing.spacing = 6
        trailing.alignment = .center

        let root = UIStackView(arrangedSubviews: [texts, trailing])
        root.spacing = 12
        root.alignment = .top
        root.pin(to: self, insets: NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))

        isAccessibilityElement = true
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? RouteRowConfiguration else { return }
        kindLabel.text = config.kindTitle
        inUseLabel.isHidden = !config.isInUse
        detailLabel.text = config.detail
        detailLabel.font = config.detailIsMonospaced
            ? UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular))
            : Theme.Font.caption1Regular
        latencyLabel.text = config.latencyText
        latencyLabel.textColor = config.isInUse ? Theme.Color.label : Theme.Color.labelSecondary
        warningIcon.isHidden = !config.showsWarning
        checkIcon.isHidden = !config.isInUse
        alpha = config.isDimmed ? 0.8 : 1

        var parts = [config.kindTitle]
        if config.isInUse { parts.append("in use") }
        parts.append(config.detail)
        parts.append(config.latencyText)
        accessibilityLabel = parts.joined(separator: ", ")
        accessibilityTraits = config.isInUse ? [.staticText, .selected] : .staticText
    }
}

struct ActionRowConfiguration: UIContentConfiguration {
    var symbol: String
    var title: String
    var isAccent: Bool = false
    var value: String?
    var showsChevron: Bool = false

    func makeContentView() -> UIView & UIContentView { ActionRowContentView(configuration: self) }
    func updated(for state: UIConfigurationState) -> ActionRowConfiguration { self }
}

final class ActionRowContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration { didSet { apply() } }

    private let wellHolder = UIStackView()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let chevron = UIImageView()
    private var well = SymbolWellView(symbol: "plus")

    init(configuration: ActionRowConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)

        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        valueLabel.font = Theme.Font.subheadline
        valueLabel.textColor = Theme.Color.labelSecondary
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        chevron.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        chevron.tintColor = Theme.Color.labelTertiary
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        wellHolder.alignment = .center

        let root = UIStackView(arrangedSubviews: [wellHolder, titleLabel, valueLabel, chevron])
        root.spacing = 12
        root.alignment = .center
        root.pin(to: self, insets: NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Size.minTarget + 8).isActive = true

        isAccessibilityElement = true
        accessibilityTraits = .button
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? ActionRowConfiguration else { return }
        well.removeFromSuperview()
        well = SymbolWellView(symbol: config.symbol, tint: config.isAccent ? Theme.Color.accentText : Theme.Color.labelSecondary)
        wellHolder.addArrangedSubview(well)

        titleLabel.text = config.title
        titleLabel.font = config.isAccent ? Theme.Font.scaled(.body, 16, .semibold) : Theme.Font.scaled(.body, 16, .regular)
        titleLabel.textColor = config.isAccent ? Theme.Color.accentText : Theme.Color.label
        valueLabel.text = config.value
        valueLabel.isHidden = config.value == nil
        chevron.isHidden = !config.showsChevron
        accessibilityLabel = config.title
        accessibilityValue = config.value
    }
}

struct TestButtonConfiguration: UIContentConfiguration {
    var isTesting: Bool
    var action: () -> Void

    func makeContentView() -> UIView & UIContentView { TestButtonContentView(configuration: self) }
    func updated(for state: UIConfigurationState) -> TestButtonConfiguration { self }
}

final class TestButtonContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration { didSet { apply() } }

    private let button = UIButton(configuration: ThemeButton.glassConfiguration(title: "Test Connection", symbol: "bolt.horizontal"))
    private var action: () -> Void = {}

    init(configuration: TestButtonConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        button.addAction(UIAction { [weak self] _ in self?.action() }, for: .primaryActionTriggered)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? TestButtonConfiguration else { return }
        action = config.action
        var updated = ThemeButton.glassConfiguration(title: config.isTesting ? "Testing…" : "Test Connection", symbol: config.isTesting ? nil : "bolt.horizontal")
        updated.showsActivityIndicator = config.isTesting
        button.configuration = updated
        button.isEnabled = !config.isTesting
    }
}

import UIKit

/// A server card for the Choose Server list. The selected card gets an ember stroke and expands to
/// list every connection with its probe state, kind, address and measured latency.
struct ChooseServerCardConfiguration: UIContentConfiguration, Hashable {
    var choice: ServerChoice
    var isSelected: Bool

    func makeContentView() -> UIView & UIContentView {
        ChooseServerCardView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> ChooseServerCardConfiguration {
        self
    }
}

final class ChooseServerCardView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let wellView = UIView()
    private let wellIcon = UIImageView(image: UIImage(systemName: "server.rack"))
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let checkCircle = UIView()
    private let checkIcon = UIImageView(image: UIImage(systemName: "checkmark"))
    private let routesStack = UIStackView()
    private let separator = UIView()
    private let expandedStack = UIStackView()

    init(configuration: ChooseServerCardConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        buildHierarchy()
        apply()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ChooseServerCardView, _: UITraitCollection) in
            view.applyBorder()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var current: ChooseServerCardConfiguration? {
        configuration as? ChooseServerCardConfiguration
    }

    private func buildHierarchy() {
        backgroundColor = Theme.Color.surface
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous

        wellView.backgroundColor = Theme.Color.surfaceRaised
        wellView.layer.cornerRadius = 13
        wellView.layer.cornerCurve = .continuous
        wellIcon.tintColor = Theme.Color.labelSecondary
        wellIcon.contentMode = .scaleAspectFit
        wellIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        wellIcon.translatesAutoresizingMaskIntoConstraints = false
        wellView.addSubview(wellIcon)

        nameLabel.font = Theme.Font.headline
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = Theme.Color.label
        nameLabel.numberOfLines = 0

        detailLabel.font = Theme.Font.footnote
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = Theme.Color.labelSecondary
        detailLabel.numberOfLines = 0

        checkCircle.backgroundColor = Theme.Color.accent
        checkCircle.layer.cornerRadius = 13
        checkIcon.tintColor = Theme.Color.onAccent
        checkIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .heavy)
        checkIcon.translatesAutoresizingMaskIntoConstraints = false
        checkCircle.addSubview(checkIcon)

        let titles = UIStackView(arrangedSubviews: [nameLabel, detailLabel])
        titles.axis = .vertical
        titles.spacing = 1

        let header = UIStackView(arrangedSubviews: [wellView, titles, checkCircle])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 12

        separator.backgroundColor = Theme.Color.separator
        routesStack.axis = .vertical
        routesStack.spacing = 0

        expandedStack.axis = .vertical
        expandedStack.spacing = 6
        expandedStack.addArrangedSubview(separator)
        expandedStack.addArrangedSubview(routesStack)

        let root = UIStackView(arrangedSubviews: [header, expandedStack])
        root.axis = .vertical
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            wellView.widthAnchor.constraint(equalToConstant: 44),
            wellView.heightAnchor.constraint(equalToConstant: 44),
            wellIcon.centerXAnchor.constraint(equalTo: wellView.centerXAnchor),
            wellIcon.centerYAnchor.constraint(equalTo: wellView.centerYAnchor),
            checkCircle.widthAnchor.constraint(equalToConstant: 26),
            checkCircle.heightAnchor.constraint(equalToConstant: 26),
            checkIcon.centerXAnchor.constraint(equalTo: checkCircle.centerXAnchor),
            checkIcon.centerYAnchor.constraint(equalTo: checkCircle.centerYAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    private func apply() {
        guard let config = current else { return }
        let choice = config.choice
        nameLabel.text = choice.name
        detailLabel.text = choice.detailText
        checkCircle.isHidden = !(config.isSelected && choice.isOnline)
        alpha = choice.isOnline ? 1 : 0.7

        let expanded = config.isSelected && choice.isOnline
        expandedStack.isHidden = !expanded
        routesStack.arrangedSubviews.forEach {
            routesStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        if expanded {
            let best = choice.bestRoute?.uri
            for route in choice.routes {
                routesStack.addArrangedSubview(Self.routeRow(route, isBest: route.uri == best))
            }
        }
        applyBorder()
        applyAccessibility(config)
    }

    private func applyBorder() {
        let selected = current.map { $0.isSelected && $0.choice.isOnline } ?? false
        layer.borderWidth = selected ? 2 : 0.5
        let color = selected ? Theme.Color.accent : Theme.Color.separator
        layer.borderColor = color.resolvedColor(with: traitCollection).cgColor
    }

    private func applyAccessibility(_ config: ChooseServerCardConfiguration) {
        isAccessibilityElement = true
        let choice = config.choice
        var parts = [choice.name, choice.detailText]
        if config.isSelected, choice.isOnline {
            if let best = choice.bestRoute, let ms = best.milliseconds {
                parts.append("Selected. Fastest route \(best.kind.title), \(ms) milliseconds")
            } else if choice.isProbing {
                parts.append("Selected. Testing connections")
            } else {
                parts.append("Selected. No reachable connection")
            }
        }
        accessibilityLabel = parts.joined(separator: ", ")
        var traits: UIAccessibilityTraits = .button
        if config.isSelected, choice.isOnline { traits.insert(.selected) }
        if !choice.isOnline { traits.insert(.notEnabled) }
        accessibilityTraits = traits
    }

    private static func routeRow(_ route: ServerRoute, isBest: Bool) -> UIView {
        let indicator = indicatorView(for: route.state)

        let kind = UILabel()
        kind.text = route.kind.title
        kind.font = Theme.Font.subheadlineSemibold
        kind.adjustsFontForContentSizeCategory = true
        kind.textColor = Theme.Color.label

        let address = UILabel()
        address.text = route.kind == .relay ? "Bandwidth limited, may force transcoding" : route.address
        address.font = route.kind == .relay
            ? Theme.Font.caption1Regular
            : UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular))
        address.adjustsFontForContentSizeCategory = true
        address.textColor = Theme.Color.labelSecondary
        address.numberOfLines = 0

        let texts = UIStackView(arrangedSubviews: [kind, address])
        texts.axis = .vertical

        let latency = UILabel()
        latency.font = Theme.Font.subheadlineSemibold
        latency.adjustsFontForContentSizeCategory = true
        latency.setContentHuggingPriority(.required, for: .horizontal)
        latency.setContentCompressionResistancePriority(.required, for: .horizontal)
        switch route.state {
        case .reachable(let ms):
            latency.text = "\(ms) ms"
            latency.textColor = isBest ? Theme.Color.label : Theme.Color.labelSecondary
        case .unreachable:
            latency.text = "Unreachable"
            latency.textColor = Theme.Color.labelTertiary
        case .probing:
            latency.text = nil
        }

        let row = UIStackView(arrangedSubviews: [indicator, texts, latency])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.layoutMargins = UIEdgeInsets(top: 7, left: 0, bottom: 7, right: 0)
        row.isLayoutMarginsRelativeArrangement = true
        row.alpha = route.state == .unreachable ? 0.7 : 1
        return row
    }

    private static func indicatorView(for state: ServerRoute.State) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 18).isActive = true
        container.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let content: UIView
        switch state {
        case .probing:
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.transform = CGAffineTransform(scaleX: 0.75, y: 0.75)
            spinner.startAnimating()
            content = spinner
        case .reachable:
            content = symbol("checkmark", color: Theme.Color.accentText, weight: .heavy)
        case .unreachable:
            content = symbol("clock", color: Theme.Color.labelTertiary, weight: .semibold)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private static func symbol(_ name: String, color: UIColor, weight: UIImage.SymbolWeight) -> UIImageView {
        let view = UIImageView(image: UIImage(systemName: name))
        view.tintColor = color
        view.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: weight)
        return view
    }
}

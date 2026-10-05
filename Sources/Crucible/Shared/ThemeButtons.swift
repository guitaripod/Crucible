@preconcurrency import UIKit

/// Button recipes shared by every screen: one ember primary action, glass for everything secondary.
@MainActor
enum ThemeButton {
    static func primaryConfiguration(title: String, symbol: String? = nil) -> UIButton.Configuration {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = Theme.Color.accent
        config.baseForegroundColor = Theme.Color.onAccent
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        config.imagePadding = 8
        if let symbol {
            config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        }
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.buttonLabel
            return outgoing
        }
        return config
    }

    static func glassConfiguration(title: String? = nil, symbol: String? = nil) -> UIButton.Configuration {
        var config = Glass.glassButton {
            var fallback = UIButton.Configuration.filled()
            fallback.baseBackgroundColor = Theme.Color.surfaceRaised
            return fallback
        }
        config.title = title
        config.baseForegroundColor = Theme.Color.label
        config.cornerStyle = .capsule
        config.imagePadding = 8
        if let symbol {
            config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        }
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.buttonLabel
            return outgoing
        }
        return config
    }

    static func primary(title: String, symbol: String? = nil) -> UIButton {
        let button = UIButton(configuration: primaryConfiguration(title: title, symbol: symbol))
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Size.primaryButtonHeight).isActive = true
        return button
    }

    /// A 44pt glass circle holding a single symbol. Callers attach a `UIAction` or a `menu`.
    static func icon(symbol: String, label: String, size: CGFloat = Theme.Size.iconButton) -> UIButton {
        var config = glassConfiguration(symbol: symbol)
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        let button = UIButton(configuration: config)
        button.accessibilityLabel = label
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: size),
            button.heightAnchor.constraint(equalToConstant: size),
        ])
        return button
    }

    /// A glass control that shows a small caption over the current value with a trailing chevron,
    /// e.g. "Audio / English · Atmos". Attach a `menu`; it opens as the primary action.
    static func menuButton(caption: String, value: String, menu: UIMenu? = nil) -> UIButton {
        let button = UIButton()
        configureMenuButton(button, caption: caption, value: value)
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        return button
    }

    static func configureMenuButton(_ button: UIButton, caption: String, value: String) {
        var config = Glass.glassButton {
            var fallback = UIButton.Configuration.filled()
            fallback.baseBackgroundColor = Theme.Color.surfaceRaised
            return fallback
        }
        config.title = caption
        config.subtitle = value
        config.titleAlignment = .leading
        config.cornerStyle = .large
        config.baseForegroundColor = Theme.Color.label
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        config.titlePadding = 1
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.scaled(.caption1, 11, .regular, maximum: 15)
            outgoing.foregroundColor = Theme.Color.labelSecondary
            return outgoing
        }
        config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.subheadlineSemibold
            outgoing.foregroundColor = Theme.Color.label
            return outgoing
        }
        config.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        config.imagePlacement = .trailing
        config.imagePadding = 8
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        button.configuration = config
        button.contentHorizontalAlignment = .leading
        button.accessibilityLabel = "\(caption), \(value)"
    }
}

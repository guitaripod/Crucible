import CrucibleDesign
import UIKit

/// Button recipes. Every button on tvOS is a `UIButton` with a `UIButton.Configuration`, so it gets
/// the system focus lift, press feedback and, on tvOS 26 with capable hardware, Liquid Glass.
///
/// Legibility rules, verified in the tvOS 26.5 simulator in Dark and Light, focused and unfocused:
/// - A focused glass button turns into a light pill with dark text, whatever its tint. Only the
///   label colour you set explicitly survives, so a prominent glass button without an explicit dark
///   `baseForegroundColor` renders a white label on that white pill and is unreadable.
/// - `baseBackgroundColor` colours `prominentGlass()` but is ignored by `glass()`.
/// - `clearGlass()` over bright artwork washes the label out; use `glass()` there.
@MainActor
enum TVButton {
    enum Style: Equatable {
        case primary
        case glass
        case plain
        case chip(selected: Bool)
    }

    static func configuration(
        _ style: Style,
        title: String?,
        symbol: String? = nil,
        symbolTrailing: Bool = false
    ) -> UIButton.Configuration {
        var configuration = base(style)
        let font = labelFont(style)
        configuration.title = title
        if let symbol {
            configuration.image = UIImage(systemName: symbol)
            configuration.imagePadding = Theme.Space.xs
            configuration.imagePlacement = symbolTrailing ? .trailing : .leading
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: font)
        }
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = font
            return outgoing
        }
        configuration.cornerStyle = .capsule
        configuration.titleLineBreakMode = .byTruncatingTail
        let vertical = max(0, ((height(style) - font.lineHeight) / 2).rounded(.down))
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: vertical,
            leading: horizontalInset(style),
            bottom: vertical,
            trailing: horizontalInset(style)
        )
        return configuration
    }

    static func make(
        _ style: Style,
        title: String?,
        symbol: String? = nil,
        symbolTrailing: Bool = false,
        action: @escaping @MainActor () -> Void
    ) -> UIButton {
        let button = UIButton(
            configuration: configuration(style, title: title, symbol: symbol, symbolTrailing: symbolTrailing),
            primaryAction: UIAction { _ in action() }
        )
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.accessibilityLabel = title
        return button
    }

    /// A glass button that opens a menu (Audio, Subtitles, Genre, Sort) and shows a trailing chevron.
    static func menuButton(title: String, symbol: String? = nil, menu: UIMenu) -> UIButton {
        let button = UIButton(configuration: configuration(.glass, title: title, symbol: symbol))
        button.configuration?.image = UIImage(systemName: "chevron.down")
        button.configuration?.imagePlacement = .trailing
        button.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: labelFont(.glass), scale: .small)
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = title
        return button
    }

    /// Re-themes `button` after its selection changed, keeping its title and image.
    static func setChipSelected(_ selected: Bool, on button: UIButton) {
        let title = button.configuration?.title
        let image = button.configuration?.image
        var configuration = Self.configuration(.chip(selected: selected), title: title)
        configuration.image = image
        button.configuration = configuration
        button.accessibilityTraits = selected ? [.button, .selected] : .button
    }

    private static func base(_ style: Style) -> UIButton.Configuration {
        switch style {
        case .primary:
            return ember()
        case .chip(let selected):
            return selected ? ember() : Glass.glassButton { .gray() }
        case .glass:
            return Glass.glassButton { .gray() }
        case .plain:
            var configuration = UIButton.Configuration.plain()
            configuration.baseForegroundColor = Theme.Color.accentText
            return configuration
        }
    }

    /// The single tinted action: prominent glass with an explicit dark label, or a filled ember pill.
    private static func ember() -> UIButton.Configuration {
        var configuration = Glass.prominentButton { .filled() }
        configuration.baseBackgroundColor = Theme.Color.accent
        configuration.baseForegroundColor = Theme.Color.onAccent
        return configuration
    }

    private static func labelFont(_ style: Style) -> UIFont {
        switch style {
        case .primary, .glass: Theme.Font.scaled(.callout, 31, .semibold, maximum: 44)
        case .chip: Theme.Font.scaled(.body, 29, .semibold, maximum: 40)
        case .plain: Theme.Font.scaled(.callout, 31, .semibold, maximum: 42)
        }
    }

    private static func height(_ style: Style) -> CGFloat {
        switch style {
        case .primary, .glass: TVMetrics.Control.primaryHeight
        case .chip: TVMetrics.Control.chipHeight
        case .plain: 56
        }
    }

    private static func horizontalInset(_ style: Style) -> CGFloat {
        switch style {
        case .primary, .glass: TVMetrics.Control.horizontalInset
        case .chip: TVMetrics.Control.chipHorizontalInset
        case .plain: 20
        }
    }
}

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

    /// A button of `style`. `action` is the primary action; leave it nil to attach one later with
    /// `addAction(_:for:)` (an empty closure would be a second, silent primary action).
    static func make(
        _ style: Style,
        title: String?,
        symbol: String? = nil,
        symbolTrailing: Bool = false,
        action: (@MainActor () -> Void)? = nil
    ) -> UIButton {
        let button = UIButton(
            configuration: configuration(style, title: title, symbol: symbol, symbolTrailing: symbolTrailing),
            primaryAction: action.map { action in UIAction { _ in action() } }
        )
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.accessibilityLabel = title
        return button
    }

    /// A button of `style` (glass or chip) that opens a menu (Audio, Subtitles, Genre, Sort) and
    /// shows a trailing chevron.
    static func menuButton(style: Style = .glass, title: String, menu: UIMenu) -> UIButton {
        let button = UIButton(type: .system)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        configure(menu: menu, title: title, style: style, on: button)
        return button
    }

    /// Updates a menu button in place (a reused cell, a header that refreshes its selection): new
    /// title and menu, chevron kept, no new button. A menu button carries the chevron as its only
    /// image, so it has no leading symbol.
    static func configure(menu: UIMenu?, title: String?, style: Style = .glass, on button: UIButton) {
        var configuration = Self.configuration(style, title: title)
        configuration.image = UIImage(systemName: "chevron.down")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = Theme.Space.xs
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: labelFont(style), scale: .small)
        button.configuration = configuration
        button.menu = menu
        button.showsMenuAsPrimaryAction = menu != nil
        button.accessibilityLabel = title
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

    static func labelFont(_ style: Style) -> UIFont {
        switch style {
        case .primary, .glass, .plain: TVFont.control
        case .chip: TVFont.cardTitle
        }
    }

    private static func height(_ style: Style) -> CGFloat {
        switch style {
        case .primary, .glass: TVMetrics.Control.primaryHeight
        case .chip: TVMetrics.Control.chipHeight
        case .plain: TVMetrics.Control.plainHeight
        }
    }

    private static func horizontalInset(_ style: Style) -> CGFloat {
        switch style {
        case .primary, .glass: TVMetrics.Control.horizontalInset
        case .chip: TVMetrics.Control.chipHorizontalInset
        case .plain: TVMetrics.Control.plainHorizontalInset
        }
    }
}

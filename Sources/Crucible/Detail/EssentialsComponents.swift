import CrucibleCore
import CrucibleDesign
import UIKit

/// The row above the season picker that says which episodes the list keeps (All Episodes, Skip Anime-Only,
/// Highlights), how much that saves, where the guide comes from, and opens the menu that changes it.
struct EssentialsBarConfiguration: UIContentConfiguration {
    var title = ""
    var detail: String?
    var source: String?
    var menu: UIMenu?

    func makeContentView() -> UIView & UIContentView {
        EssentialsBarContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> EssentialsBarConfiguration { self }
}

final class EssentialsBarContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let button = UIButton()
    private let detailLabel = UILabel()
    private let sourceLabel = UILabel()

    init(configuration: EssentialsBarConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        button.showsMenuAsPrimaryAction = true
        button.isPointerInteractionEnabled = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        for label in [detailLabel, sourceLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        detailLabel.font = Theme.Font.footnote
        detailLabel.textColor = Theme.Color.labelSecondary
        sourceLabel.font = Theme.Font.caption1Regular
        sourceLabel.textColor = Theme.Color.labelTertiary

        let text = UIStackView(arrangedSubviews: [detailLabel, sourceLabel])
        text.axis = .vertical
        text.spacing = 2
        text.setContentCompressionResistancePriority(.required, for: .vertical)
        detailLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        sourceLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        let row = UIStackView(arrangedSubviews: [button, text])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Space.s
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? EssentialsBarConfiguration else { return }
        var buttonConfig = ThemeButton.glassConfiguration(title: config.title)
        buttonConfig.image = UIImage(systemName: "line.3.horizontal.decrease", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        buttonConfig.imagePlacement = .leading
        buttonConfig.imagePadding = 8
        buttonConfig.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 16)
        buttonConfig.titleLineBreakMode = .byTruncatingTail
        buttonConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.scaled(.callout, 16, .semibold, maximum: 24)
            return outgoing
        }
        button.configuration = buttonConfig
        button.menu = config.menu
        button.isEnabled = config.menu != nil
        button.accessibilityLabel = String(localized: "Episodes: \(config.title)", comment: "VoiceOver label of the Essentials button, e.g. Episodes: Skip Anime-Only")
        button.accessibilityHint = config.detail
        detailLabel.text = config.detail
        detailLabel.isHidden = config.detail == nil
        sourceLabel.text = config.source
        sourceLabel.isHidden = config.source == nil
    }
}

/// The card a long show with a guide shows once: how many episodes it has, what Skip Anime-Only would save,
/// and the two answers.
struct EssentialsOfferConfiguration: UIContentConfiguration {
    var title = ""
    var message = ""
    var onAccept: (() -> Void)?
    var onDecline: (() -> Void)?

    func makeContentView() -> UIView & UIContentView {
        EssentialsOfferContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> EssentialsOfferConfiguration { self }
}

final class EssentialsOfferContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let card = UIView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let accept = UIButton()
    private let decline = UIButton()

    init(configuration: EssentialsOfferConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        card.backgroundColor = Theme.Color.surface
        card.layer.cornerRadius = Theme.Radius.m
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let icon = UIImageView(image: UIImage(systemName: "sparkles", withConfiguration: UIImage.SymbolConfiguration(textStyle: .title3, scale: .medium)))
        icon.tintColor = Theme.Color.accent
        icon.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.font = Theme.Font.headline
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        messageLabel.font = Theme.Font.subheadline
        messageLabel.textColor = Theme.Color.labelSecondary
        messageLabel.numberOfLines = 0
        messageLabel.adjustsFontForContentSizeCategory = true

        var acceptConfig = UIButton.Configuration.filled()
        acceptConfig.title = EssentialsCopy.offerAccept
        acceptConfig.baseBackgroundColor = Theme.Color.accent
        acceptConfig.baseForegroundColor = Theme.Color.onAccent
        acceptConfig.cornerStyle = .capsule
        accept.configuration = acceptConfig
        accept.addAction(UIAction { [weak self] _ in
            Haptics.success()
            (self?.configuration as? EssentialsOfferConfiguration)?.onAccept?()
        }, for: .primaryActionTriggered)

        var declineConfig = UIButton.Configuration.plain()
        declineConfig.title = EssentialsCopy.offerDecline
        declineConfig.baseForegroundColor = Theme.Color.labelSecondary
        decline.configuration = declineConfig
        decline.addAction(UIAction { [weak self] _ in
            Haptics.light()
            (self?.configuration as? EssentialsOfferConfiguration)?.onDecline?()
        }, for: .primaryActionTriggered)

        let text = UIStackView(arrangedSubviews: [titleLabel, messageLabel])
        text.axis = .vertical
        text.spacing = 4
        let header = UIStackView(arrangedSubviews: [icon, text])
        header.axis = .horizontal
        header.alignment = .top
        header.spacing = Theme.Space.s
        let buttons = UIStackView(arrangedSubviews: [accept, decline])
        buttons.axis = .horizontal
        buttons.spacing = Theme.Space.s
        buttons.alignment = .center
        let stack = UIStackView(arrangedSubviews: [header, buttons])
        stack.axis = .vertical
        stack.spacing = Theme.Space.m
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Theme.Space.m),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.Space.m),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.Space.m),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Theme.Space.m),
        ])
        isAccessibilityElement = false
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? EssentialsOfferConfiguration else { return }
        titleLabel.text = config.title
        messageLabel.text = config.message
    }
}

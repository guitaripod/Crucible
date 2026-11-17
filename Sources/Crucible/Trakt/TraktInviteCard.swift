import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// The invitation a title page shows where Trakt's community would be while Trakt is not connected: what connecting adds to this
/// title, Connect Trakt, and Not Now. It wears the warm card the community's own Pro card wears, so it reads as part of the page
/// rather than an advertisement on it, inset like the other full-width rows of the page.
struct TraktInviteCardConfiguration: UIContentConfiguration {
    var invite: TraktInvite
    var onConnect: () -> Void = {}
    var onNotNow: () -> Void = {}

    func makeContentView() -> UIView & UIContentView { TraktInviteCardContentView(configuration: self) }
    func updated(for state: UIConfigurationState) -> TraktInviteCardConfiguration { self }
}

final class TraktInviteCardContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let card = UIView()
    private let gradient = CAGradientLayer()
    private let markWell = UIView()
    private let mark = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let connectButton = UIButton(configuration: .filled())
    private let notNowButton = UIButton(configuration: .plain())
    private let buttons = UIStackView()

    init(configuration: TraktInviteCardConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        card.layer.cornerRadius = Theme.Radius.m + 4
        card.layer.cornerCurve = .continuous
        card.layer.masksToBounds = true
        gradient.colors = [Theme.Color.emberTop, Theme.Color.emberMid, Theme.Color.emberBottom].map(\.cgColor)
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        card.layer.insertSublayer(gradient, at: 0)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
        ])
        installContent()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = card.bounds
    }

    private func installContent() {
        markWell.backgroundColor = .white
        markWell.layer.cornerRadius = 20
        markWell.translatesAutoresizingMaskIntoConstraints = false
        mark.image = BrandMark.trakt.image
        mark.contentMode = .scaleAspectFit
        mark.translatesAutoresizingMaskIntoConstraints = false
        markWell.addSubview(mark)

        titleLabel.font = Theme.Font.title3
        titleLabel.textColor = Theme.Color.onArt
        titleLabel.accessibilityTraits = .header
        messageLabel.font = Theme.Font.subheadline
        messageLabel.textColor = Theme.Color.onArtSecondary
        for label in [titleLabel, messageLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }

        connectButton.accessibilityIdentifier = "trakt.invite.connect"
        connectButton.isPointerInteractionEnabled = true
        connectButton.addAction(UIAction { [weak self] _ in self?.connectTapped() }, for: .primaryActionTriggered)
        notNowButton.accessibilityIdentifier = "trakt.invite.notNow"
        notNowButton.isPointerInteractionEnabled = true
        notNowButton.addAction(UIAction { [weak self] _ in self?.notNowTapped() }, for: .primaryActionTriggered)

        let heading = UIStackView(arrangedSubviews: [markWell, titleLabel])
        heading.spacing = Theme.Space.s
        heading.alignment = .center
        buttons.addArrangedSubview(connectButton)
        buttons.addArrangedSubview(notNowButton)
        buttons.spacing = Theme.Space.xs
        for button in [connectButton, notNowButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        stackButtonsForTextSize()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: TraktInviteCardContentView, _: UITraitCollection) in
            view.stackButtonsForTextSize()
        }
        let stack = UIStackView(arrangedSubviews: [heading, messageLabel, buttons])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.s
        stack.setCustomSpacing(Theme.Space.m, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let inset = Theme.Space.m + 2
        NSLayoutConstraint.activate([
            markWell.widthAnchor.constraint(equalToConstant: 40),
            markWell.heightAnchor.constraint(equalToConstant: 40),
            mark.centerXAnchor.constraint(equalTo: markWell.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: markWell.centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: 24),
            mark.heightAnchor.constraint(equalToConstant: 24),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
        ])
        accessibilityIdentifier = "trakt.invite"
    }

    private func apply() {
        guard let config = configuration as? TraktInviteCardConfiguration else { return }
        titleLabel.text = config.invite.title
        messageLabel.text = config.invite.message

        var connect = UIButton.Configuration.filled()
        connect.title = config.invite.action
        connect.baseBackgroundColor = Theme.Color.emberEyebrow
        connect.baseForegroundColor = Theme.Color.onAccent
        connect.cornerStyle = .capsule
        connect.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18)
        connect.titleTextAttributesTransformer = Self.font(Theme.Font.subheadlineSemibold)
        connectButton.configuration = connect

        var notNow = UIButton.Configuration.plain()
        notNow.title = TraktInvite.notNow
        notNow.baseForegroundColor = Theme.Color.onArtSecondary
        notNow.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        notNow.titleTextAttributesTransformer = Self.font(Theme.Font.subheadline)
        notNowButton.configuration = notNow
    }

    /// Puts Not Now under Connect Trakt at the accessibility text sizes, where the two no longer fit side by side.
    private func stackButtonsForTextSize() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        buttons.axis = large ? .vertical : .horizontal
        buttons.alignment = large ? .leading : .center
    }

    private static func font(_ font: UIFont) -> UIConfigurationTextAttributesTransformer {
        UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = font
            return outgoing
        }
    }

    private func connectTapped() {
        Haptics.light()
        (configuration as? TraktInviteCardConfiguration)?.onConnect()
    }

    private func notNowTapped() {
        Haptics.selection()
        (configuration as? TraktInviteCardConfiguration)?.onNotNow()
    }
}

/// Opens Settings › Trakt over `host` as a sheet: what connecting does and what Trakt receives, then Connect Trakt. The sheet stays
/// until the viewer closes it, so the question about Trakt's own Plex sync that can follow a connection is never cut short.
@MainActor
enum TraktInviteSheet {
    static func present(from host: UIViewController, api: APIClient) {
        let settings = TraktSettingsViewController(api: api)
        let navigation = UINavigationController(rootViewController: settings)
        settings.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak navigation] _ in
            navigation?.dismiss(animated: true)
        })
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        host.present(navigation, animated: true)
    }
}

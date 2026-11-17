import CrucibleCore
import CrucibleDesign
import UIKit

/// The invitation a title page shows where Trakt's community would be while Trakt is not connected: Trakt's mark, what connecting
/// adds to this title, Connect Trakt and Not Now. The panel itself never takes focus; its two buttons do.
final class TVTraktInviteView: UIView {
    private static let markSide: CGFloat = 88
    private static let messageWidth: CGFloat = 1100

    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let connectButton: UIButton
    private let notNowButton: UIButton
    /// Catches focus coming down onto the panel anywhere along its width and hands it to Connect Trakt, which is what the panel is
    /// for; it steps aside while the focus is inside, so Up from a button still leaves the panel.
    private let entryGuide = UIFocusGuide()

    init(onConnect: @escaping @MainActor () -> Void, onNotNow: @escaping @MainActor () -> Void) {
        connectButton = TVButton.make(.primary, title: TraktCopy.connect, symbol: "link", action: onConnect)
        notNowButton = TVButton.make(.glass, title: TraktInvite.notNow, action: onNotNow)
        super.init(frame: .zero)
        connectButton.accessibilityIdentifier = "detail.traktInvite.connect"
        notNowButton.accessibilityIdentifier = "detail.traktInvite.notNow"
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { false }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] { [connectButton] }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        entryGuide.isEnabled = !(context.nextFocusedView?.isDescendant(of: self) ?? false)
    }

    /// Shows `invite`'s words and its button in place, so a refresh never takes the focus off a focused button.
    func apply(_ invite: TraktInvite) {
        titleLabel.text = invite.title
        messageLabel.text = invite.message
        connectButton.configuration?.title = invite.action
        connectButton.accessibilityLabel = invite.action
    }

    private func build() {
        let mark = UIImageView(image: BrandMark.trakt.image)
        mark.contentMode = .scaleAspectFit
        mark.isAccessibilityElement = false
        mark.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Theme.Font.title3
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityIdentifier = "detail.traktInvite.title"
        messageLabel.font = Theme.Font.body
        messageLabel.textColor = Theme.Color.labelSecondary
        messageLabel.numberOfLines = 0

        let buttons = UIStackView(arrangedSubviews: [connectButton, notNowButton])
        buttons.axis = .horizontal
        buttons.spacing = Theme.Space.m

        let text = UIStackView(arrangedSubviews: [titleLabel, messageLabel, buttons])
        text.axis = .vertical
        text.alignment = .leading
        text.spacing = Theme.Space.xs
        text.setCustomSpacing(Theme.Space.l, after: messageLabel)

        let row = UIStackView(arrangedSubviews: [mark, text])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = Theme.Space.l
        row.translatesAutoresizingMaskIntoConstraints = false

        let panel = UIView()
        panel.backgroundColor = Theme.Color.surface.withAlphaComponent(0.72)
        panel.layer.cornerRadius = Theme.Radius.l
        panel.layer.cornerCurve = .continuous
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(row)
        addSubview(panel)
        entryGuide.preferredFocusEnvironments = [connectButton]
        panel.addLayoutGuide(entryGuide)
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: Self.markSide),
            mark.heightAnchor.constraint(equalToConstant: Self.markSide),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.messageWidth),
            row.topAnchor.constraint(equalTo: panel.topAnchor, constant: Theme.Space.l),
            row.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -Theme.Space.l),
            row.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: Theme.Space.l),
            row.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -Theme.Space.l),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            entryGuide.topAnchor.constraint(equalTo: panel.topAnchor),
            entryGuide.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -Theme.Space.xs),
            entryGuide.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            entryGuide.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
        ])
        accessibilityIdentifier = "detail.traktInvite"
    }
}

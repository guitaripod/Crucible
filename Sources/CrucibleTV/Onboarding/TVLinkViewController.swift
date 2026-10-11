import CrucibleCore
import CrucibleDesign
import UIKit

/// Signs in with the account's PIN: the person types the code at plex.tv/link or scans the QR code,
/// and the screen carries on by itself the moment Plex confirms. Both codes belong to one session;
/// the first approval wins. Leaving the screen stops polling.
final class TVLinkViewController: TVOnboardingViewController {
    private enum Phase {
        case requesting
        case waiting
        case signedIn
        case expired
        case failed(String)
    }

    private static let qrSide: CGFloat = 420
    private static let qrPadding: CGFloat = 28

    private let titleView = TVScreenTitleView(clearsTabBar: false, column: TVMetrics.Column.message)
    private let tiles = TVCodeTilesView()
    private let qrImageView = UIImageView()
    private let qrCard = UIView()
    private let qrCaption = UILabel()
    private let statusRow = TVStatusRow()
    private lazy var retryButton = TVButton.make(.primary, title: "Get a New Code", symbol: "arrow.clockwise") { [weak self] in
        self?.startSession()
    }

    private var phase = Phase.requesting
    private var session: Task<Void, Never>?

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        switch phase {
        case .expired, .failed: return [retryButton]
        case .waiting where tiles.canBecomeFocused: return [tiles]
        default: return []
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installContent()
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if session == nil, !isSignedIn { startSession() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        session?.cancel()
        session = nil
    }

    private var isSignedIn: Bool {
        if case .signedIn = phase { return true }
        return false
    }

    private func startSession() {
        session?.cancel()
        phase = .requesting
        tiles.setCode(nil)
        qrImageView.image = nil
        render()
        session = Task { [weak self] in
            for await state in PlexLinkSession().states() {
                guard let self, !Task.isCancelled else { return }
                handle(state)
            }
        }
    }

    private func handle(_ state: PlexLinkState) {
        switch state {
        case .requesting:
            phase = .requesting
        case .waiting(let codes):
            tiles.setCode(codes.shortCode)
            qrImageView.image = TVQRCode.image(for: codes.authURL.absoluteString, side: Self.qrSide, scale: traitCollection.displayScale)
            phase = .waiting
            announce(codes.shortCode)
        case .claimed(let token):
            phase = .signedIn
            render()
            PlexSignIn.complete(token: token)
            flow.didSignIn(token: token, from: self)
            return
        case .expired:
            phase = .expired
        case .failed(let message):
            phase = .failed(message)
        }
        render()
    }

    /// VoiceOver follows focus and nothing here is focusable while waiting, so the code is spoken
    /// the moment it arrives and, with VoiceOver on, the code row can be focused to hear it again.
    private func announce(_ code: String) {
        let spoken = code.uppercased().map(String.init).joined(separator: " ")
        UIAccessibility.post(notification: .announcement, argument: "Link code \(spoken). Go to plex dot tv slash link and enter it.")
        guard tiles.canBecomeFocused else { return }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func render() {
        let offersRetry: Bool
        switch phase {
        case .requesting:
            statusRow.show("Requesting a code…", isBusy: true)
            offersRetry = false
        case .waiting:
            statusRow.show("Waiting for approval…", isBusy: true)
            offersRetry = false
        case .signedIn:
            statusRow.show("Signed in. Finding your servers…", isBusy: true)
            offersRetry = false
        case .expired:
            statusRow.show("This code has expired.")
            retryButton.configuration = TVButton.configuration(.primary, title: "Get a New Code", symbol: "arrow.clockwise")
            offersRetry = true
        case .failed(let message):
            statusRow.show(message, tone: .error)
            retryButton.configuration = TVButton.configuration(.primary, title: "Try Again", symbol: "arrow.clockwise")
            offersRetry = true
        }
        retryButton.isHidden = !offersRetry
        tiles.alpha = offersRetry ? 0.3 : 1
        qrCard.alpha = offersRetry ? 0.3 : 1
        if offersRetry {
            view.layoutIfNeeded()
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    private func installContent() {
        titleView.configure(TVScreenTitleContent(title: "Link your Plex account"))

        let steps = UIStackView(arrangedSubviews: [
            Self.stepRow(number: 1, text: Self.linkInstruction()),
            Self.stepRow(number: 2, text: NSAttributedString(string: "Enter this code", attributes: Self.stepAttributes)),
            Self.stepRow(number: 3, text: NSAttributedString(string: "Approve Crucible", attributes: Self.stepAttributes)),
        ])
        steps.axis = .vertical
        steps.alignment = .leading
        steps.spacing = Theme.Space.s

        statusRow.accessibilityIdentifier = "onboarding.status"
        retryButton.accessibilityIdentifier = "onboarding.newCode"
        retryButton.isHidden = true

        let left = UIStackView(arrangedSubviews: [titleView, steps, tiles, statusRow, retryButton])
        left.axis = .vertical
        left.alignment = .leading
        left.spacing = Theme.Space.l
        left.setCustomSpacing(Theme.Space.xl, after: steps)
        left.setCustomSpacing(Theme.Space.xl, after: tiles)

        installQRCard()
        qrCaption.text = "Or scan with your iPhone camera"
        qrCaption.font = Theme.Font.body
        qrCaption.textColor = Theme.Color.labelSecondary
        qrCaption.textAlignment = .center
        qrCaption.numberOfLines = 2
        let right = UIStackView(arrangedSubviews: [qrCard, qrCaption])
        right.axis = .vertical
        right.alignment = .center
        right.spacing = Theme.Space.m

        let columns = UIStackView(arrangedSubviews: [left, right])
        columns.axis = .horizontal
        columns.alignment = .center
        columns.spacing = 160
        columns.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(columns)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            left.widthAnchor.constraint(equalToConstant: TVMetrics.Column.message),
            qrCaption.widthAnchor.constraint(equalTo: qrCard.widthAnchor),
            columns.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            columns.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            columns.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor),
            columns.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor),
        ])
    }

    /// A white rounded card with the QR code inside: scanners need dark modules on light, in Dark
    /// and Light alike.
    private func installQRCard() {
        qrCard.backgroundColor = .white
        qrCard.layer.cornerRadius = Theme.Radius.hero
        qrCard.layer.cornerCurve = .continuous
        qrCard.translatesAutoresizingMaskIntoConstraints = false
        qrCard.isAccessibilityElement = false
        qrImageView.contentMode = .scaleToFill
        qrImageView.layer.magnificationFilter = .nearest
        qrImageView.layer.minificationFilter = .nearest
        qrImageView.translatesAutoresizingMaskIntoConstraints = false
        qrImageView.accessibilityIdentifier = "onboarding.qr"
        qrCard.addSubview(qrImageView)
        let side = Self.qrSide
        let padding = Self.qrPadding
        NSLayoutConstraint.activate([
            qrCard.widthAnchor.constraint(equalToConstant: side + 2 * padding),
            qrCard.heightAnchor.constraint(equalToConstant: side + 2 * padding),
            qrImageView.centerXAnchor.constraint(equalTo: qrCard.centerXAnchor),
            qrImageView.centerYAnchor.constraint(equalTo: qrCard.centerYAnchor),
            qrImageView.widthAnchor.constraint(equalToConstant: side),
            qrImageView.heightAnchor.constraint(equalToConstant: side),
        ])
    }

    private static let stepAttributes: [NSAttributedString.Key: Any] = [
        .font: Theme.Font.callout,
        .foregroundColor: Theme.Color.label,
    ]

    private static func linkInstruction() -> NSAttributedString {
        let text = NSMutableAttributedString(string: "On your iPhone or computer, go to ", attributes: stepAttributes)
        var emphasis = stepAttributes
        emphasis[.font] = Theme.Font.scaled(.callout, 31, .bold, maximum: 42)
        emphasis[.foregroundColor] = Theme.Color.accentText
        text.append(NSAttributedString(string: "plex.tv/link", attributes: emphasis))
        return text
    }

    private static func stepRow(number: Int, text: NSAttributedString) -> UIView {
        let badgeSide: CGFloat = 56
        let badge = UILabel()
        badge.text = "\(number)"
        badge.font = Theme.Font.scaled(.body, 29, .bold, maximum: 36)
        badge.textColor = Theme.Color.accentText
        badge.textAlignment = .center
        badge.backgroundColor = Theme.Color.accentTint
        badge.layer.cornerRadius = badgeSide / 2
        badge.clipsToBounds = true
        badge.isAccessibilityElement = false
        badge.setContentHuggingPriority(.required, for: .horizontal)

        let label = UILabel()
        label.attributedText = text
        label.numberOfLines = 2
        label.accessibilityLabel = "Step \(number). \(text.string)"

        let row = UIStackView(arrangedSubviews: [badge, label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Space.m
        badge.widthAnchor.constraint(equalToConstant: badgeSide).isActive = true
        badge.heightAnchor.constraint(equalToConstant: badgeSide).isActive = true
        return row
    }
}

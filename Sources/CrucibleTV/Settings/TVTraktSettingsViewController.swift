import CrucibleCore
import CrucibleDesign
import UIKit

/// Settings › Integrations › Trakt on Apple TV: the pitch and what Trakt receives on the left, and on the right Connect or
/// the account with what this Apple TV sends.
final class TVTraktSettingsViewController: TVSettingsScaffold {
    private let heading = TVSettingsHeading(title: TraktCopy.name)
    private var observation: UUID?

    deinit {
        if let observation { Task { @MainActor in TraktAccount.shared.stopObserving(observation) } }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.remembersLastFocusedIndexPath = false
        installHeading(heading)
        render()
        observation = TraktAccount.shared.observe { [weak self] in self?.render() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        render()
    }

    override var preferredFocusRowID: String? {
        TraktAccount.shared.isConnected ? "trakt.scrobble" : "trakt.connect"
    }

    private var renderedConnected: Bool?

    /// Connecting or disconnecting replaces every row, so the row focused before means nothing after: focus goes to the
    /// screen's preferred row, Scrobble Playback once connected and Connect before.
    private func forgetFocusWhenTheAccountChanges(connected: Bool) {
        defer { renderedConnected = connected }
        guard let renderedConnected, renderedConnected != connected else { return }
        focusMemory.reset()
    }

    private func render() {
        let account = TraktAccount.shared
        forgetFocusWhenTheAccountChanges(connected: account.isConnected)
        let choices = account.choices
        var rows: [TVRowItem] = []
        var body: String
        switch account.status {
        case .unavailable:
            body = TraktCopy.unavailable
        case .restricted:
            body = TraktCopy.restricted
        case .disconnected, .needsReconnect:
            body = TraktCopy.pitch.contextText
            body += "\n\n" + TraktCopy.consentTitle + "\n" + [TraktCopy.consentPlays, TraktCopy.consentRatings].map { "· \($0)" }.joined(separator: "\n")
            body += "\n" + TraktCopy.consentNever
            if account.status == .needsReconnect { body = TraktCopy.needsReconnect + "\n\n" + body }
            rows.append(TVRowItem(id: "trakt.connect", title: account.status == .needsReconnect ? TraktCopy.reconnect : TraktCopy.connect, symbol: "link", accessory: .chevron))
            if account.status == .disconnected { rows += TraktCopy.pitch.benefitRows(idPrefix: "trakt") }
        case .connected(let profile):
            body = TraktCopy.tagline
            rows.append(TVRowItem(id: "trakt.profile", title: profile?.displayName ?? TraktCopy.name, subtitle: profile.map { "@\($0.username)" }, value: profile?.isVIP == true ? "VIP" : nil, symbol: "person.crop.circle.fill", isStatic: true))
        }
        if account.isConnected || account.status == .needsReconnect {
            let on = String(localized: "On")
            let off = String(localized: "Off")
            rows += [
                TVRowItem(id: "trakt.scrobble", title: TraktCopy.scrobble, subtitle: TraktCopy.scrobbleDetail, value: choices.scrobbles ? on : off, symbol: "play.circle"),
                TVRowItem(id: "trakt.sendChanges", title: TraktCopy.sendChanges, subtitle: TraktCopy.sendChangesDetail, value: choices.sendsChanges ? on : off, symbol: "arrow.up.right.circle"),
                TVRowItem(id: "trakt.removeOnUnwatch", title: TraktCopy.removeOnUnwatch, subtitle: TraktCopy.removeOnUnwatchDetail, value: choices.removesPlaysOnUnwatch ? on : off, symbol: "minus.circle"),
                TVRowItem(id: "trakt.anotherApp", title: TraktCopy.anotherApp, subtitle: TraktCopy.anotherAppDetail, value: choices.anotherAppScrobbles ? on : off, symbol: "arrow.triangle.2.circlepath"),
            ]
            let pending = TraktOutbox.shared.pending.count
            if pending > 0 {
                rows.append(TVRowItem(id: "trakt.pending", title: TraktCopy.waitingChanges, value: TraktCopy.pendingCount(pending), symbol: "tray.and.arrow.up", isStatic: true))
            }
            let unmatched = TraktResolver.shared.unmatchedTitles
            if !unmatched.isEmpty {
                rows.append(TVRowItem(id: "trakt.unmatched", title: TraktCopy.unmatched, subtitle: unmatched.prefix(3).joined(separator: ", "), value: "\(unmatched.count)", symbol: "questionmark.circle", isStatic: true))
            }
        }
        if account.isConnected {
            rows.append(TVRowItem(id: "trakt.disconnect", title: TraktCopy.disconnect, symbol: "xmark.circle", isDestructive: true))
        }
        heading.setBody(body + "\n\n" + TraktCopy.disclaimer)
        setRows(rows)
    }

    override func rowDidSelect(_ id: String) {
        switch id {
        case "trakt.connect":
            TVNavigation.push(TVTraktLinkViewController(), from: self)
        case "trakt.scrobble": TraktAccount.shared.update { $0.scrobbles.toggle() }
        case "trakt.sendChanges": TraktAccount.shared.update { $0.sendsChanges.toggle() }
        case "trakt.removeOnUnwatch": TraktAccount.shared.update { $0.removesPlaysOnUnwatch.toggle() }
        case "trakt.anotherApp": TraktAccount.shared.update { $0.anotherAppScrobbles.toggle() }
        case "trakt.disconnect":
            presentConfirmation(title: TraktCopy.disconnectTitle, message: TraktCopy.disconnectMessage, confirmTitle: TraktCopy.disconnect) {
                Task { await TraktAccount.shared.disconnect() }
            }
        default: break
        }
    }
}

/// Connects Trakt on Apple TV: the eight-character code in tiles, a QR code that opens Trakt's activation page on a
/// phone, and the screen goes back by itself the moment the viewer approves.
final class TVTraktLinkViewController: UIViewController {
    private static let qrSide: CGFloat = 400
    private let titleView = TVScreenTitleView(clearsTabBar: false, column: TVMetrics.Column.message)
    private let instruction = UILabel()
    private let tiles = TVCodeTilesView(length: 8, hint: TraktCopy.approveMessage)
    private let qrImageView = UIImageView()
    private let qrCard = UIView()
    private let qrCaption = UILabel()
    private let statusRow = TVStatusRow()
    private lazy var retryButton = TVButton.make(.primary, title: TraktCopy.newCode, symbol: "arrow.clockwise") { [weak self] in self?.start() }
    private var session: Task<Void, Never>?
    private var failed = false
    private let anchor = TVFocusAnchorView()

    /// The code is information, not a control, so without VoiceOver nothing on the screen takes focus while it waits; the
    /// anchor holds it, or it would fall to the tab bar, where Menu leaves the app and connecting leaves it stuck.
    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        if failed { return [retryButton] }
        return tiles.canBecomeFocused ? [tiles] : [anchor]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        build()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if session == nil { start() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        session?.cancel()
        session = nil
    }

    private func build() {
        titleView.configure(TVScreenTitleContent(title: TraktCopy.approveTitle))
        instruction.font = Theme.Font.callout
        instruction.textColor = Theme.Color.label
        instruction.numberOfLines = 0
        instruction.text = TraktCopy.approveAt(Self.displayAddress(nil))
        retryButton.isHidden = true
        retryButton.accessibilityIdentifier = "trakt.newCode"
        statusRow.accessibilityIdentifier = "trakt.status"

        let left = UIStackView(arrangedSubviews: [titleView, instruction, tiles, statusRow, retryButton])
        left.axis = .vertical
        left.alignment = .leading
        left.spacing = Theme.Space.l
        left.setCustomSpacing(Theme.Space.xl, after: instruction)
        left.setCustomSpacing(Theme.Space.xl, after: tiles)

        qrCard.backgroundColor = .white
        qrCard.layer.cornerRadius = Theme.Radius.hero
        qrCard.layer.cornerCurve = .continuous
        qrCard.translatesAutoresizingMaskIntoConstraints = false
        qrImageView.layer.magnificationFilter = .nearest
        qrImageView.translatesAutoresizingMaskIntoConstraints = false
        qrImageView.accessibilityIdentifier = "trakt.qr"
        qrCard.addSubview(qrImageView)
        qrCaption.text = TraktCopy.scanToApprove
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
        columns.spacing = 140
        columns.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(columns)
        anchor.isNeeded = { [weak self] in
            guard let self else { return false }
            return !failed && !tiles.canBecomeFocused
        }
        anchor.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(anchor)
        let guide = view.safeAreaLayoutGuide
        let side = Self.qrSide + 56
        NSLayoutConstraint.activate([
            anchor.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            anchor.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            anchor.widthAnchor.constraint(equalToConstant: 2),
            anchor.heightAnchor.constraint(equalToConstant: 2),
            left.widthAnchor.constraint(equalToConstant: TVMetrics.Column.message),
            qrCard.widthAnchor.constraint(equalToConstant: side),
            qrCard.heightAnchor.constraint(equalToConstant: side),
            qrImageView.centerXAnchor.constraint(equalTo: qrCard.centerXAnchor),
            qrImageView.centerYAnchor.constraint(equalTo: qrCard.centerYAnchor),
            qrImageView.widthAnchor.constraint(equalToConstant: Self.qrSide),
            qrImageView.heightAnchor.constraint(equalToConstant: Self.qrSide),
            qrCaption.widthAnchor.constraint(equalTo: qrCard.widthAnchor),
            columns.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            columns.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            columns.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor),
        ])
    }

    private func start() {
        session?.cancel()
        failed = false
        tiles.setCode(nil)
        qrImageView.image = nil
        render(TraktCopy.requestingCode, busy: true)
        session = Task { [weak self] in
            for await state in TraktLinkSession().states() {
                guard let self, !Task.isCancelled else { return }
                await handle(state)
            }
        }
    }

    private func handle(_ state: TraktLinkState) async {
        switch state {
        case .requesting:
            render(TraktCopy.requestingCode, busy: true)
        case .waiting(let code):
            instruction.text = TraktCopy.approveAt(Self.displayAddress(code.verificationURL))
            tiles.setCode(code.userCode)
            qrImageView.image = TVQRCode.image(for: code.verificationURL.absoluteString, side: Self.qrSide, scale: traitCollection.displayScale)
            render(TraktCopy.waiting, busy: true)
            UIAccessibility.post(notification: .announcement, argument: "\(TraktCopy.waiting) \(code.userCode.map(String.init).joined(separator: " "))")
        case .approved(let token):
            render(TraktCopy.connecting, busy: true)
            await TraktAccount.shared.connect(with: token)
            await offerToStopTraktsPlexScrobbler()
            navigationController?.popViewController(animated: TVMotion.animationsEnabled)
        case .expired: fail(TraktCopy.expired)
        case .denied: fail(TraktCopy.denied)
        case .notAllowed: fail(TraktCopy.notAllowed)
        case .failed(let message):
            guard !message.isEmpty else { return }
            fail(message)
        }
    }

    /// The activation page as a person types it, `auth.trakt.tv/activate`, from the address Trakt sent with the code.
    private static func displayAddress(_ url: URL?) -> String {
        guard let url, let host = url.host() else { return "auth.trakt.tv/activate" }
        return host + url.path()
    }

    /// Asks once whether Trakt's own Plex link or Crucible records plays, when Trakt's is on.
    private func offerToStopTraktsPlexScrobbler() async {
        guard let server = ServerBootstrap.savedMachineIdentifier, !TraktAccount.shared.choices.askedAboutPlexLink.contains(server),
              await TraktAccount.shared.traktRecordsPlexPlays() else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alert = UIAlertController(title: TraktCopy.doublePlayTitle, message: TraktCopy.doublePlayMessage, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: TraktCopy.crucibleRecords, style: .default) { _ in
                Task {
                    try? await TraktAccount.shared.letCrucibleRecordPlays(server: server)
                    continuation.resume()
                }
            })
            alert.addAction(UIAlertAction(title: TraktCopy.traktRecords, style: .cancel) { _ in
                TraktAccount.shared.letTraktRecordPlays(server: server)
                continuation.resume()
            })
            present(alert, animated: TVMotion.animationsEnabled)
        }
    }

    private func fail(_ message: String) {
        failed = true
        render(message, busy: false, tone: .error)
    }

    private func render(_ status: String, busy: Bool, tone: TVStatusRow.Tone = .neutral) {
        statusRow.show(status, isBusy: busy, tone: tone)
        retryButton.isHidden = !failed
        tiles.alpha = failed ? 0.3 : 1
        qrCard.alpha = failed ? 0.3 : 1
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }
}

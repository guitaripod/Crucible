import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// Settings › Integrations › Trakt (`TVTraktSettingsViewController`): the pitch and what Trakt receives on the left, and on
/// the right Connect with what it brings, or the account with what this computer sends, what waits to be sent, what Trakt
/// could not match, and Disconnect.
@MainActor
final class TraktSettingsScreen: SettingsScaffold {
    private enum RowID {
        static let connect = "trakt.connect"
        static let scrobble = "trakt.scrobble"
        static let sendChanges = "trakt.sendChanges"
        static let removeOnUnwatch = "trakt.removeOnUnwatch"
        static let anotherApp = "trakt.anotherApp"
        static let disconnect = "trakt.disconnect"
    }

    private var observation: UUID?
    private var renderedConnected: Bool?
    private let panel = ContextPanel(content: .init(symbol: "checkmark.rectangle.stack", title: TraktCopy.name))

    init() {
        super.init(title: TraktCopy.name)
        panel.wellView = BrandMarkView("trakt")
        installContext(panel)
        render()
    }

    override func screenDidAppear() {
        if observation == nil { observation = TraktAccount.shared.observe { [weak self] in self?.render() } }
        render()
    }

    override func screenWillDisappear() {
        if let observation { TraktAccount.shared.stopObserving(observation) }
        observation = nil
    }

    private func render() {
        let account = TraktAccount.shared
        let choices = account.choices
        var items: [RowItem] = []
        var body: String
        switch account.status {
        case .unavailable:
            body = TraktCopy.unavailable
        case .restricted:
            body = TraktCopy.restricted
        case .disconnected, .needsReconnect:
            body = TraktCopy.pitch.headline + "\n" + TraktCopy.pitch.story
            body += "\n\n" + TraktCopy.consentTitle + "\n" + [TraktCopy.consentPlays, TraktCopy.consentRatings].map { "· \($0)" }.joined(separator: "\n")
            body += "\n" + TraktCopy.consentNever
            if account.status == .needsReconnect { body = TraktCopy.needsReconnect + "\n\n" + body }
            items.append(RowItem(id: RowID.connect, title: account.status == .needsReconnect ? TraktCopy.reconnect : TraktCopy.connect, symbol: "link",
                                 accessory: .chevron))
            if account.status == .disconnected {
                items += TraktCopy.pitch.benefits.enumerated().filter { !$0.element.needsPro }.map { index, benefit in
                    RowItem(id: "trakt.benefit\(index)", title: benefit.title, subtitle: benefit.detail, symbol: Symbol(benefit.symbol), isStatic: true)
                }
            }
        case .connected(let profile):
            body = TraktCopy.consentTitle + "\n" + [TraktCopy.consentPlays, TraktCopy.consentRatings].map { "· \($0)" }.joined(separator: "\n")
                + "\n" + TraktCopy.consentNever
            items.append(RowItem(id: "trakt.profile", title: profile?.displayName ?? TraktCopy.name, subtitle: profile.map { "@\($0.username)" },
                                 value: profile?.isVIP == true ? "VIP" : nil, symbol: "person.crop.circle.fill", isStatic: true))
        }
        if account.isConnected || account.status == .needsReconnect {
            items += [
                toggle(RowID.scrobble, TraktCopy.scrobble, TraktCopy.scrobbleDetail, choices.scrobbles, symbol: "play.circle"),
                toggle(RowID.sendChanges, TraktCopy.sendChanges, TraktCopy.sendChangesDetail, choices.sendsChanges, symbol: "arrow.up.right.circle"),
                toggle(RowID.removeOnUnwatch, TraktCopy.removeOnUnwatch, TraktCopy.removeOnUnwatchDetail, choices.removesPlaysOnUnwatch, symbol: "minus.circle"),
                toggle(RowID.anotherApp, TraktCopy.anotherApp, TraktCopy.anotherAppDetail, choices.anotherAppScrobbles, symbol: "arrow.triangle.2.circlepath"),
            ]
            let pending = TraktOutbox.shared.pending.count
            if pending > 0 {
                items.append(RowItem(id: "trakt.pending", title: TraktCopy.waitingChanges, value: TraktCopy.pendingCount(pending), symbol: "tray.and.arrow.up",
                                     isStatic: true))
            }
            let unmatched = TraktResolver.shared.unmatchedTitles
            if !unmatched.isEmpty {
                items.append(RowItem(id: "trakt.unmatched", title: TraktCopy.unmatched, subtitle: unmatched.prefix(3).joined(separator: ", "),
                                     value: "\(unmatched.count)", symbol: "questionmark.circle", isStatic: true))
            }
        }
        if account.isConnected {
            items.append(RowItem(id: RowID.disconnect, title: TraktCopy.disconnect, symbol: "xmark.circle", isDestructive: true))
        }
        panel.content = .init(symbol: "checkmark.rectangle.stack", title: TraktCopy.name, subtitle: TraktCopy.tagline, body: body + "\n\n" + TraktCopy.disclaimer)
        let connected = account.isConnected
        let changed = renderedConnected != nil && renderedConnected != connected
        renderedConnected = connected
        setRows(items)
        if changed, containsFocus { window?.focus.focus(rows, animated: false) }
    }

    private func toggle(_ id: String, _ title: String, _ detail: String, _ isOn: Bool, symbol: Symbol) -> RowItem {
        RowItem.onOff(id: id, title: title, subtitle: detail, isOn: isOn, symbol: symbol)
    }

    override func rowSelected(_ id: String) {
        switch id {
        case RowID.connect: navigation?.push(TraktLinkScreen())
        case RowID.scrobble: TraktAccount.shared.update { $0.scrobbles.toggle() }
        case RowID.sendChanges: TraktAccount.shared.update { $0.sendsChanges.toggle() }
        case RowID.removeOnUnwatch: TraktAccount.shared.update { $0.removesPlaysOnUnwatch.toggle() }
        case RowID.anotherApp: TraktAccount.shared.update { $0.anotherAppScrobbles.toggle() }
        case RowID.disconnect:
            guard let window else { return }
            AlertView.confirm(title: TraktCopy.disconnectTitle, message: TraktCopy.disconnectMessage, confirm: TraktCopy.disconnect, in: window) {
                Task { await TraktAccount.shared.disconnect() }
            }
        default: break
        }
        render()
    }
}

/// Connects Trakt (`TVTraktLinkViewController`): the eight-character code in tiles, a QR code that opens Trakt's
/// activation page on a phone, a status line while it waits, and the screen goes back by itself the moment the viewer
/// approves; after an expired, denied or failed code, New Code starts again.
@MainActor
final class TraktLinkScreen: ScreenView {
    private let qr = QRCodeView()
    private let status = StatusLineView()
    private let retry = ButtonView(style: .primary, title: TraktCopy.newCode, symbol: "arrow.clockwise")
    private let anchor = FocusAnchorView()
    private var session: Task<Void, Never>?
    private var code: String?
    private var address = "auth.trakt.tv/activate"
    private var failed = false

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        retry.onPress = { [weak self] in self?.start() }
        retry.isHidden = true
        [qr, status, retry, anchor].forEach(addSubview)
    }

    override var preferredFocusView: View? { failed ? retry : anchor }

    override func screenDidAppear() {
        if session == nil { start() }
    }

    override func screenWillDisappear() {
        session?.cancel()
        session = nil
    }

    private func start() {
        session?.cancel()
        failed = false
        code = nil
        qr.text = nil
        retry.isHidden = true
        status.show(TraktCopy.requestingCode, busy: true)
        window?.focus.focus(anchor, animated: false)
        setNeedsLayout()
        setNeedsDisplay()
        session = Task { [weak self] in
            for await state in TraktLinkSession().states() {
                guard let self, !Task.isCancelled else { return }
                await self.handle(state)
            }
        }
    }

    private func handle(_ state: TraktLinkState) async {
        switch state {
        case .requesting:
            status.show(TraktCopy.requestingCode, busy: true)
        case .waiting(let linkCode):
            code = linkCode.userCode
            address = Self.displayAddress(linkCode.verificationURL)
            qr.text = linkCode.verificationURL.absoluteString
            status.show(TraktCopy.waiting, busy: true)
        case .approved(let token):
            status.show(TraktCopy.connecting, busy: true)
            await TraktAccount.shared.connect(with: token)
            await offerToStopTraktsPlexScrobbler()
            _ = navigation?.pop()
        case .expired: fail(TraktCopy.expired)
        case .denied: fail(TraktCopy.denied)
        case .notAllowed: fail(TraktCopy.notAllowed)
        case .failed(let message):
            guard !message.isEmpty else { return }
            fail(message)
        }
        setNeedsLayout()
        setNeedsDisplay()
    }

    private func fail(_ message: String) {
        failed = true
        status.show(message, tone: .error)
        retry.isHidden = false
        window?.focus.focus(retry, animated: false)
    }

    /// The activation page as a person types it, `auth.trakt.tv/activate`, from the address Trakt sent with the code.
    private static func displayAddress(_ url: URL?) -> String {
        guard let url, let host = url.host() else { return "auth.trakt.tv/activate" }
        return host + url.path()
    }

    /// Asks once whether Trakt's own Plex link or Crucible records plays, when Trakt's is on.
    private func offerToStopTraktsPlexScrobbler() async {
        guard let window, let server = ServerBootstrap.savedMachineIdentifier, !TraktAccount.shared.choices.askedAboutPlexLink.contains(server),
              await TraktAccount.shared.traktRecordsPlexPlays() else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            AlertView(title: TraktCopy.doublePlayTitle, message: TraktCopy.doublePlayMessage, actions: [
                AlertView.Action(TraktCopy.crucibleRecords) {
                    Task {
                        try? await TraktAccount.shared.letCrucibleRecordPlays(server: server)
                        continuation.resume()
                    }
                },
                AlertView.Action(TraktCopy.traktRecords, role: .cancel) {
                    TraktAccount.shared.letTraktRecordPlays(server: server)
                    continuation.resume()
                },
            ]).present(in: window)
        }
    }

    private var metrics: Metrics { Theme.current.metrics }
    private var leftX: Float { metrics.sideMargin * 2 }
    private var column: Float { min(metrics.messageColumn, frame.width * 0.55 - leftX) }

    override func layoutSubviews() {
        let qrSide = metrics.tv(400)
        qr.frame = Rect(x: frame.width * 0.62, y: ((frame.height - qrSide) / 2).rounded() - metrics.tv(20), width: qrSide, height: qrSide)
        let statusHeight = max(status.sizeThatFits(Size(width: column, height: 0)).height, metrics.tv(36))
        status.frame = Rect(x: leftX, y: (frame.height * 0.62).rounded(), width: column, height: statusHeight)
        let size = retry.sizeThatFits(Size(width: 600, height: 200))
        retry.frame = Rect(x: leftX, y: status.frame.maxY + metrics.tv(32), width: size.width, height: size.height)
        anchor.frame = Rect(x: frame.midX, y: frame.midY, width: 1, height: 1)
    }

    override func draw(_ context: inout DrawContext) {
        let theme = Theme.current
        let palette = theme.palette
        guard let scale = window?.scale else { return }
        context.fill(bounds, color: palette.canvas)
        var y = frame.height * 0.2
        let title = TextLayout(TraktCopy.approveTitle, font: theme.type.title1, maxWidth: column, maxLines: 2, scale: scale)
        context.text(title, at: Point(x: leftX, y: y), color: palette.label)
        y += title.size.height + metrics.tv(36)
        let instruction = TextLayout(TraktCopy.approveAt(address), font: theme.type.callout, maxWidth: column, maxLines: 4, scale: scale)
        context.text(instruction, at: Point(x: leftX, y: y), color: palette.label)
        y += instruction.size.height + metrics.tv(48)
        context.faded(failed ? 0.3 : 1) { faded in
            drawTiles(code, at: Point(x: leftX, y: y), context: &faded)
        }
        if qr.text != nil {
            let caption = TextLayout(TraktCopy.scanToApprove, font: theme.type.body, maxWidth: qr.frame.width, maxLines: 2, alignment: .center, scale: scale)
            context.text(caption, at: Point(x: qr.frame.midX - caption.size.width / 2, y: qr.frame.maxY + metrics.tv(24)), color: palette.labelSecondary)
        }
    }

    /// The code as a row of eight tiles, one character each, empty tiles while it is requested.
    private func drawTiles(_ code: String?, at origin: Point, context: inout DrawContext) {
        let theme = Theme.current
        let scale = window?.scale ?? 1
        let gap = metrics.tv(12)
        let tile = min(metrics.tv(84), (column - gap * 7) / 8)
        let characters = code.map(Array.init) ?? []
        for index in 0..<8 {
            let rect = Rect(x: origin.x + Float(index) * (tile + gap), y: origin.y, width: tile, height: tile * 1.2)
            context.fill(rect, radius: metrics.radiusM, color: theme.palette.surfaceRaised)
            guard index < characters.count else { continue }
            let letter = TextLayout(String(characters[index]), font: Font(size: tile * 0.55, weight: .bold), scale: scale)
            context.text(letter, at: Point(x: (rect.midX - letter.size.width / 2).rounded(), y: (rect.midY - letter.size.height / 2).rounded()),
                         color: theme.palette.label)
        }
    }
}

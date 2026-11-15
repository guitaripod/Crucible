import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// The words Crucible Server's screens use on Linux, where this computer pairs as the Apple TV does.
enum CrucibleServerCopy {
    static let codeSteps = String(
        localized: "On an iPhone or iPad already paired with Crucible Server, scan this code with the Camera. This computer finishes pairing on its own.",
        comment: "Shown beside the QR code a Linux computer shows for pairing with Crucible Server"
    )

    /// This computer's name as the server lists its devices: the host name without its domain.
    static var deviceName: String {
        let host = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? ""
        return host.isEmpty ? "Linux" : host
    }

    /// The value of the Crucible Server row: the paired computer's name, or Not Set Up.
    static var rowValue: String {
        CompanionStore.current()?.name ?? CompanionCopy.notSetUp
    }
}

/// Settings › Crucible Server on Linux (`TVCompanionViewController`): what it is and how to set it up, pairing by the code
/// `crucible-server setup` prints or by a QR code a paired iPhone scans, or once paired, the computer it is paired with,
/// how its model is doing, and Unpair.
@MainActor
final class CrucibleServerScreen: SettingsScaffold {
    private enum RowID {
        static let enterCode = "server.enterCode"
        static let showCode = "server.showCode"
        static let install = "server.install"
        static let unpair = "server.unpair"
    }

    private let panel = ContextPanel(content: .init(symbol: "server.rack", title: CompanionCopy.title))
    private var statusTask: Task<Void, Never>?
    private var status: String?

    init() {
        super.init(title: CompanionCopy.title)
        installContext(panel)
        render()
    }

    override func screenDidAppear() {
        refresh()
    }

    override func screenWillDisappear() {
        statusTask?.cancel()
    }

    private func render() {
        let server = CompanionStore.current()
        if let server {
            panel.content = .init(symbol: "server.rack", title: CompanionCopy.paired(server.name), status: status ?? CompanionCopy.checking,
                                  statusColor: Theme.current.palette.labelSecondary, body: CompanionCopy.pitch)
            setRows([
                RowItem(id: RowID.unpair, title: CompanionCopy.unpair, symbol: "xmark.circle", isDestructive: true),
            ])
        } else {
            panel.content = .init(symbol: "server.rack", title: CompanionCopy.title, status: status,
                                  statusColor: Theme.current.palette.labelSecondary,
                                  body: "\(CompanionCopy.pitch)\n\n\(CompanionCopy.stepsTV)")
            setRows([
                RowItem(id: RowID.enterCode, title: CompanionCopy.enterCode, symbol: "key", accessory: .chevron),
                RowItem(id: RowID.showCode, title: CompanionCopy.showCode, symbol: "qrcode", accessory: .chevron),
                RowItem(id: RowID.install, title: CompanionCopy.howToInstall, symbol: "arrow.up.right.square", accessory: .chevron),
            ])
        }
    }

    /// Draws the screen for the pairing as it stands and, when paired, asks the server how its model is doing.
    private func refresh() {
        status = nil
        render()
        statusTask?.cancel()
        guard let server = CompanionStore.current() else { return }
        statusTask = Task { [weak self] in
            let token = ServerBootstrap.connection()?.authToken ?? ""
            let text: String
            do throws(CompanionError) {
                text = CompanionCopy.status(try await CompanionClient(server: server, plexToken: token).brain())
            } catch {
                text = error.message
            }
            guard !Task.isCancelled, let self else { return }
            self.status = text
            self.render()
        }
    }

    override func rowSelected(_ id: String) {
        guard let window else { return }
        switch id {
        case RowID.enterCode:
            askForCode()
        case RowID.showCode:
            let screen = CrucibleServerCodeScreen()
            screen.onPaired = { [weak self] in
                guard let self else { return }
                _ = self.navigation?.pop()
                self.refresh()
            }
            navigation?.push(screen)
        case RowID.install:
            Browser.open(CompanionCopy.installURL)
        case RowID.unpair:
            AlertView.confirm(title: CompanionCopy.unpair, message: CompanionCopy.unpairMessage, confirm: CompanionCopy.unpair, in: window) { [weak self] in
                CompanionStore.forget()
                self?.refresh()
            }
        default:
            break
        }
    }

    private func askForCode() {
        guard let window else { return }
        var alert: AlertView?
        alert = AlertView(title: CompanionCopy.enterCode, message: CompanionCopy.stepsTV, actions: [
            AlertView.Action(CompanionCopy.pair) { [weak self] in self?.pair(code: alert?.text ?? "") },
            AlertView.Action(String(localized: "Cancel"), role: .cancel),
        ], fieldPlaceholder: CompanionCopy.codePlaceholder)
        alert?.present(in: window)
    }

    private func pair(code: String) {
        guard !code.isEmpty else { return }
        guard let invite = PreviouslyOnRequest.invite(code: code) else {
            status = CompanionError.codeRefused.message
            render()
            return
        }
        status = CompanionCopy.pairing
        render()
        Task { [weak self] in
            do throws(CompanionError) {
                _ = try await PreviouslyOnRequest.pair(invite, deviceName: CrucibleServerCopy.deviceName, platform: "linux")
                self?.refresh()
            } catch {
                self?.status = error.message
                self?.render()
            }
        }
    }
}

/// The QR code this computer shows to be added to Crucible Server (`TVCompanionCodeViewController`): a secret made here
/// that never leaves it. A paired iPhone scans it and hands the secret to the server over its pinned connection, while
/// this screen keeps trying to pair with it beside the Plex server; the code works only while the screen waits.
@MainActor
final class CrucibleServerCodeScreen: ScreenView {
    var onPaired: (@MainActor () -> Void)?

    private static let lifetime: TimeInterval = 600
    private let deadline = Date().addingTimeInterval(CrucibleServerCodeScreen.lifetime)
    private lazy var device = CompanionDeviceInvite(name: CrucibleServerCopy.deviceName, secret: CompanionInvite.newSecret(), expires: deadline)
    private let code = QRCodeView()
    private let cancel = ButtonView(style: .glass, title: String(localized: "Cancel"))
    private var status = CompanionCopy.waitingForIPhone
    private var waiting: Task<Void, Never>?

    init() {
        super.init()
        code.text = device.link.absoluteString
        cancel.onPress = { [weak self] in _ = self?.navigation?.pop() }
        [code, cancel].forEach(addSubview)
    }

    override var preferredFocusView: View? { cancel }

    override func screenDidAppear() {
        guard waiting == nil else { return }
        wait()
    }

    override func screenWillDisappear() {
        waiting?.cancel()
        waiting = nil
    }

    private func wait() {
        let hosts = PreviouslyOnRequest.hostsBesidePlex()
        guard !hosts.isEmpty else {
            show(CompanionError.unreachable.message)
            return
        }
        let invite = CompanionInvite(name: CompanionCopy.title, hosts: hosts, secret: device.secret, fingerprint: nil)
        let deadline = deadline
        waiting = Task { [weak self] in
            do throws(CompanionError) {
                let server = try await PreviouslyOnRequest.waitForHandOff(invite, deviceName: CrucibleServerCopy.deviceName, platform: "linux", until: deadline)
                self?.show(CompanionCopy.paired(server.name))
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.onPaired?()
            } catch {
                guard !Task.isCancelled else { return }
                self?.show(error == .codeRefused ? CompanionCopy.codeExpired : error.message)
            }
        }
    }

    private func show(_ text: String) {
        status = text
        setNeedsLayout()
        setNeedsDisplay()
    }

    private var columns: (qr: Rect, text: Rect) {
        let metrics = Theme.current.metrics
        let side = min(metrics.tv(520), bounds.height - metrics.tabBarClearance - metrics.tv(120))
        let textWidth = min(metrics.tv(860), bounds.width - side - metrics.sideMargin * 2 - metrics.tv(80))
        let x = ((bounds.width - side - metrics.tv(80) - textWidth) / 2).rounded()
        let y = (metrics.tabBarClearance + (bounds.height - metrics.tabBarClearance - side) / 2).rounded()
        return (Rect(x: x, y: y, width: side, height: side), Rect(x: x + side + metrics.tv(80), y: y, width: textWidth, height: side))
    }

    private func layouts(width: Float, scale: Float) -> (heading: TextLayout, steps: TextLayout, status: TextLayout) {
        let type = Theme.current.type
        return (TextLayout(CompanionCopy.showCode, font: type.title2, maxWidth: width, maxLines: 2, scale: scale),
                TextLayout(CrucibleServerCopy.codeSteps, font: type.body, maxWidth: width, maxLines: 0, scale: scale),
                TextLayout(status, font: type.body, maxWidth: width, maxLines: 0, scale: scale))
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let (qr, text) = columns
        code.frame = qr
        let parts = layouts(width: text.width, scale: window?.scale ?? 1)
        let gap = metrics.tv(32)
        let height = parts.heading.size.height + parts.steps.size.height + parts.status.size.height + gap * 3 + metrics.primaryControlHeight
        let y = (text.midY - height / 2).rounded() + parts.heading.size.height + parts.steps.size.height + parts.status.size.height + gap * 3
        let width = cancel.sizeThatFits(Size(width: text.width, height: metrics.primaryControlHeight)).width
        cancel.frame = Rect(x: text.x, y: y, width: width, height: metrics.primaryControlHeight)
    }

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let theme = Theme.current
        context.fill(bounds, color: theme.palette.canvas)
        let (_, text) = columns
        let parts = layouts(width: text.width, scale: scale)
        let gap = theme.metrics.tv(32)
        let height = parts.heading.size.height + parts.steps.size.height + parts.status.size.height + gap * 3 + theme.metrics.primaryControlHeight
        var y = (text.midY - height / 2).rounded()
        context.text(parts.heading, at: Point(x: text.x, y: y), color: theme.palette.label)
        y += parts.heading.size.height + gap
        context.text(parts.steps, at: Point(x: text.x, y: y), color: theme.palette.labelSecondary)
        y += parts.steps.size.height + gap
        context.text(parts.status, at: Point(x: text.x, y: y), color: theme.palette.label)
    }
}

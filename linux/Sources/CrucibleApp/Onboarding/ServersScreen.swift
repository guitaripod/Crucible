import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// The account's Plex servers with the route Crucible found fastest (`TVChooseServerViewController`). With a single server
/// it connects by itself; with several, once exactly one answers it continues. A server that does not answer can be tested
/// again, an address can always be typed instead, and a failed connection keeps the list with a word why above it.
@MainActor
final class ServersScreen: ScreenView {
    var onConnected: ((PlexConnection) -> Void)?
    var onAddAddress: ((ServerChoice?, String?) -> Void)?
    var onSignInAgain: (() -> Void)?

    private enum RowID {
        static let addAddress = "action.addAddress"
        static let retry = "action.retry"
        static let signInAgain = "action.signInAgain"
        static let recoveryPrefix = "recovery."
        static let serverPrefix = "server."
    }

    private let discovery: ServerDiscovery
    private let token: String

    /// The Plex account token the list was read with, for Add by Address.
    var accountToken: String { token }
    private let rows = RowListView()
    private let state = StateView()
    private let heading = ScreenTitleView(title: "")
    private let errorLine = MessageLineView()
    private var picker: ServerPickerState?
    private var rowIDs: [String] = []
    private var singleServer: ServerChoice?
    private var recovery: ConnectRecovery?
    private var tailnetWhenRecoveryShown = false
    private var tasks: [Task<Void, Never>] = []
    private var isConnecting = false
    private var allowsAutoContinue = false

    init(token: String) {
        self.token = token
        discovery = ServerDiscovery(token: token)
        super.init()
        heading.columnWidth = Theme.current.metrics.wideColumn
        errorLine.columnWidth = Theme.current.metrics.wideColumn
        rows.columnWidth = Theme.current.metrics.wideColumn
        [heading, errorLine, rows, state].forEach(addSubview)
        rows.onSelect = { [weak self] item in self?.select(item.id) }
        state.isHidden = true
    }

    override var preferredFocusView: View? { state.isHidden ? rows : state }

    override func screenDidAppear() {
        if tasks.isEmpty { load() }
    }

    override func screenWillDisappear() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    /// Searching again is worth it only when Tailscale was turned on or off since a server could not be reached.
    func windowBecameActive() {
        guard recovery != nil, !isConnecting, TailnetPresence.isConnected != tailnetWhenRecoveryShown else { return }
        load()
    }

    private func load() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        picker = nil
        singleServer = nil
        recovery = nil
        setBusy(String(localized: "Finding your servers…"))
        tasks.append(Task { [weak self] in
            guard let self else { return }
            do {
                switch try await discovery.listing(progress: { [weak self] in self?.setBusy($0.message) }) {
                case .none:
                    show(title: String(localized: "No Plex Server Found"),
                         subtitle: String(localized: "This account doesn’t own or share a Plex Media Server. Sign in with the account that has your server, or add one by its address."),
                         rows: [RowID.addAddress, RowID.retry])
                case .single(let server):
                    singleServer = server
                    await connectToOnly(server)
                case .several(let servers):
                    showServers(servers)
                }
            } catch {
                guard !Task.isCancelled else { return }
                showLoadFailure(error)
            }
        })
    }

    private func showLoadFailure(_ error: Error) {
        if let apiError = error as? APIError, case .unauthorized = apiError {
            show(title: String(localized: "Sign-in Expired"),
                 subtitle: String(localized: "Plex needs you to sign in again before Crucible can list your servers."),
                 rows: [RowID.signInAgain, RowID.addAddress])
        } else {
            show(title: String(localized: "Couldn’t Load Your Servers"), subtitle: ConnectionError.message(for: error),
                 rows: [RowID.retry, RowID.addAddress])
        }
    }

    private func connectToOnly(_ server: ServerChoice) async {
        let outcome = await discovery.connect(toOnly: server) { [weak self] progress in self?.setBusy(progress.message) }
        guard !Task.isCancelled else { return }
        switch outcome {
        case .connected(let connection):
            onConnected?(connection)
        case .needsAddress(let message):
            let advice = ConnectRecovery(server: server, tailnetConnected: TailnetPresence.isConnected, access: .none, canUseToken: false)
            recovery = advice
            tailnetWhenRecoveryShown = TailnetPresence.isConnected
            show(title: String(localized: "Couldn’t Reach \(server.name)"),
                 subtitle: message ?? String(localized: "Crucible found no route to this server. Enter its address instead."),
                 rows: [RowID.addAddress, RowID.retry] + advice.steps.indices.map { RowID.recoveryPrefix + String($0) })
        case .failed(let message):
            show(title: String(localized: "Couldn’t Connect to \(server.name)"), subtitle: message, rows: [RowID.retry, RowID.addAddress])
        case .cancelled:
            break
        }
    }

    private func showServers(_ servers: [ServerChoice]) {
        var picker = ServerPickerState(choices: servers)
        for (server, route) in picker.unprobeableRoutes { _ = picker.record(server: server, route: route, milliseconds: nil) }
        self.picker = picker
        allowsAutoContinue = true
        show(title: String(localized: "Choose Server"), subtitle: String(localized: "Crucible tests every connection and picks the fastest."),
             rows: servers.map { RowID.serverPrefix + $0.id } + [RowID.addAddress])
        startProbing(picker.probeTargets)
    }

    private func startProbing(_ targets: [RouteProbeTarget]) {
        let measurements = discovery.measureRoutes(targets)
        tasks.append(Task { [weak self] in
            for await measurement in measurements {
                guard !Task.isCancelled, let self else { return }
                if self.picker?.record(server: measurement.serverID, route: measurement.routeIndex, milliseconds: measurement.milliseconds) == true {
                    self.refreshRows()
                    self.continueIfDecided()
                }
            }
            guard !Task.isCancelled, let self else { return }
            _ = self.picker?.finishProbing()
            self.refreshRows()
        })
    }

    /// Continues alone when exactly one server answered and every best route is known.
    private func continueIfDecided() {
        guard allowsAutoContinue, !isConnecting, let target = picker?.autoContinue else { return }
        allowsAutoContinue = false
        connect(target.choice, route: target.route)
    }

    private func show(title: String, subtitle: String, rows newRows: [String]) {
        isConnecting = false
        rowIDs = newRows
        heading.title = title
        heading.detail = subtitle
        errorLine.message = nil
        state.isHidden = true
        heading.isHidden = false
        errorLine.isHidden = false
        rows.isHidden = false
        refreshRows()
        window?.focus.focus(rows, animated: false)
    }

    private func setBusy(_ text: String) {
        isConnecting = true
        heading.isHidden = true
        errorLine.isHidden = true
        rows.isHidden = true
        state.isHidden = false
        state.show(.loading(title: text))
    }

    private func endBusy() {
        isConnecting = false
        state.isHidden = true
        heading.isHidden = false
        errorLine.isHidden = false
        rows.isHidden = false
        window?.focus.focus(rows, animated: false)
    }

    private func refreshRows() {
        rows.setItems(rowIDs.map(rowItem))
        setNeedsLayout()
    }

    private func rowItem(_ id: String) -> RowItem {
        switch id {
        case RowID.addAddress:
            return RowItem(id: id, title: String(localized: "Add by Address"), subtitle: String(localized: "Type an IP address or hostname"), symbol: "plus",
                           accessory: .chevron)
        case RowID.retry:
            return RowItem(id: id, title: String(localized: "Try Again"), symbol: "arrow.clockwise")
        case RowID.signInAgain:
            return RowItem(id: id, title: String(localized: "Sign In Again"), symbol: "person.crop.circle.badge.checkmark", accessory: .chevron)
        default:
            if id.hasPrefix(RowID.recoveryPrefix) {
                guard let recovery, let index = Int(id.dropFirst(RowID.recoveryPrefix.count)), recovery.steps.indices.contains(index) else {
                    return RowItem(id: id, title: "")
                }
                let step = recovery.steps[index]
                return RowItem(id: id, title: recovery.title(of: step), subtitle: recovery.detail(of: step), symbol: Symbol(recovery.symbol(of: step)),
                               isStatic: true)
            }
            let serverID = String(id.dropFirst(RowID.serverPrefix.count))
            guard let choice = picker?.choice(withID: serverID) else {
                return RowItem(id: id, title: String(localized: "Server", comment: "Fallback row title for a server that is no longer listed"))
            }
            return RowItem(id: id, title: choice.name, subtitle: choice.statusLine, value: choice.routeValue, symbol: Self.symbol(for: choice),
                           accessory: .chevron, isEnabled: choice.reachability != .offline)
        }
    }

    private static func symbol(for choice: ServerChoice) -> Symbol {
        switch choice.reachability {
        case .offline: "moon.zzz"
        case .unreachable: "exclamationmark.triangle"
        case .probing: "server.rack"
        case .reachable: Symbol((choice.bestRoute?.kind ?? .remote).symbolName)
        }
    }

    private func select(_ id: String) {
        guard !isConnecting else { return }
        switch id {
        case RowID.addAddress:
            onAddAddress?(singleServer, nil)
        case RowID.retry:
            load()
        case RowID.signInAgain:
            onSignInAgain?()
        default:
            guard id.hasPrefix(RowID.serverPrefix) else { return }
            choose(String(id.dropFirst(RowID.serverPrefix.count)))
        }
    }

    /// A server whose routes all failed is tested again; one with a route connects through it.
    private func choose(_ serverID: String) {
        guard var picker, let choice = picker.choice(withID: serverID) else { return }
        allowsAutoContinue = false
        guard let route = choice.bestRoute else {
            let targets = picker.restartProbing(of: serverID)
            self.picker = picker
            refreshRows()
            if !targets.isEmpty { startProbing(targets) }
            return
        }
        _ = picker.choose(serverID)
        self.picker = picker
        connect(choice, route: route)
    }

    private func connect(_ choice: ServerChoice, route: ServerRoute) {
        guard !isConnecting else { return }
        errorLine.message = nil
        setBusy(String(localized: "Connecting to \(choice.name)…"))
        tasks.append(Task { [weak self] in
            guard let self else { return }
            let outcome = await discovery.connect(to: choice, route: route) { [weak self] progress in self?.setBusy(progress.message) }
            guard !Task.isCancelled else { return }
            switch outcome {
            case .connected(let connection):
                onConnected?(connection)
            case .failed(let message):
                endBusy()
                errorLine.message = message
                setNeedsLayout()
            case .needsAddress(let message):
                endBusy()
                onAddAddress?(choice, message)
            case .cancelled:
                endBusy()
            }
        })
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        state.frame = bounds
        let titleHeight = heading.sizeThatFits(bounds.size).height
        heading.frame = Rect(x: 0, y: metrics.tv(120), width: frame.width, height: titleHeight)
        let errorHeight = errorLine.sizeThatFits(bounds.size).height
        errorLine.frame = Rect(x: 0, y: heading.frame.maxY, width: frame.width, height: errorHeight)
        let height = rows.sizeThatFits(Size(width: frame.width, height: 0)).height
        rows.frame = Rect(x: 0, y: errorLine.frame.maxY + metrics.tv(40), width: frame.width, height: height)
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

/// A line in the destructive colour under a screen's title, lined up with its column: why something just failed.
@MainActor
final class MessageLineView: View {
    var message: String? { didSet { superview?.setNeedsLayout(); setNeedsDisplay() } }
    var columnWidth: Float?

    private func layout(width: Float) -> TextLayout? {
        guard let message, !message.isEmpty else { return nil }
        let metrics = Theme.current.metrics
        let column = min(columnWidth ?? metrics.wideColumn, width - metrics.sideMargin * 2)
        return TextLayout(message, font: Theme.current.type.callout, maxWidth: column, maxLines: 3, scale: window?.scale ?? 1)
    }

    override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: layout(width: size.width).map { $0.size.height + Theme.current.metrics.tv(24) } ?? 0)
    }

    override func draw(_ context: inout DrawContext) {
        guard let text = layout(width: bounds.width) else { return }
        let metrics = Theme.current.metrics
        let column = min(columnWidth ?? metrics.wideColumn, bounds.width - metrics.sideMargin * 2)
        context.text(text, at: Point(x: ((bounds.width - column) / 2).rounded(), y: metrics.tv(16)), color: Theme.current.palette.destructive)
    }
}

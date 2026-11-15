import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// Settings › Integrations › Seerr (`TVSeerrSettingsViewController`): finds Seerr beside the Plex server and signs in with
/// the Plex account already on this computer, so connecting takes one click; the address and an API key can still be
/// typed. Connected, it shows who is signed in, what they may request, the requests and Disconnect.
@MainActor
final class SeerrSettingsScreen: SettingsScaffold {
    private enum RowID {
        static let connect = "seerr.connect"
        static let guide = "seerr.guide"
        static let enterAddress = "seerr.enterAddress"
        static let apiKey = "seerr.apiKey"
        static let requests = "seerr.requests"
        static let disconnect = "seerr.disconnect"
    }

    private enum Discovery: Equatable {
        case idle
        case searching
        case found(URL, SeerrPublicSettings)
        case notFound

        /// Seerr answered and its setup is finished, so Connect can sign in.
        var isConnectable: Bool {
            if case .found(_, let settings) = self { return settings.initialized != false }
            return false
        }
    }

    private let api: APIClient
    private let panel = ContextPanel(content: .init(symbol: "tray.full", title: SeerrCopy.name))
    private var observation: UUID?
    private var discovery = Discovery.idle
    private var isConnecting = false
    private var pendingApprovals = 0
    private var renderedStatus: SeerrAccount.Status?

    init(api: APIClient) {
        self.api = api
        super.init(title: SeerrCopy.name)
        panel.wellView = BrandMarkView("seerr")
        installContext(panel)
        render()
    }

    override func screenDidAppear() {
        if observation == nil {
            observation = SeerrAccount.shared.observe { [weak self] in
                self?.render()
                self?.loadApprovals()
            }
        }
        if !discovery.isConnectable, discovery != .idle, discovery != .searching { discovery = .idle }
        discoverIfNeeded()
        loadApprovals()
        render()
    }

    override func screenWillDisappear() {
        if let observation { SeerrAccount.shared.stopObserving(observation) }
        observation = nil
    }

    private func render() {
        let account = SeerrAccount.shared
        var items: [RowItem] = []
        var body = SeerrCopy.pitch.headline + "\n" + SeerrCopy.pitch.story + "\n\n" + SeerrCopy.privacy
        switch account.status {
        case .restricted:
            body = SeerrCopy.restricted
        case .disconnected:
            items = disconnectedRows()
        case .needsReconnect(let connection):
            body = SeerrCopy.needsReconnect
            items = [
                RowItem(id: RowID.connect, title: SeerrCopy.reconnect, subtitle: connection.displayName, symbol: "link", accessory: .chevron),
                RowItem(id: RowID.disconnect, title: SeerrCopy.disconnect, symbol: "xmark.circle", isDestructive: true),
            ]
        case .connected(let connection):
            body = SeerrCopy.tagline + "\n\n" + SeerrCopy.privacy
            let name = connection.auth == .apiKey ? SeerrCopy.apiKeyAccount : (connection.user?.name ?? SeerrCopy.name)
            items = [
                RowItem(id: "seerr.user", title: name, subtitle: SeerrCopy.signedInAs, symbol: "person.crop.circle.fill", isStatic: true),
                RowItem(id: "seerr.address", title: SeerrCopy.name, value: connection.displayName, symbol: "server.rack", isStatic: true),
                RowItem(id: "seerr.rights", title: SeerrCopy.canRequest, value: Self.rightsLabel(account.permissions), symbol: "checkmark.shield", isStatic: true),
                RowItem(id: RowID.requests, title: SeerrCopy.requests, value: pendingApprovals > 0 ? SeerrCopy.pendingCount(pendingApprovals) : nil,
                        symbol: "tray.full", accessory: .chevron),
                RowItem(id: RowID.disconnect, title: SeerrCopy.disconnect, symbol: "xmark.circle", isDestructive: true),
            ]
        }
        panel.content = .init(symbol: "tray.full", title: SeerrCopy.name, subtitle: SeerrCopy.tagline, body: body + "\n\n" + SeerrCopy.worksWith)
        let focusedRow = window?.focusedView.flatMap { focused in rows.items.first { rows.row(id: $0.id).map(focused.isDescendant(of:)) == true } }
        let changed = renderedStatus != nil && renderedStatus != account.status
        renderedStatus = account.status
        setRows(items)
        let lostFocus = focusedRow.map { row in !items.contains { $0.id == row.id } } ?? false
        if changed || lostFocus, containsFocus || lostFocus, let row = rows.row(id: preferredRowID) ?? rows.preferredFocusView {
            window?.focus.focus(row, animated: false)
        }
    }

    /// The row the screen settles on (`preferredFocusRowID`): Requests once connected, Connect when there is something to
    /// connect to, otherwise the guide.
    private var preferredRowID: String {
        switch SeerrAccount.shared.status {
        case .connected: return RowID.requests
        case .needsReconnect: return RowID.connect
        default: return discovery.isConnectable ? RowID.connect : RowID.guide
        }
    }

    /// Not connected: what the search found (Connect when Seerr is ready), the guide while it is not, typing the address
    /// or an API key, and what Seerr brings, without the benefit that sells Crucible Pro, which Linux does not have.
    private func disconnectedRows() -> [RowItem] {
        if isConnecting {
            return [RowItem(id: "seerr.connecting", title: SeerrCopy.connecting, symbol: "arrow.triangle.2.circlepath", isStatic: true)]
        }
        var items: [RowItem] = []
        switch discovery {
        case .idle, .searching:
            items.append(RowItem(id: "seerr.searching", title: SeerrCopy.searching, symbol: "dot.radiowaves.left.and.right", isStatic: true))
        case .found(_, let settings) where settings.initialized == false:
            items.append(RowItem(id: "seerr.needsSetup", title: SeerrGuide.needsSetup, symbol: "info.circle", isStatic: true))
        case .found(let address, let settings):
            let name = SeerrConnection(address: address, auth: .plex, title: settings.applicationTitle).displayName
            items.append(RowItem(id: RowID.connect, title: SeerrCopy.connect, subtitle: SeerrCopy.found + " · " + name, symbol: "link", accessory: .chevron))
        case .notFound:
            items.append(RowItem(id: "seerr.notFound", title: SeerrCopy.notFound, symbol: "info.circle", isStatic: true))
        }
        if !discovery.isConnectable {
            items.append(RowItem(id: RowID.guide, title: SeerrGuide.title, subtitle: SeerrCopy.guideSubtitle, symbol: "list.number", accessory: .chevron))
        }
        items.append(RowItem(id: RowID.enterAddress, title: SeerrCopy.enterAddress, symbol: "keyboard"))
        if discovery != .idle, discovery != .searching {
            items.append(RowItem(id: RowID.apiKey, title: SeerrCopy.useAPIKey, symbol: "key"))
        }
        items += SeerrCopy.pitch.benefits.enumerated().filter { !$0.element.needsPro }.map { index, benefit in
            RowItem(id: "seerr.benefit\(index)", title: benefit.title, subtitle: benefit.detail, symbol: Symbol(benefit.symbol), isStatic: true)
        }
        return items
    }

    /// What this account may request: everything on its own, with approval, or nothing.
    static func rightsLabel(_ permissions: SeerrPermissions) -> String {
        guard permissions.canRequest(.movie) || permissions.canRequest(.tv) else { return SeerrCopy.cannotRequest }
        return permissions.autoApproves(.movie) && permissions.autoApproves(.tv) ? SeerrCopy.autoApproved : SeerrCopy.needsApproval
    }

    override func rowSelected(_ id: String) {
        switch id {
        case RowID.connect: connectToFoundOrSaved()
        case RowID.guide: openGuide()
        case RowID.enterAddress: askForAddress(thenAPIKey: false)
        case RowID.apiKey: askForAPIKey()
        case RowID.requests: navigation?.push(SeerrRequestsScreen(api: api))
        case RowID.disconnect:
            guard let window else { return }
            AlertView.confirm(title: SeerrCopy.disconnectTitle, message: SeerrCopy.disconnectMessage, confirm: SeerrCopy.disconnect, in: window) { [weak self] in
                Task {
                    await SeerrAccount.shared.disconnect()
                    self?.discovery = .idle
                    self?.discoverIfNeeded()
                }
            }
        default: break
        }
    }

    /// The setup guide; once Seerr is ready there, the guide closes and connecting starts here.
    private func openGuide() {
        let guide = SeerrGuideScreen(api: api) { [weak self] address, settings in
            guard let self else { return }
            self.navigation?.pop()
            self.discovery = .found(address, settings)
            self.connect(address: address, settings: settings, apiKey: nil)
        }
        navigation?.push(guide)
    }

    private func discoverIfNeeded() {
        guard SeerrAccount.shared.status == .disconnected, discovery == .idle else { return }
        discovery = .searching
        render()
        let saved = ServerBootstrap.connection()?.candidateURIs
        let api = api
        Task { [weak self] in
            let routes: [URL]
            if let saved { routes = saved } else { routes = [await api.baseURL] }
            let found = await SeerrAccount.shared.discover(serverRoutes: routes)
            guard let self else { return }
            self.discovery = found.map { .found($0.0, $0.1) } ?? .notFound
            self.render()
        }
    }

    private func connectToFoundOrSaved() {
        if case .found(let address, let settings) = discovery {
            connect(address: address, settings: settings, apiKey: nil)
        } else if let connection = SeerrAccount.shared.connection {
            connect(address: connection.address,
                    settings: SeerrPublicSettings(applicationTitle: connection.title, partialRequestsEnabled: connection.partialRequests), apiKey: nil)
        }
    }

    private func connect(address: URL, settings: SeerrPublicSettings, apiKey: String?) {
        isConnecting = true
        render()
        Task { [weak self] in
            do {
                try await SeerrAccount.shared.connect(address: address, settings: settings, apiKey: apiKey)
                self?.isConnecting = false
                self?.render()
            } catch {
                guard let self else { return }
                MidgarLog.error("Seerr connect failed: \(error)", category: .seerr)
                self.isConnecting = false
                self.discovery = .found(address, settings)
                self.render()
                self.alert(SeerrCopy.connectFailed, message: error.localizedDescription)
            }
        }
    }

    private func askForAddress(thenAPIKey: Bool) {
        guard let window else { return }
        var text = ""
        if case .found(let address, _) = discovery { text = SeerrDiscovery.displayAddress(address) }
        var entry: AlertView?
        let confirm = thenAPIKey ? String(localized: "Next") : SeerrCopy.connect
        entry = AlertView(title: SeerrCopy.addressTitle, message: SeerrCopy.addressMessage, actions: [
            AlertView.Action(confirm) { [weak self] in
                guard let typed = entry?.text, !typed.isEmpty else { return }
                self?.resolve(typed, thenAPIKey: thenAPIKey)
            },
            AlertView.Action(String(localized: "Cancel"), role: .cancel),
        ], fieldPlaceholder: SeerrCopy.addressPlaceholder, fieldText: text)
        entry?.present(in: window)
    }

    private func resolve(_ typed: String, thenAPIKey: Bool) {
        isConnecting = true
        render()
        Task { [weak self] in
            let result = await SeerrDiscovery.resolve(typed: typed)
            guard let self else { return }
            self.isConnecting = false
            switch result {
            case .success(let (address, settings)):
                self.discovery = .found(address, settings)
                self.render()
                if thenAPIKey { self.askForAPIKey() } else { self.connect(address: address, settings: settings, apiKey: nil) }
            case .failure(let error):
                self.render()
                self.alert(SeerrCopy.connectFailed, message: error.localizedDescription)
            }
        }
    }

    private func askForAPIKey() {
        guard case .found(let address, let settings) = discovery else { return askForAddress(thenAPIKey: true) }
        guard let window else { return }
        var entry: AlertView?
        entry = AlertView(title: SeerrCopy.apiKeyTitle, message: SeerrCopy.apiKeyMessage, actions: [
            AlertView.Action(String(localized: "Connect", comment: "Button that connects Seerr with the API key")) { [weak self] in
                guard let key = entry?.text, !key.isEmpty else { return }
                self?.connect(address: address, settings: settings, apiKey: key)
            },
            AlertView.Action(String(localized: "Cancel"), role: .cancel),
        ], fieldPlaceholder: SeerrCopy.apiKeyPlaceholder)
        entry?.present(in: window)
    }

    private func loadApprovals() {
        guard SeerrAccount.shared.managesRequests else {
            pendingApprovals = 0
            return
        }
        Task { [weak self] in
            let count = await SeerrRequests.shared.pendingCount()
            guard let self, count != self.pendingApprovals else { return }
            self.pendingApprovals = count
            self.render()
        }
    }

    private func alert(_ title: String, message: String?) {
        guard let window else { return }
        AlertView.notice(title: title, message: message, in: window)
    }
}

/// Settings › Integrations › Seerr › Set Up Seerr (`TVSeerrGuideViewController`): the five steps with what Crucible sees of
/// each right now, which machine runs Seerr (choosing cycles), and two codes to scan with a phone, the whole guide with
/// its commands and Seerr's own setup page on the home network. Connect appears the moment Seerr is ready.
@MainActor
final class SeerrGuideScreen: SettingsScaffold {
    private let watcher: SeerrSetupWatcher
    private let onReady: (URL, SeerrPublicSettings) -> Void
    private let context = SeerrGuideContext()

    init(api: APIClient, onReady: @escaping (URL, SeerrPublicSettings) -> Void) {
        watcher = SeerrSetupWatcher(api: api)
        self.onReady = onReady
        super.init(title: SeerrGuide.title)
        installContext(context)
        context.guideCode.text = SeerrGuide.webGuide.absoluteString
        render()
    }

    override func screenDidAppear() {
        watcher.start { [weak self] in self?.render() }
        render()
    }

    override func screenWillDisappear() {
        watcher.stop()
    }

    private func render() {
        context.panel.content = .init(symbol: "list.number", title: SeerrGuide.title,
                                      body: ServerOwnership.isOwner() ? SeerrGuide.intro : SeerrGuide.intro + "\n\n" + SeerrGuide.notOwner)
        context.showSetup(watcher.setupURL?.absoluteString)
        var items: [RowItem] = []
        if case .ready = watcher.seerr {
            items.append(RowItem(id: "seerrGuide.connect", title: SeerrCopy.connect, subtitle: SeerrGuide.readyToConnect, symbol: "link", accessory: .chevron))
        }
        items.append(RowItem(id: "seerrGuide.host", title: SeerrGuide.hostQuestion, value: watcher.host.title, symbol: "server.rack", accessory: .chevron))
        for step in SeerrGuide.Step.allCases {
            let status = status(for: step)
            items.append(RowItem(id: "seerrGuide.step.\(step.rawValue)", title: "\(step.rawValue + 1). \(SeerrGuide.title(step))",
                                 subtitle: SeerrGuide.summary(step, host: watcher.host, home: watcher.homeHost, server: watcher.serverName),
                                 value: status?.value, symbol: Symbol(status?.symbol ?? "circle"), isStatic: true))
        }
        items.append(RowItem(id: "seerrGuide.enterAddress", title: SeerrCopy.enterAddress, subtitle: SeerrGuide.otherAddress, symbol: "keyboard"))
        setRows(items)
    }

    /// What Crucible sees of `step` right now, or nil when there is nothing to say yet.
    private func status(for step: SeerrGuide.Step) -> (value: String, symbol: String)? {
        switch step {
        case .install:
            switch watcher.seerr {
            case .looking: return nil
            case .notFound: return (SeerrGuide.statusNotYet, "circle.dashed")
            case .needsSetup, .notPlex, .ready: return (SeerrGuide.statusFound, "checkmark.circle.fill")
            }
        case .setUp:
            switch watcher.seerr {
            case .ready: return (SeerrGuide.statusDone, "checkmark.circle.fill")
            case .needsSetup: return (SeerrGuide.statusUnfinished, "circle.dashed")
            case .notPlex: return (SeerrGuide.statusWrongServer, "exclamationmark.triangle")
            case .looking, .notFound: return nil
            }
        case .away:
            return watcher.deviceOnTailnet ? (SeerrGuide.statusOn, "checkmark.circle.fill") : (SeerrGuide.statusOff, "circle.dashed")
        case .downloads, .people:
            return nil
        }
    }

    override func rowSelected(_ id: String) {
        switch id {
        case "seerrGuide.connect":
            guard case .ready(let url, let settings) = watcher.seerr else { return }
            onReady(url, settings)
        case "seerrGuide.enterAddress":
            guard let window else { return }
            var entry: AlertView?
            entry = AlertView(title: SeerrCopy.addressTitle, message: SeerrCopy.addressMessage, actions: [
                AlertView.Action(SeerrGuide.lookThere) { [weak self] in
                    guard let typed = entry?.text, !typed.isEmpty else { return }
                    self?.watcher.add(typed: typed)
                },
                AlertView.Action(String(localized: "Cancel"), role: .cancel),
            ], fieldPlaceholder: SeerrCopy.addressPlaceholder)
            entry?.present(in: window)
        case "seerrGuide.host":
            let hosts = SeerrHost.allCases
            watcher.choose(hosts[((hosts.firstIndex(of: watcher.host) ?? 0) + 1) % hosts.count])
        default:
            break
        }
    }
}

/// The guide's left column: the panel with the introduction, and under it the two codes to scan, each on its white plate
/// with a caption; Seerr's own code shows once Crucible knows where its setup page is.
@MainActor
private final class SeerrGuideContext: View {
    let panel = ContextPanel(content: .init(symbol: "list.number", title: SeerrGuide.title))
    let guideCode = QRCodeView()
    private let setupCode = QRCodeView()

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        [panel, guideCode, setupCode].forEach(addSubview)
        setupCode.isHidden = true
    }

    func showSetup(_ address: String?) {
        setupCode.text = address
        setupCode.isHidden = address == nil
        setNeedsLayout()
        setNeedsDisplay()
    }

    private var spacing: Float { Theme.current.metrics.tv(40) }
    private var codeSide: Float { Theme.current.metrics.tv(240) }
    private var captionGap: Float { Theme.current.metrics.tv(14) }

    private func caption(_ text: String, scale: Float) -> TextLayout {
        TextLayout(text, font: Theme.current.type.footnote, maxWidth: codeSide, maxLines: 3, alignment: .center, scale: scale)
    }

    private var captionHeight: Float {
        let scale = window?.scale ?? 1
        return max(caption(SeerrGuide.scanForGuide, scale: scale).size.height, caption(SeerrGuide.scanForSeerr, scale: scale).size.height)
    }

    override func sizeThatFits(_ size: Size) -> Size {
        let panelHeight = panel.sizeThatFits(size).height
        return Size(width: size.width, height: panelHeight + spacing + codeSide + captionGap + captionHeight)
    }

    override func layoutSubviews() {
        let panelHeight = panel.sizeThatFits(Size(width: frame.width, height: 0)).height
        panel.frame = Rect(x: 0, y: 0, width: frame.width, height: panelHeight)
        let y = panelHeight + spacing
        guideCode.frame = Rect(x: 0, y: y, width: codeSide, height: codeSide)
        setupCode.frame = Rect(x: codeSide + spacing, y: y, width: codeSide, height: codeSide)
    }

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let color = Theme.current.palette.labelSecondary
        for (code, text) in [(guideCode, SeerrGuide.scanForGuide), (setupCode, SeerrGuide.scanForSeerr)] where !code.isHidden {
            let layout = caption(text, scale: scale)
            context.text(layout, at: Point(x: code.frame.minX + ((codeSide - layout.size.width) / 2).rounded(), y: code.frame.maxY + captionGap), color: color)
        }
    }
}

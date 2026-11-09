import CrucibleCore
import CrucibleDesign
import UIKit

/// Settings › Integrations › Seerr on Apple TV: finds Seerr next to the Plex server and signs in with the Plex account
/// already on this Apple TV, so connecting takes one click; the address and an API key can still be typed.
final class TVSeerrSettingsViewController: TVSettingsScaffold {
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

    private let env: TVAppEnvironment
    private let heading = TVSettingsHeading(title: SeerrCopy.name)
    private var observation: UUID?
    private var discovery = Discovery.idle
    private var isConnecting = false
    private var pendingApprovals = 0

    init(env: TVAppEnvironment) {
        self.env = env
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observation { Task { @MainActor in SeerrAccount.shared.stopObserving(observation) } }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installHeading(heading)
        render()
        observation = SeerrAccount.shared.observe { [weak self] in
            self?.render()
            self?.loadApprovals()
        }
        discoverIfNeeded()
        loadApprovals()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !discovery.isConnectable, discovery != .idle, discovery != .searching {
            discovery = .idle
            discoverIfNeeded()
        }
        render()
    }

    override var preferredFocusRowID: String? {
        switch SeerrAccount.shared.status {
        case .connected: return "seerr.requests"
        case .needsReconnect: return "seerr.connect"
        default: return discovery.isConnectable ? "seerr.connect" : "seerr.guide"
        }
    }

    private func render() {
        let account = SeerrAccount.shared
        var rows: [TVRowItem] = []
        var body = SeerrCopy.pitch.contextText + "\n\n" + SeerrCopy.privacy
        switch account.status {
        case .restricted:
            body = SeerrCopy.restricted
        case .disconnected:
            if isConnecting {
                rows.append(TVRowItem(id: "seerr.connecting", title: SeerrCopy.connecting, symbol: "arrow.triangle.2.circlepath", isStatic: true))
            } else {
                switch discovery {
                case .idle, .searching:
                    rows.append(TVRowItem(id: "seerr.searching", title: SeerrCopy.searching, symbol: "dot.radiowaves.left.and.right", isStatic: true))
                case .found(_, let settings) where settings.initialized == false:
                    rows.append(TVRowItem(id: "seerr.needsSetup", title: SeerrGuide.needsSetup, symbol: "info.circle", isStatic: true))
                case .found(let address, let settings):
                    let name = SeerrConnection(address: address, auth: .plex, title: settings.applicationTitle).displayName
                    rows.append(TVRowItem(id: "seerr.connect", title: SeerrCopy.connect, subtitle: SeerrCopy.found + " · " + name, symbol: "link", accessory: .chevron))
                case .notFound:
                    rows.append(TVRowItem(id: "seerr.notFound", title: SeerrCopy.notFound, symbol: "info.circle", isStatic: true))
                }
                if !discovery.isConnectable {
                    rows.append(TVRowItem(id: "seerr.guide", title: SeerrGuide.title, subtitle: SeerrCopy.guideSubtitle, symbol: "list.number", accessory: .chevron))
                }
                rows.append(TVRowItem(id: "seerr.enterAddress", title: SeerrCopy.enterAddress, symbol: "keyboard"))
                if discovery != .idle, discovery != .searching {
                    rows.append(TVRowItem(id: "seerr.apiKey", title: SeerrCopy.useAPIKey, symbol: "key"))
                }
                rows += SeerrCopy.pitch.benefitRows(idPrefix: "seerr")
            }
        case .needsReconnect(let connection):
            body = SeerrCopy.needsReconnect
            rows.append(TVRowItem(id: "seerr.connect", title: SeerrCopy.reconnect, subtitle: connection.displayName, symbol: "link", accessory: .chevron))
            rows.append(TVRowItem(id: "seerr.disconnect", title: SeerrCopy.disconnect, symbol: "xmark.circle", isDestructive: true))
        case .connected(let connection):
            body = SeerrCopy.tagline + "\n\n" + SeerrCopy.privacy
            let name = connection.auth == .apiKey ? SeerrCopy.apiKeyAccount : (connection.user?.name ?? SeerrCopy.name)
            rows += [
                TVRowItem(id: "seerr.user", title: name, subtitle: SeerrCopy.signedInAs, symbol: "person.crop.circle.fill", isStatic: true),
                TVRowItem(id: "seerr.address", title: SeerrCopy.name, value: connection.displayName, symbol: "server.rack", isStatic: true),
                TVRowItem(id: "seerr.rights", title: SeerrCopy.canRequest, value: Self.rightsLabel(account.permissions), symbol: "checkmark.shield", isStatic: true),
                TVRowItem(id: "seerr.requests", title: SeerrCopy.requests, value: pendingApprovals > 0 ? SeerrCopy.pendingCount(pendingApprovals) : nil, symbol: "tray.full", accessory: .chevron),
                TVRowItem(id: "seerr.disconnect", title: SeerrCopy.disconnect, symbol: "xmark.circle", isDestructive: true),
            ]
        }
        heading.setBody(body + "\n\n" + SeerrCopy.worksWith)
        setRows(rows)
    }

    static func rightsLabel(_ permissions: SeerrPermissions) -> String {
        guard permissions.canRequest(.movie) || permissions.canRequest(.tv) else { return SeerrCopy.cannotRequest }
        return permissions.autoApproves(.movie) && permissions.autoApproves(.tv) ? SeerrCopy.autoApproved : SeerrCopy.needsApproval
    }

    override func rowDidSelect(_ id: String) {
        switch id {
        case "seerr.connect": connectToFoundOrSaved()
        case "seerr.guide": openGuide()
        case "seerr.enterAddress": askForAddress(thenAPIKey: false)
        case "seerr.apiKey": askForAPIKey()
        case "seerr.requests": TVNavigation.push(TVSeerrRequestsViewController(env: env), from: self)
        case "seerr.disconnect":
            presentConfirmation(title: SeerrCopy.disconnectTitle, message: SeerrCopy.disconnectMessage, confirmTitle: SeerrCopy.disconnect) { [weak self] in
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
        let guide = TVSeerrGuideViewController(env: env) { [weak self] address, settings in
            guard let self else { return }
            navigationController?.popToViewController(self, animated: true)
            discovery = .found(address, settings)
            connect(address: address, settings: settings, apiKey: nil)
        }
        TVNavigation.push(guide, from: self)
    }

    private func discoverIfNeeded() {
        guard SeerrAccount.shared.status == .disconnected, discovery == .idle else { return }
        discovery = .searching
        render()
        let routes = ServerBootstrap.connection()?.candidateURIs ?? [env.api.baseURL]
        Task { [weak self] in
            let found = await SeerrAccount.shared.discover(serverRoutes: routes)
            guard let self else { return }
            discovery = found.map { .found($0.0, $0.1) } ?? .notFound
            render()
        }
    }

    private func connectToFoundOrSaved() {
        if case .found(let address, let settings) = discovery {
            connect(address: address, settings: settings, apiKey: nil)
        } else if let connection = SeerrAccount.shared.connection {
            connect(address: connection.address, settings: SeerrPublicSettings(applicationTitle: connection.title, partialRequestsEnabled: connection.partialRequests), apiKey: nil)
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
                isConnecting = false
                discovery = .found(address, settings)
                render()
                presentAlert(title: SeerrCopy.connectFailed, message: error.localizedDescription)
            }
        }
    }

    private func askForAddress(thenAPIKey: Bool) {
        var text = ""
        if case .found(let address, _) = discovery { text = SeerrDiscovery.displayAddress(address) }
        presentTextEntry(title: SeerrCopy.addressTitle, message: SeerrCopy.addressMessage, text: text, placeholder: SeerrCopy.addressPlaceholder, keyboard: .URL, confirmTitle: thenAPIKey ? String(localized: "Next") : SeerrCopy.connect) { [weak self] typed in
            self?.resolve(typed, thenAPIKey: thenAPIKey)
        }
    }

    private func resolve(_ typed: String, thenAPIKey: Bool) {
        isConnecting = true
        render()
        Task { [weak self] in
            let result = await SeerrDiscovery.resolve(typed: typed)
            guard let self else { return }
            isConnecting = false
            switch result {
            case .success(let (address, settings)):
                discovery = .found(address, settings)
                render()
                if thenAPIKey { askForAPIKey() } else { connect(address: address, settings: settings, apiKey: nil) }
            case .failure(let error):
                render()
                presentAlert(title: SeerrCopy.connectFailed, message: error.localizedDescription)
            }
        }
    }

    private func askForAPIKey() {
        guard case .found(let address, let settings) = discovery else { return askForAddress(thenAPIKey: true) }
        presentTextEntry(title: SeerrCopy.apiKeyTitle, message: SeerrCopy.apiKeyMessage, text: "", placeholder: SeerrCopy.apiKeyPlaceholder, confirmTitle: String(localized: "Connect", comment: "Button that connects Seerr with the API key")) { [weak self] key in
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self?.connect(address: address, settings: settings, apiKey: trimmed)
        }
    }

    private func loadApprovals() {
        guard SeerrAccount.shared.managesRequests else {
            pendingApprovals = 0
            return
        }
        Task { [weak self] in
            let count = await SeerrRequests.shared.pendingCount()
            guard let self, count != pendingApprovals else { return }
            pendingApprovals = count
            render()
        }
    }
}

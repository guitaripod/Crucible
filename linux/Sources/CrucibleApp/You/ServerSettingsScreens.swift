import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// Server & Connection (`TVServerSettingsViewController`): the server card on the left; every known route with its
/// measured latency, Test Connection, the connection preferences and the ways to add or change server on the right.
@MainActor
final class ServerConnectionScreen: SettingsScaffold {
    private enum RowID {
        static let test = "server.test"
        static let preferLocal = "server.preferLocal"
        static let allowRelay = "server.allowRelay"
        static let addServer = "server.addServer"
        static let switchServer = "server.switchServer"
        static let routePrefix = "server.route."
    }

    private let model = ServerConnectionModel()
    private let card = ContextPanel(content: .init(symbol: "server.rack", title: ""))

    init() {
        super.init(title: String(localized: "Server & Connection"))
        installContext(card)
        model.onChange = { [weak self] in self?.render() }
        render()
    }

    override func screenDidAppear() {
        render()
        model.startIfNeeded()
    }

    override func screenWillDisappear() {
        model.stop()
    }

    override func rowSelected(_ id: String) {
        switch id {
        case RowID.test:
            if !model.isTesting { model.runTest() }
            render()
        case RowID.preferLocal:
            flip(.preferLocalConnection)
        case RowID.allowRelay:
            flip(.allowRelayConnection)
        case RowID.addServer:
            navigation?.push(AddServerScreen())
        case RowID.switchServer:
            rootView?.onSwitchServer?()
        default:
            guard id.hasPrefix(RowID.routePrefix), let url = URL(string: String(id.dropFirst(RowID.routePrefix.count))) else { return }
            use(url)
        }
    }

    /// Uses the route picked until the network changes; a route that does not answer as the server is refused with a word why.
    private func use(_ url: URL) {
        Task { [weak self] in
            guard let self else { return }
            if await self.model.use(url) {
                self.render()
                return
            }
            guard let window = self.window else { return }
            AlertView.notice(title: String(localized: "Couldn’t Use This Connection", comment: "Alert when a picked server connection does not answer"),
                             message: String(localized: "It didn’t answer as your server, so Crucible stays on the connection it uses now.",
                                             comment: "Alert when a picked server connection does not answer"),
                             in: window)
        }
    }

    private func flip(_ setting: PreferenceSetting) {
        setting.setOn(!setting.isOn)
        render()
    }

    private func render() {
        let summary = model.card
        let palette = Theme.current.palette
        let tone: Color
        switch summary.tone {
        case .ok: tone = palette.statusOK
        case .failure: tone = palette.destructive
        case .neutral: tone = palette.labelTertiary
        }
        card.content = .init(symbol: "server.rack", title: summary.name, subtitle: summary.subtitle, status: summary.status, statusColor: tone,
                             body: ServerConnectionModel.routesFooter)
        var items = model.routeRows.map { route in
            RowItem(id: RowID.routePrefix + route.url.absoluteString, title: route.kindTitle,
                    subtitle: route.isInUse ? String(localized: "In use · \(route.detail)") : route.detail, value: route.latencyText,
                    symbol: Symbol(route.kind.symbolName), accessory: route.isInUse ? .checkmark : .none)
        }
        items.append(RowItem(id: RowID.test, title: String(localized: "Test Connection"), value: model.isTesting ? String(localized: "Testing…") : nil,
                             symbol: "bolt.horizontal"))
        items.append(toggle(RowID.preferLocal, .preferLocalConnection, symbol: "wifi"))
        items.append(toggle(RowID.allowRelay, .allowRelayConnection, symbol: "arrow.triangle.swap"))
        items.append(RowItem(id: RowID.addServer, title: String(localized: "Add Server by Address"), symbol: "plus", accessory: .chevron))
        items.append(RowItem(id: RowID.switchServer, title: String(localized: "Switch Server"), symbol: "arrow.left.arrow.right", accessory: .chevron))
        setRows(items)
    }

    private func toggle(_ id: String, _ setting: PreferenceSetting, symbol: Symbol) -> RowItem {
        RowItem(id: id, title: setting.title, value: setting.valueLabel, symbol: symbol)
    }
}

/// Add Server by Address in Settings (`TVAddServerViewController`): the address expands into candidate URLs, the first one
/// that answers as a Plex server is saved, and the app reconnects to it.
@MainActor
final class AddServerScreen: ScreenView {
    private let heading = ScreenTitleView(title: String(localized: "Add Server by Address"),
                                          detail: String(localized: "Enter an IP address, hostname or full URL. The default port is 32400."))
    private let form = AddressForm(initialText: nil)
    private var connectTask: Task<Void, Never>?

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        heading.columnWidth = Theme.current.metrics.formColumn
        [heading, form].forEach(addSubview)
        form.onSubmit = { [weak self] text in self?.connect(text) }
    }

    override var preferredFocusView: View? { form }

    override func screenWillDisappear() {
        connectTask?.cancel()
        connectTask = nil
    }

    private func connect(_ input: String) {
        guard connectTask == nil else { return }
        guard let candidates = AddServerLookup.candidates(from: input) else {
            form.showError(AddServerLookup.invalidAddressMessage)
            return
        }
        guard let token = ServerBootstrap.connection()?.authToken else { return }
        form.setBusy(true, status: String(localized: "Connecting…"))
        connectTask = Task { [weak self] in
            let found = await AddServerLookup.find(among: candidates, token: token)
            guard let self, !Task.isCancelled else { return }
            self.connectTask = nil
            self.form.setBusy(false)
            guard let found else {
                MidgarLog.error("Add server: nothing answered at \(input)", category: .networking)
                self.form.showError(AddServerLookup.notFoundMessage(for: input))
                return
            }
            AddServerLookup.save(found)
            self.rootView?.onReconnect?()
        }
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let width = min(metrics.formColumn, frame.width - metrics.sideMargin * 2)
        let titleHeight = heading.sizeThatFits(bounds.size).height
        heading.frame = Rect(x: 0, y: metrics.tabBarClearance, width: frame.width, height: titleHeight)
        let formHeight = form.sizeThatFits(Size(width: width, height: 0)).height
        form.frame = Rect(x: ((frame.width - width) / 2).rounded(), y: heading.frame.maxY + metrics.tv(40), width: width, height: formHeight)
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

/// About Crucible (`TVAboutViewController`): the app's identity on the left; version, build, licence, source, the support
/// address and the open-source credits on the right.
@MainActor
final class AboutScreen: SettingsScaffold {
    private struct Credit {
        let name: String
        let license: String
        let url: URL
    }

    /// Core's credits and what the Linux client is built on.
    private static var credits: [Credit] {
        AppInfo.acknowledgements.map { Credit(name: $0.name, license: $0.license, url: $0.url) } + linuxCredits
    }

    private static let linuxCredits = [
        Credit(name: "mpv", license: "LGPL-2.1+", url: URL(string: "https://mpv.io")!),
        Credit(name: "libplacebo", license: "LGPL-2.1+", url: URL(string: "https://code.videolan.org/videolan/libplacebo")!),
        Credit(name: "FFmpeg", license: "LGPL-2.1+", url: URL(string: "https://ffmpeg.org")!),
        Credit(name: "Inter", license: "OFL-1.1", url: URL(string: "https://rsms.me/inter")!),
        Credit(name: "Lucide", license: "ISC", url: URL(string: "https://lucide.dev")!),
        Credit(name: "Pango", license: "LGPL-2.1+", url: URL(string: "https://gitlab.gnome.org/GNOME/pango")!),
        Credit(name: "librsvg", license: "LGPL-2.1+", url: URL(string: "https://gitlab.gnome.org/GNOME/librsvg")!),
        Credit(name: "libsecret", license: "LGPL-2.1+", url: URL(string: "https://gitlab.gnome.org/GNOME/libsecret")!),
        Credit(name: "libqrencode", license: "LGPL-2.1+", url: URL(string: "https://github.com/fukuchi/libqrencode")!),
        Credit(name: "swift-crypto", license: "Apache-2.0", url: URL(string: "https://github.com/apple/swift-crypto")!),
    ]

    private var updateObserver: UUID?

    init() {
        super.init(title: String(localized: "About Crucible"))
        let panel = ContextPanel(content: .init(symbol: "sparkles", title: "Crucible", subtitle: String(localized: "Version \(AppInfo.versionSummary)"),
                                                body: AppInfo.licenseSummary))
        panel.wellView = CrystalGlyphView()
        installContext(panel)
        updateObserver = SoftwareUpdate.shared.observe { [weak self] in self?.refreshRows() }
        refreshRows()
    }

    deinit {
        let observer = updateObserver
        Task { @MainActor in observer.map(SoftwareUpdate.shared.stopObserving) }
    }

    /// Software Update first, saying when a newer release is out, then the facts and the credits.
    private func refreshRows() {
        var items = [
            RowItem(id: "about.update", title: String(localized: "Software Update"),
                    value: SoftwareUpdate.shared.hasUpdate ? String(localized: "Update Available") : nil, symbol: "arrow.down.circle", accessory: .chevron),
            RowItem(id: "about.version", title: String(localized: "Version"), value: AppInfo.versionText, symbol: "info.circle"),
            RowItem(id: "about.build", title: String(localized: "Build", comment: "Build number of the app"), value: AppInfo.buildText, symbol: "hammer"),
            RowItem(id: "about.license", title: String(localized: "License"), value: AppInfo.licenseName, symbol: "doc.text"),
        ]
        if let source = AppInfo.sourceURL {
            items.append(RowItem(id: "about.source", title: String(localized: "Source Code"), subtitle: (source.host ?? "") + source.path,
                                 symbol: "chevron.left.forwardslash.chevron.right", accessory: .chevron))
        }
        items.append(RowItem(id: "about.support", title: String(localized: "Support"), subtitle: AppInfo.supportAddress, symbol: "envelope",
                             accessory: .chevron))
        for credit in Self.credits {
            items.append(RowItem(id: "about.credit.\(credit.name)", title: credit.name, subtitle: (credit.url.host ?? "") + credit.url.path,
                                 value: credit.license, symbol: "shippingbox"))
        }
        setRows(items)
    }

    override func rowSelected(_ id: String) {
        switch id {
        case "about.update": navigation?.push(SoftwareUpdateScreen())
        case "about.source": AppInfo.sourceURL.map(Browser.open)
        case "about.support": AppInfo.supportMailURL.map(Browser.open)
        default:
            guard let credit = Self.credits.first(where: { "about.credit.\($0.name)" == id }) else { return }
            Browser.open(credit.url)
        }
    }
}

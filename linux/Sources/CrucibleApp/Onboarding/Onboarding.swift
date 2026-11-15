import CLinuxServices
import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// Signing in on a desk: a welcome screen, then plex.tv in the browser (the code and a QR code stay on screen for signing
/// in from another device), then the account's servers, each probed for its fastest route.
@MainActor
final class OnboardingView: View {
    enum Mode { case signIn, switchServer, reauthenticate }

    let mode: Mode
    var onConnected: ((PlexConnection) -> Void)?
    var onCancel: (() -> Void)?

    private let navigation: NavigationView

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .signIn, .reauthenticate:
            navigation = NavigationView(root: WelcomeScreen())
        case .switchServer:
            navigation = NavigationView(root: ServersScreen(token: ServerBootstrap.accountToken ?? ""))
        }
        super.init()
        addSubview(navigation)
        configure(navigation.screens[0])
    }

    override var preferredFocusView: View? { navigation }

    private func configure(_ screen: ScreenView) {
        if let welcome = screen as? WelcomeScreen {
            welcome.onSignIn = { [weak self] in self?.showLink() }
        } else if let link = screen as? LinkScreen {
            link.onToken = { [weak self] token in self?.signedIn(token: token) }
        } else if let servers = screen as? ServersScreen {
            servers.onConnected = { [weak self] connection in self?.onConnected?(connection) }
        }
    }

    private func showLink() {
        let link = LinkScreen()
        configure(link)
        navigation.push(link)
    }

    private func signedIn(token: String) {
        PlexSignIn.complete(token: token)
        let servers = ServersScreen(token: token)
        configure(servers)
        navigation.push(servers)
    }

    /// Escape walks back through the steps; at the first one it cancels a server switch or sign-in again.
    func handleBack() -> Bool {
        if let top = navigation.top, top.handleBack() { return true }
        if navigation.screens.count > 1 {
            if navigation.top is ServersScreen, mode == .signIn { AccountSessionReset.signOut(LinuxSession.collaborators) }
            navigation.pop()
            return true
        }
        guard mode != .signIn else { return false }
        onCancel?()
        return true
    }

    override func layoutSubviews() {
        navigation.frame = bounds
    }
}

/// The first screen: the wordmark, a line about the app and Sign in with Plex.
@MainActor
final class WelcomeScreen: ScreenView {
    var onSignIn: (() -> Void)?
    private let signIn = ButtonView(style: .primary, title: String(localized: "Sign in with Plex"))

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        signIn.onPress = { [weak self] in self?.onSignIn?() }
        addSubview(signIn)
    }

    override var preferredFocusView: View? { signIn }

    override func layoutSubviews() {
        let size = signIn.sizeThatFits(Size(width: 600, height: 200))
        signIn.frame = Rect(x: ((frame.width - size.width) / 2).rounded(), y: (frame.height * 0.62).rounded(), width: size.width, height: size.height)
    }

    override func draw(_ context: inout DrawContext) {
        let theme = Theme.current
        guard let scale = window?.scale else { return }
        context.fill(bounds, color: theme.palette.canvas)
        context.glow(in: bounds, radius: 0, center: Point(x: bounds.midX, y: bounds.height * 0.4), glowRadius: bounds.width * 0.55,
                     color: Color(srgbRed: 0.18, green: 0.10, blue: 0.04).withAlpha(0.95))
        let wordmark = TextLayout("Crucible", font: Font(size: theme.type.largeTitle.size * 1.3, weight: .heavy), scale: scale)
        context.text(wordmark, at: Point(x: ((bounds.width - wordmark.size.width) / 2).rounded(), y: (bounds.height * 0.36 - wordmark.size.height / 2).rounded()),
                     color: theme.palette.label)
        let tagline = TextLayout(String(localized: "Your Plex library, beautifully on Linux."), font: theme.type.title3, maxWidth: bounds.width * 0.8,
                                 alignment: .center, scale: scale)
        context.text(tagline, at: Point(x: ((bounds.width - tagline.size.width) / 2).rounded(), y: (bounds.height * 0.36 + wordmark.size.height / 2 + theme.metrics.tv(24)).rounded()),
                     color: theme.palette.labelSecondary)
    }
}

/// plex.tv's link session: the browser opens on the sign-in page at once; the short code for plex.tv/link and a QR code
/// of the same sign-in stay on screen for a phone, and whichever is approved first signs in.
@MainActor
final class LinkScreen: ScreenView {
    var onToken: ((String) -> Void)?
    private var task: Task<Void, Never>?
    private var codes: PlexLinkCodes?
    private var status = String(localized: "Requesting a code…")
    private var failed = false
    private var openedBrowser = false
    private let openButton = ButtonView(style: .primary, title: String(localized: "Open plex.tv"), symbol: "arrow.up.right.circle")
    private let retryButton = ButtonView(style: .glass, title: String(localized: "Get a New Code"), symbol: "arrow.clockwise")
    private let qr = QRCodeView()

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        openButton.onPress = { [weak self] in
            guard let url = self?.codes?.authURL else { return }
            Browser.open(url)
        }
        retryButton.onPress = { [weak self] in self?.start() }
        retryButton.isHidden = true
        openButton.isEnabled = false
        [openButton, retryButton, qr].forEach(addSubview)
    }

    override var preferredFocusView: View? { retryButton.isHidden ? openButton : retryButton }

    override func screenDidAppear() {
        if task == nil { start() }
    }

    override func screenWillDisappear() {
        task?.cancel()
        task = nil
    }

    private func start() {
        task?.cancel()
        codes = nil
        failed = false
        openedBrowser = false
        retryButton.isHidden = true
        openButton.isEnabled = false
        qr.text = nil
        status = String(localized: "Requesting a code…")
        setNeedsDisplay()
        task = Task { [weak self] in
            for await state in PlexLinkSession().states() {
                guard !Task.isCancelled, let self else { return }
                self.apply(state)
            }
        }
    }

    private func apply(_ state: PlexLinkState) {
        switch state {
        case .requesting:
            status = String(localized: "Requesting a code…")
        case .waiting(let newCodes):
            codes = newCodes
            qr.text = newCodes.authURL.absoluteString
            openButton.isEnabled = true
            status = String(localized: "Waiting for approval…")
            if !openedBrowser {
                openedBrowser = true
                Browser.open(newCodes.authURL)
            }
            window?.focus.focus(openButton, animated: false)
        case .claimed(let token):
            status = String(localized: "Signed in. Finding your servers…")
            task = nil
            onToken?(token)
        case .expired:
            status = String(localized: "This code has expired.")
            showRetry(String(localized: "Get a New Code"))
        case .failed(let message):
            status = message
            showRetry(String(localized: "Try Again"))
        }
        setNeedsLayout()
        setNeedsDisplay()
    }

    private func showRetry(_ title: String) {
        failed = true
        retryButton.title = title
        retryButton.isHidden = false
        openButton.isEnabled = false
        window?.focus.focus(retryButton, animated: false)
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let qrSide = metrics.tv(360)
        qr.frame = Rect(x: frame.width * 0.62, y: frame.height * 0.3, width: qrSide, height: qrSide)
        let size = openButton.sizeThatFits(Size(width: 600, height: 200))
        openButton.frame = Rect(x: metrics.sideMargin * 2, y: frame.height * 0.62, width: size.width, height: size.height)
        let retrySize = retryButton.sizeThatFits(Size(width: 600, height: 200))
        retryButton.frame = Rect(x: openButton.frame.maxX + metrics.tv(32), y: openButton.frame.y, width: retrySize.width, height: retrySize.height)
    }

    override func draw(_ context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        let palette = theme.palette
        guard let scale = window?.scale else { return }
        context.fill(bounds, color: palette.canvas)
        let left = metrics.sideMargin * 2
        let column = frame.width * 0.62 - left - metrics.tv(80)
        var y = frame.height * 0.18
        let title = TextLayout(String(localized: "Link your Plex account"), font: theme.type.title1, maxWidth: column, maxLines: 2, scale: scale)
        context.text(title, at: Point(x: left, y: y), color: palette.label)
        y += title.size.height + metrics.tv(36)
        let explanation = TextLayout(String(localized: "Sign in to Plex in the browser that just opened and approve Crucible. On another device, go to plex.tv/link and enter this code."),
                                     font: theme.type.body, maxWidth: column, maxLines: 4, scale: scale)
        context.text(explanation, at: Point(x: left, y: y), color: palette.labelSecondary)
        y += explanation.size.height + metrics.tv(36)
        if let code = codes?.shortCode {
            drawCode(code, at: Point(x: left, y: y), context: &context)
        }
        let line = TextLayout(status, font: theme.type.callout, maxWidth: column, scale: scale)
        context.text(line, at: Point(x: left, y: openButton.frame.maxY + metrics.tv(32)), color: failed ? palette.destructive : palette.labelSecondary)
        if qr.text != nil {
            let caption = TextLayout(String(localized: "Or scan with your phone's camera"), font: theme.type.callout, maxWidth: qr.frame.width * 1.8,
                                     alignment: .center, scale: scale)
            context.text(caption, at: Point(x: qr.frame.midX - caption.size.width / 2, y: qr.frame.maxY + metrics.tv(24)), color: palette.labelSecondary)
        }
    }

    /// The code as a row of tiles, one letter each, as the Apple TV shows it.
    private func drawCode(_ code: String, at origin: Point, context: inout DrawContext) {
        let theme = Theme.current
        guard let scale = window?.scale else { return }
        let tile = theme.metrics.tv(96)
        let gap = theme.metrics.tv(16)
        for (index, character) in code.enumerated() {
            let rect = Rect(x: origin.x + Float(index) * (tile + gap), y: origin.y, width: tile, height: tile * 1.2)
            context.fill(rect, radius: theme.metrics.radiusM, color: theme.palette.surfaceRaised)
            let letter = TextLayout(String(character), font: Font(size: theme.type.title1.size, weight: .bold), scale: scale)
            context.text(letter, at: Point(x: rect.midX - letter.size.width / 2, y: rect.midY - letter.size.height / 2), color: theme.palette.label)
        }
    }
}

/// A QR code drawn with hard module edges on a white plate with its quiet zone.
@MainActor
final class QRCodeView: View {
    var text: String? { didSet { if text != oldValue { texture = nil; setNeedsDisplay() } } }
    private var texture: Texture?
    private var modules = 0

    private func makeTexture() {
        guard texture == nil, let text, let gpu = window?.gpu else { return }
        var width: Int32 = 0
        guard let raw = crucible_qr_encode(text, &width) else { return }
        defer { crucible_qr_free(raw) }
        let side = Int(width)
        let stride = (side + 3) & ~3
        var pixels = [UInt8](repeating: 0, count: stride * side)
        for y in 0..<side {
            for x in 0..<side where raw[y * side + x] != 0 { pixels[y * stride + x] = 255 }
        }
        guard let made = try? gpu.texture(width: side, height: side, format: .r8, renderable: false) else { return }
        _ = pixels.withUnsafeBytes { made.upload($0.baseAddress!, rowBytes: stride) }
        texture = made
        modules = side
    }

    override func draw(_ context: inout DrawContext) {
        makeTexture()
        guard let texture, modules > 0 else { return }
        context.fill(bounds, radius: Theme.current.metrics.radiusM, color: .white)
        let quiet = bounds.width * 4 / Float(modules + 8)
        context.mask(texture, in: bounds.insetBy(quiet, quiet), color: Color(hex: 0x111111), nearest: true)
    }
}

/// The account's servers, each probed for its fastest route; one that answers alone is connected to at once.
@MainActor
final class ServersScreen: ScreenView {
    var onConnected: ((PlexConnection) -> Void)?
    private let discovery: ServerDiscovery
    private let token: String
    private let rows = RowListView()
    private let state = StateView()
    private let title = ScreenTitleView(title: String(localized: "Choose Server"),
                                        detail: String(localized: "Crucible tests every connection and picks the fastest."))
    private var picker: ServerPickerState?
    private var tasks: [Task<Void, Never>] = []
    private var connecting = false
    private var autoContinue = true

    init(token: String) {
        self.token = token
        discovery = ServerDiscovery(token: token)
        super.init()
        [title, rows, state].forEach(addSubview)
        rows.onSelect = { [weak self] item in self?.select(item.id) }
        rows.columnWidth = Theme.current.metrics.formColumn
    }

    override var preferredFocusView: View? { state.isHidden ? rows : state }

    override func screenDidAppear() {
        if tasks.isEmpty { load() }
    }

    override func screenWillDisappear() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    private func busy(_ text: String) {
        title.isHidden = true
        rows.isHidden = true
        state.isHidden = false
        state.show(.loading(title: text))
    }

    private func load() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        busy(String(localized: "Finding your servers…"))
        tasks.append(Task { [weak self] in
            guard let self else { return }
            do {
                switch try await discovery.listing(progress: { [weak self] in self?.busy($0.message) }) {
                case .none:
                    failure(String(localized: "No Plex Server Found"),
                            String(localized: "This account doesn’t own or share a Plex Media Server. Sign in with the account that has your server, or add one by its address."))
                case .single(let server):
                    let outcome = await discovery.connect(toOnly: server) { [weak self] progress in self?.busy(progress.message) }
                    handle(outcome, server: server)
                case .several(let servers):
                    show(servers)
                }
            } catch {
                guard !Task.isCancelled else { return }
                failure(String(localized: "Couldn’t Load Your Servers"), ConnectionError.message(for: error))
            }
        })
    }

    private func failure(_ heading: String, _ message: String) {
        title.isHidden = true
        rows.isHidden = true
        state.isHidden = false
        state.show(.error(title: heading, message: message, retryTitle: String(localized: "Try Again"), retry: { [weak self] in self?.load() }))
    }

    private func handle(_ outcome: ServerConnectOutcome, server: ServerChoice) {
        connecting = false
        switch outcome {
        case .connected(let connection):
            onConnected?(connection)
        case .needsAddress(let message):
            failure(String(localized: "Couldn’t Reach \(server.name)"),
                    message ?? String(localized: "Crucible found no route to this server. Enter its address instead."))
        case .failed(let message):
            failure(String(localized: "Couldn’t Connect to \(server.name)"), message)
        case .cancelled:
            break
        }
    }

    private func show(_ servers: [ServerChoice]) {
        var picker = ServerPickerState(choices: servers)
        for (server, route) in picker.unprobeableRoutes { _ = picker.record(server: server, route: route, milliseconds: nil) }
        self.picker = picker
        title.isHidden = false
        rows.isHidden = false
        state.isHidden = true
        refreshRows()
        window?.focus.focus(rows, animated: false)
        let measurements = discovery.measureRoutes(picker.probeTargets)
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

    private func refreshRows() {
        guard let picker else { return }
        rows.setItems(picker.choices.map { choice in
            RowItem(id: choice.id, title: choice.name, subtitle: choice.statusLine, value: choice.routeValue,
                    symbol: "server.rack", accessory: .chevron, isEnabled: picker.isSelectable(choice.id))
        })
        setNeedsLayout()
    }

    /// Continues alone when exactly one server answered and every best route is known.
    private func continueIfDecided() {
        guard autoContinue, !connecting, let target = picker?.autoContinue else { return }
        autoContinue = false
        connect(target.choice, route: target.route)
    }

    private func select(_ id: String) {
        guard var picker, picker.choose(id), let choice = picker.selectedChoice, let route = choice.bestRoute else { return }
        self.picker = picker
        autoContinue = false
        connect(choice, route: route)
    }

    private func connect(_ choice: ServerChoice, route: ServerRoute) {
        guard !connecting else { return }
        connecting = true
        busy(String(localized: "Connecting to \(choice.name)…"))
        tasks.append(Task { [weak self] in
            guard let self else { return }
            let outcome = await discovery.connect(to: choice, route: route) { [weak self] progress in self?.busy(progress.message) }
            guard !Task.isCancelled else { return }
            handle(outcome, server: choice)
        })
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        state.frame = bounds
        let titleHeight = title.sizeThatFits(bounds.size).height
        title.frame = Rect(x: 0, y: metrics.tv(120), width: frame.width, height: titleHeight)
        let height = rows.sizeThatFits(Size(width: frame.width, height: 0)).height
        rows.frame = Rect(x: 0, y: title.frame.maxY + metrics.tv(40), width: frame.width, height: height)
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

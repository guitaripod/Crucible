@preconcurrency import UIKit
import WebKit
import os

final class ServerSetupViewController: UIViewController {
    private struct KnownServer {
        let name: String
        let machineId: String
        let advertised: [URL]
    }

    var onConnected: ((PlexConnection) -> Void)?
    var allowsCancel = false

    private let glow = EmberGlowView()
    private let glyph = CrystalGlyphView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let statusLabel = UILabel()
    private let footerLabel = UILabel()
    private let signInButton = ThemeButton.primary(title: "Sign in with Plex")
    private let addressButton = UIButton(configuration: .plain())
    private let scrollView = UIScrollView()
    private var chooser: ChooseServerViewController?
    private var authTask: Task<Void, Never>?
    private var signedInToken: String?
    private var pendingManualAddress: ServerAddress?
    private let log = Logger(subsystem: "com.guitaripod.crucible", category: "auth")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        navigationController?.setNavigationBarHidden(true, animated: false)
        installGlow()
        installWelcomeContent()
        if allowsCancel { installCancelButton() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startGlyphMotion()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        authTask?.cancel()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        glyph.stopBreathing()
    }

    private func startGlyphMotion() {
        guard !UIAccessibility.isReduceMotionEnabled, chooser == nil else { return }
        glyph.startBreathing()
    }

    private func installGlow() {
        glow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(glow)
        NSLayoutConstraint.activate([
            glow.topAnchor.constraint(equalTo: view.topAnchor),
            glow.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            glow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            glow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func installCancelButton() {
        let close = ThemeButton.icon(symbol: "xmark", label: "Cancel")
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(close)
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            close.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
        ])
    }

    private func installWelcomeContent() {
        glyph.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: 132),
            glyph.heightAnchor.constraint(equalToConstant: 132),
        ])

        titleLabel.text = "Crucible"
        titleLabel.font = Theme.Font.scaled(.largeTitle, 40, .heavy, maximum: 54)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.textAlignment = .center
        titleLabel.accessibilityTraits = .header

        subtitleLabel.text = "Your personal Plex client"
        subtitleLabel.font = Theme.Font.body
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = Theme.Color.labelSecondary
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        statusLabel.font = Theme.Font.footnoteSemibold
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true

        footerLabel.text = "Works with any Plex Media Server"
        footerLabel.font = Theme.Font.caption1Regular
        footerLabel.adjustsFontForContentSizeCategory = true
        footerLabel.textColor = Theme.Color.labelTertiary
        footerLabel.textAlignment = .center
        footerLabel.numberOfLines = 0

        signInButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        signInButton.addAction(UIAction { [weak self] _ in self?.startAuth() }, for: .touchUpInside)

        var addressConfig = UIButton.Configuration.plain()
        addressConfig.title = "Connect with a server address"
        addressConfig.baseForegroundColor = Theme.Color.accentText
        addressConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        addressConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.scaled(.callout, 16, .semibold, maximum: 22)
            return outgoing
        }
        addressButton.configuration = addressConfig
        addressButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        addressButton.addAction(UIAction { [weak self] _ in self?.presentAddressSheet(known: nil) }, for: .touchUpInside)

        let identity = UIStackView(arrangedSubviews: [glyph, titleLabel, subtitleLabel])
        identity.axis = .vertical
        identity.alignment = .center
        identity.spacing = 6
        identity.setCustomSpacing(26, after: glyph)

        let actions = UIStackView(arrangedSubviews: [statusLabel, signInButton, addressButton, footerLabel])
        actions.axis = .vertical
        actions.alignment = .fill
        actions.spacing = 10
        actions.setCustomSpacing(18, after: addressButton)

        scrollView.alwaysBounceVertical = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let content = UIView()
        content.translatesAutoresizingMaskIntoConstraints = false
        identity.translatesAutoresizingMaskIntoConstraints = false
        actions.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(content)
        content.addSubview(identity)
        content.addSubview(actions)

        let centered = identity.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -70)
        centered.priority = .defaultHigh
        let frame = scrollView.frameLayoutGuide
        let contentGuide = scrollView.contentLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            content.topAnchor.constraint(equalTo: contentGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: frame.widthAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: frame.heightAnchor),

            centered,
            identity.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 64),
            identity.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            identity.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            identity.bottomAnchor.constraint(lessThanOrEqualTo: actions.topAnchor, constant: -24),

            actions.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            actions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -56),
        ])
    }

    private func setBusy(_ busy: Bool) {
        var config = ThemeButton.primaryConfiguration(title: "Sign in with Plex")
        config.showsActivityIndicator = busy
        signInButton.configuration = config
        signInButton.isEnabled = !busy
        addressButton.isEnabled = !busy
    }

    private func startAuth() {
        statusLabel.isHidden = true
        setBusy(true)

        authTask?.cancel()
        authTask = Task { [weak self] in
            guard let self else { return }
            do {
                showStatus("Requesting PIN...", color: Theme.Color.labelSecondary)
                let pin: PlexPin = try await APIClient.plexTVRequest(.requestPin)
                guard !Task.isCancelled else { return }

                let clientId = PlexHeaders.clientIdentifier
                let authURLString = "https://app.plex.tv/auth#?clientID=\(clientId)&code=\(pin.code)&context%5Bdevice%5D%5Bproduct%5D=Crucible"
                guard let authURL = URL(string: authURLString) else {
                    showError("Failed to build auth URL")
                    setBusy(false)
                    return
                }

                let webVC = PlexWebAuthViewController(url: authURL)
                let nav = UINavigationController(rootViewController: webVC)
                present(nav, animated: true)

                showStatus("Waiting for authorization...", color: Theme.Color.labelSecondary)
                let token = try await pollForToken(pinId: pin.id)
                guard !Task.isCancelled else { return }

                nav.dismiss(animated: true)
                ServerBootstrap.saveToken(token)
                signedInToken = token
                Task { await PlexAccountName.refresh(token: token) }
                showStatus("Signed in! Discovering servers...", color: Theme.Color.statusOK)

                if let address = pendingManualAddress {
                    pendingManualAddress = nil
                    if let failure = await connectManually(address, token: token, known: nil) {
                        showError(failure)
                        setBusy(false)
                    }
                    return
                }
                try await discoverServers(token: token)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                log.error("Auth failed: \(error)")
                showError(error.localizedDescription)
                setBusy(false)
            }
        }
    }

    private func pollForToken(pinId: Int) async throws -> String {
        for i in 0..<150 {
            try await Task.sleep(for: .seconds(2))
            try Task.checkCancellation()
            do {
                let pin: PlexPin = try await APIClient.plexTVRequest(.checkPin(pinId: pinId))
                if let token = pin.authToken {
                    return token
                }
            } catch {
                log.error("Poll \(i) error: \(error)")
            }
        }
        throw APIError.httpError(statusCode: 408, message: "Authentication timed out. Please try again.")
    }

    private func discoverServers(token: String) async throws {
        let resources: [PlexResource] = try await APIClient.plexTVRequest(.resources, token: token)
        let servers = resources.filter { $0.provides.contains("server") }
        guard let first = servers.first else {
            showError("No Plex server found on your account")
            setBusy(false)
            return
        }

        guard servers.count > 1 else {
            await connectToOnlyServer(first, token: token)
            return
        }
        guard !Task.isCancelled else { return }
        showChooser(choices: servers.map(ServerChoice.init(resource:)), token: token)
    }

    /// Single-server accounts skip the picker: probe every route (progress shown on the Welcome
    /// screen), pin the best one, and fall back to the address sheet when nothing answers.
    private func connectToOnlyServer(_ server: PlexResource, token: String) async {
        let ranked = ServerChoice.ranked(server.connections)
        let advertised = ranked.compactMap { URL(string: $0.uri) }
        let known = KnownServer(name: server.name, machineId: server.clientIdentifier, advertised: advertised)

        guard !advertised.isEmpty else {
            setBusy(false)
            presentAddressSheet(known: known)
            return
        }

        showStatus("Finding the best route to \(server.name)…", color: Theme.Color.labelSecondary)
        let best = await ServerConnectionResolver.firstReachable(advertised, token: token)
        guard !Task.isCancelled else { return }
        guard let best else {
            showError("Could not reach \(server.name). Enter its address instead.")
            setBusy(false)
            presentAddressSheet(known: known)
            return
        }
        if let failure = await finishConnect(url: best, name: server.name, machineId: server.clientIdentifier, token: token, candidates: advertised) {
            showError(failure)
            setBusy(false)
        }
    }

    private func presentAddressSheet(known: KnownServer?) {
        let sheet = ServerAddressSheetViewController(prefill: UserDefaults.standard.string(forKey: "last_server_ip")) { [weak self] address in
            await self?.handleSubmitted(address, known: known)
        }
        sheet.onDidDismiss = { [weak self] in self?.beginPendingAuthIfNeeded() }
        present(sheet, animated: true)
    }

    /// Starts sign-in once the address sheet is gone, so the web auth sheet never competes with it.
    private func beginPendingAuthIfNeeded() {
        guard pendingManualAddress != nil, signedInToken == nil else { return }
        startAuth()
    }

    /// Signed-out users authenticate first and the address is connected right after sign-in.
    private func handleSubmitted(_ address: ServerAddress, known: KnownServer?) async -> String? {
        let remembered = address.port == ServerAddress.defaultPort ? address.host : "\(address.host):\(address.port)"
        UserDefaults.standard.set(remembered, forKey: "last_server_ip")
        guard let token = signedInToken else {
            pendingManualAddress = address
            return nil
        }
        let failure = await connectManually(address, token: token, known: known)
        if failure != nil { setBusy(false) }
        return failure
    }

    private func connectManually(_ address: ServerAddress, token: String, known: KnownServer?) async -> String? {
        showStatus("Connecting to \(address.host)…", color: Theme.Color.labelSecondary)
        guard let url = await ServerConnectionResolver.firstReachable(address.candidateURLs, token: token) else {
            return "Couldn't reach \(address.host). Check the address and that the server is online."
        }
        let machineId: String
        let name: String
        if let known {
            machineId = known.machineId
            name = known.name
        } else {
            let identified = await Self.machineIdentifier(at: url, token: token)
            machineId = identified ?? address.host
            let resolvedName = await Self.serverName(machineId: machineId, token: token)
            name = resolvedName ?? address.host
        }
        let advertised = (known?.advertised ?? []).filter { $0 != url }
        return await finishConnect(url: url, name: name, machineId: machineId, token: token, candidates: advertised)
    }

    private static func machineIdentifier(at url: URL, token: String) async -> String? {
        guard let request = try? PlexEndpoint.identity.urlRequest(baseURL: url, token: token),
              let (data, _) = try? await URLSession.shared.data(for: request),
              let identity = try? JSONDecoder().decode(PlexIdentity.self, from: data)
        else { return nil }
        return identity.MediaContainer.machineIdentifier
    }

    private static func serverName(machineId: String, token: String) async -> String? {
        let resources: [PlexResource]? = try? await APIClient.plexTVRequest(.resources, token: token)
        return resources?.first { $0.clientIdentifier == machineId }?.name
    }

    private func showChooser(choices: [ServerChoice], token: String) {
        let picker = ChooseServerViewController(choices: choices, token: token)
        picker.onBack = { [weak self] in self?.showWelcome() }
        picker.onAddByAddress = { [weak self] in self?.presentAddressSheet(known: nil) }
        picker.onConnect = { [weak self] choice, route in
            await self?.connectFromChooser(choice, route: route)
        }

        addChild(picker)
        picker.view.frame = view.bounds
        picker.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        picker.view.alpha = 0
        view.addSubview(picker.view)
        picker.didMove(toParent: self)
        chooser = picker
        glyph.stopBreathing()

        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.3) {
            picker.view.alpha = 1
        } completion: { [weak self] _ in
            self?.scrollView.isHidden = true
            UIAccessibility.post(notification: .screenChanged, argument: picker.view)
        }
    }

    private func showWelcome() {
        guard let picker = chooser else { return }
        chooser = nil
        scrollView.isHidden = false
        setBusy(false)
        statusLabel.isHidden = true
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25) {
            picker.view.alpha = 0
        } completion: { [weak self] _ in
            picker.willMove(toParent: nil)
            picker.view.removeFromSuperview()
            picker.removeFromParent()
            self?.startGlyphMotion()
            UIAccessibility.post(notification: .screenChanged, argument: self?.titleLabel)
        }
    }

    private func connectFromChooser(_ choice: ServerChoice, route: ServerRoute) async -> String? {
        guard let token = signedInToken, let url = URL(string: route.uri) else { return "Invalid server address" }
        let advertised = choice.routes.compactMap { URL(string: $0.uri) }.filter { $0 != url }
        return await finishConnect(url: url, name: choice.name, machineId: choice.id, token: token, candidates: advertised)
    }

    /// Re-checks the route, persists the server and hands the connection to the app. Returns a
    /// user-facing message on failure and nil once the connection has been delivered.
    private func finishConnect(url: URL, name: String, machineId: String, token: String, candidates: [URL]) async -> String? {
        showStatus("Connecting to \(url.absoluteString)...", color: Theme.Color.labelSecondary)
        guard await APIClient.probe(baseURL: url, token: token) else {
            return "Could not reach server at \(url.absoluteString)"
        }

        ServerBootstrap.saveServer(uri: url, name: name, machineIdentifier: machineId, candidates: candidates.filter { $0 != url })
        showStatus("Connected to \(name)", color: Theme.Color.statusOK)

        guard let plexConnection = ServerBootstrap.connection() else {
            return "Failed to save connection"
        }

        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return nil }
        onConnected?(plexConnection)
        return nil
    }

    private func showError(_ message: String) {
        statusLabel.textColor = Theme.Color.destructive
        statusLabel.text = message
        statusLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func showStatus(_ message: String, color: UIColor) {
        statusLabel.textColor = color
        statusLabel.text = message
        statusLabel.isHidden = false
    }
}

/// A soft ember radial glow behind the crystal; the alpha drops slightly in light appearance.
private final class EmberGlowView: UIView {
    private let gradient = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        gradient.type = .radial
        gradient.locations = [0, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: 0.30)
        gradient.endPoint = CGPoint(x: 1.12, y: 0.30 + 0.62)
        layer.addSublayer(gradient)
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: EmberGlowView, _: UITraitCollection) in
            view.applyColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    private func applyColors() {
        let alpha: CGFloat = traitCollection.userInterfaceStyle == .dark ? 0.26 : 0.20
        let ember = UIColor(red: 1, green: 140 / 255, blue: 20 / 255, alpha: alpha)
        gradient.colors = [ember.cgColor, ember.withAlphaComponent(0).cgColor]
    }
}

final class PlexWebAuthViewController: UIViewController {
    private let url: URL
    private var webView: WKWebView!

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sign in to Plex"

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            }
        )

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])

        webView.load(URLRequest(url: url))
    }
}

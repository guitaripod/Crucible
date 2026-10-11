import CrucibleCore
import CrucibleDesign
import os
@preconcurrency import UIKit
import WebKit

final class ServerSetupViewController: UIViewController {
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
                guard let token = try await authorize(), !Task.isCancelled else { return }
                PlexSignIn.complete(token: token)
                signedInToken = token
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

    private struct SignInFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Requests a PIN, shows plex.tv's approval page in a web sheet and waits for the token.
    /// Returns nil when the task was cancelled.
    private func authorize() async throws -> String? {
        var sheet: UINavigationController?
        for await state in PlexPinAuth(strong: true, timing: .phoneWeb).states() {
            guard !Task.isCancelled else { return nil }
            switch state {
            case .requesting:
                showStatus("Requesting PIN...", color: Theme.Color.labelSecondary)
            case .waiting(let pin):
                guard let authURL = PlexAuthURL.url(clientIdentifier: PlexHeaders.clientIdentifier, code: pin.code) else {
                    throw SignInFailure(message: "Failed to build auth URL")
                }
                let nav = UINavigationController(rootViewController: PlexWebAuthViewController(url: authURL))
                present(nav, animated: true)
                sheet = nav
                showStatus("Waiting for authorization...", color: Theme.Color.labelSecondary)
            case .claimed(let token):
                sheet?.dismiss(animated: true)
                return token
            case .expired:
                throw APIError.httpError(statusCode: 408, message: "Authentication timed out. Please try again.")
            case .failed(let message):
                throw SignInFailure(message: message)
            }
        }
        return nil
    }

    private func discoverServers(token: String) async throws {
        let discovery = ServerDiscovery(token: token)
        switch try await discovery.listing() {
        case .none:
            showError("No Plex server found on your account")
            setBusy(false)
        case .single(let server):
            await connectToOnlyServer(server, discovery: discovery)
        case .several(let servers):
            guard !Task.isCancelled else { return }
            showChooser(choices: servers, token: token)
        }
    }

    /// Single-server accounts skip the picker: probe every route (progress shown on the Welcome
    /// screen), pin the best one, and fall back to the address sheet when nothing answers.
    private func connectToOnlyServer(_ server: ServerChoice, discovery: ServerDiscovery) async {
        let outcome = await discovery.connect(toOnly: server, progress: { [weak self] in self?.show($0) })
        if case .needsAddress(let message) = outcome {
            if let message { showError(message) }
            setBusy(false)
            presentAddressSheet(known: server)
            return
        }
        if let failure = await deliver(outcome) {
            showError(failure)
            setBusy(false)
        }
    }

    private func presentAddressSheet(known: ServerChoice?) {
        let sheet = ServerAddressSheetViewController(prefill: RememberedServerAddress.text) { [weak self] address in
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
    private func handleSubmitted(_ address: ServerAddress, known: ServerChoice?) async -> String? {
        RememberedServerAddress.remember(address)
        guard let token = signedInToken else {
            pendingManualAddress = address
            return nil
        }
        let failure = await connectManually(address, token: token, known: known)
        if failure != nil { setBusy(false) }
        return failure
    }

    private func connectManually(_ address: ServerAddress, token: String, known: ServerChoice?) async -> String? {
        let outcome = await ServerDiscovery(token: token).connect(toAddress: address, known: known, progress: { [weak self] in self?.show($0) })
        return await deliver(outcome)
    }

    private func show(_ progress: ConnectProgress) {
        showStatus(progress.message, color: progress.isSuccess ? Theme.Color.statusOK : Theme.Color.labelSecondary)
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
        guard let token = signedInToken else { return "Invalid server address" }
        let outcome = await ServerDiscovery(token: token).connect(to: choice, route: route, progress: { [weak self] in self?.show($0) })
        return await deliver(outcome)
    }

    /// Hands a saved connection to the app once "Connected" has had a moment on screen. Returns a
    /// user-facing message on failure and nil once the connection has been delivered.
    private func deliver(_ outcome: ServerConnectOutcome) async -> String? {
        switch outcome {
        case .connected(let connection):
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return nil }
            onConnected?(connection)
            return nil
        case .failed(let message):
            return message
        case .needsAddress(let message):
            return message
        case .cancelled:
            return nil
        }
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

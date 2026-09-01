import UIKit
import WebKit
import os

final class ServerSetupViewController: UIViewController {
    private let signInButton = UIButton(configuration: .filled())
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    var onConnected: ((PlexConnection) -> Void)?
    var allowsCancel = false
    private var authTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.guitaripod.crucible", category: "auth")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        if allowsCancel {
            navigationController?.setNavigationBarHidden(false, animated: false)
            title = "Switch Server"
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                systemItem: .cancel,
                primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
            )
        } else {
            navigationController?.setNavigationBarHidden(true, animated: false)
        }

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 48, weight: .medium)
        let iconImage = UIImageView(image: UIImage(systemName: "play.rectangle.fill", withConfiguration: iconConfig))
        iconImage.tintColor = .systemOrange
        iconImage.contentMode = .scaleAspectFit
        iconImage.translatesAutoresizingMaskIntoConstraints = false
        iconImage.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let titleLabel = UILabel()
        titleLabel.text = "Crucible"
        titleLabel.font = .systemFont(ofSize: 34, weight: .bold)
        titleLabel.textAlignment = .center

        let subtitleLabel = UILabel()
        subtitleLabel.text = "Your personal Plex client"
        subtitleLabel.font = .systemFont(ofSize: 16, weight: .regular)
        subtitleLabel.textColor = .tertiaryLabel
        subtitleLabel.textAlignment = .center

        var config = Glass.prominentButton {
            var fallback = UIButton.Configuration.filled()
            fallback.baseBackgroundColor = .systemOrange
            fallback.baseForegroundColor = .white
            return fallback
        }
        config.title = "Sign in with Plex"
        config.image = UIImage(systemName: "play.fill")
        config.imagePadding = 10
        config.cornerStyle = .large
        config.buttonSize = .large
        signInButton.tintColor = .systemOrange
        signInButton.configuration = config
        signInButton.addAction(UIAction { [unowned self] _ in startAuth() }, for: .touchUpInside)

        statusLabel.textColor = .systemRed
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true

        spinner.hidesWhenStopped = true

        let stack = UIStackView(arrangedSubviews: [iconImage, titleLabel, subtitleLabel, signInButton, statusLabel, spinner])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill
        stack.setCustomSpacing(6, after: titleLabel)
        stack.setCustomSpacing(40, after: subtitleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -30),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -24),
        ])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        authTask?.cancel()
    }

    private func startAuth() {
        statusLabel.isHidden = true
        spinner.startAnimating()
        signInButton.isEnabled = false

        authTask?.cancel()
        authTask = Task { [weak self] in
            guard let self else { return }
            do {
                showStatus("Requesting PIN...", color: .secondaryLabel)
                let pin: PlexPin = try await APIClient.plexTVRequest(.requestPin)
                guard !Task.isCancelled else { return }

                let clientId = PlexHeaders.clientIdentifier
                let authURLString = "https://app.plex.tv/auth#?clientID=\(clientId)&code=\(pin.code)&context%5Bdevice%5D%5Bproduct%5D=Crucible"
                guard let authURL = URL(string: authURLString) else {
                    showError("Failed to build auth URL")
                    return
                }

                let webVC = PlexWebAuthViewController(url: authURL)
                let nav = UINavigationController(rootViewController: webVC)
                present(nav, animated: true)

                showStatus("Waiting for authorization...", color: .secondaryLabel)
                let token = try await pollForToken(pinId: pin.id)
                guard !Task.isCancelled else { return }

                nav.dismiss(animated: true)
                ServerBootstrap.saveToken(token)
                showStatus("Signed in! Discovering servers...", color: .systemGreen)

                try await discoverServers(token: token)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                log.error("Auth failed: \(error)")
                showError(error.localizedDescription)
                spinner.stopAnimating()
                signInButton.isEnabled = true
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
        guard let server = resources.first(where: { $0.provides.contains("server") }) else {
            showError("No Plex server found on your account")
            spinner.stopAnimating()
            signInButton.isEnabled = true
            return
        }

        let serverName = server.name
        let machineId = server.clientIdentifier
        let ranked = rankConnections(server.connections)

        guard !ranked.isEmpty else {
            promptServerURL(serverName: serverName, machineId: machineId, token: token, advertised: [])
            return
        }

        showStatus("Finding the best route to \(serverName)…", color: .secondaryLabel)

        let reachability = await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, connection) in ranked.enumerated() {
                guard let url = URL(string: connection.uri) else { continue }
                group.addTask {
                    let client = APIClient(baseURL: url, token: token)
                    return (index, await client.identityCheck())
                }
            }
            var results = [Int: Bool]()
            for await (index, ok) in group {
                results[index] = ok
            }
            return results
        }

        guard !Task.isCancelled else { return }
        let advertised = ranked.compactMap { URL(string: $0.uri) }
        if let best = reachability.filter(\.value).keys.min() {
            connectTo(uri: ranked[best].uri, serverName: serverName, machineId: machineId, token: token, candidates: advertised)
        } else {
            promptServerURL(serverName: serverName, machineId: machineId, token: token, advertised: advertised)
        }
    }

    /// Orders connections best-first: local before remote, direct before relay, HTTPS before HTTP.
    /// Docker-bridge addresses (RFC 1918 ranges a phone can never route) are demoted below the
    /// server's LAN address so a same-network client pins a route it can actually reach.
    private func rankConnections(_ connections: [PlexResourceConnection]) -> [PlexResourceConnection] {
        func score(_ connection: PlexResourceConnection) -> Int {
            var score = 0
            if connection.relay == true { score += 100 }
            if connection.local != true { score += 10 }
            if connection.protocol != "https" { score += 1 }
            if let address = connection.address, Self.unroutablePrefixes.contains(where: { address.hasPrefix($0) }) {
                score += 5
            }
            return score
        }
        return connections.sorted { score($0) < score($1) }
    }

    private static let unroutablePrefixes = ["172.17.", "172.18.", "172.19.", "172.20.", "172.21.", "172.22.", "172.23.", "172.24.", "172.25.", "172.26.", "172.27.", "172.28.", "172.29.", "172.30.", "172.31."]

    private func promptServerURL(serverName: String, machineId: String, token: String, advertised: [URL]) {
        let alert = UIAlertController(title: "Server Address", message: "Enter your Plex server's Tailscale IP", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "100.x.x.x"
            field.keyboardType = .decimalPad
            field.text = UserDefaults.standard.string(forKey: "last_server_ip")
        }
        alert.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self] _ in
            guard let self, let ip = alert.textFields?.first?.text, !ip.isEmpty else { return }
            UserDefaults.standard.set(ip, forKey: "last_server_ip")
            let uri = "http://\(ip):32400"
            connectTo(uri: uri, serverName: serverName, machineId: machineId, token: token, candidates: advertised)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.spinner.stopAnimating()
            self?.signInButton.isEnabled = true
        })
        present(alert, animated: true)
    }

    private func connectTo(uri: String, serverName: String, machineId: String, token: String, candidates: [URL]) {
        guard let url = URL(string: uri) else {
            showError("Invalid URL")
            spinner.stopAnimating()
            signInButton.isEnabled = true
            return
        }

        showStatus("Connecting to \(uri)...", color: .secondaryLabel)
        Task { [weak self] in
            guard let self else { return }
            let testClient = APIClient(baseURL: url, token: token)
            let reachable = await testClient.identityCheck()
            guard reachable else {
                showError("Could not reach server at \(uri)")
                spinner.stopAnimating()
                signInButton.isEnabled = true
                return
            }

            let otherCandidates = candidates.filter { $0 != url }
            ServerBootstrap.saveServer(uri: url, name: serverName, machineIdentifier: machineId, candidates: otherCandidates)
            showStatus("Connected to \(serverName)", color: .systemGreen)

            guard let plexConnection = ServerBootstrap.connection() else {
                showError("Failed to save connection")
                spinner.stopAnimating()
                signInButton.isEnabled = true
                return
            }

            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            spinner.stopAnimating()
            onConnected?(plexConnection)
        }
    }


    private func showError(_ message: String) {
        statusLabel.textColor = .systemRed
        statusLabel.text = message
        statusLabel.isHidden = false
    }

    private func showStatus(_ message: String, color: UIColor) {
        statusLabel.textColor = color
        statusLabel.text = message
        statusLabel.isHidden = false
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

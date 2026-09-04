import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var pendingActivity: NSUserActivity?
    private var launchTask: Task<Void, Never>?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.tintColor = .systemOrange
        window.backgroundColor = CrystalGlyphView.canvas
        self.window = window
        window.makeKeyAndVisible()

        if let activity = connectionOptions.userActivities.first {
            pendingActivity = activity
        }
        reconfigureRoot()
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        route(userActivity)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        DownloadManager.shared.handleEnteredForeground()
    }

    private func route(_ activity: NSUserActivity) {
        guard let target = MediaActivity.route(activity) else { return }
        guard let tabBar = window?.rootViewController as? TabBarController else {
            pendingActivity = activity
            return
        }
        tabBar.openMedia(ratingKey: target.ratingKey, mediaType: target.mediaType)
    }

    func reconfigureRoot() {
        launchTask?.cancel()
        if let connection = ServerBootstrap.connection() {
            launch(connection: connection)
        } else {
            showServerSetup()
        }
    }

    /// The main UI is never on screen with a broken connection: the launch screen holds until the
    /// route is validated (healing it if needed) and both Home and Library payloads are in hand.
    private func launch(connection: PlexConnection) {
        let gate = (window?.rootViewController as? LaunchViewController) ?? installLaunchScreen()
        gate.showLoading(status: "Connecting to \(connection.serverName)…")
        launchTask = Task { @MainActor [weak self, weak gate] in
            let outcome = await AppLaunchSession.run(connection: connection) { message in
                Task { @MainActor in gate?.showLoading(status: message) }
            }
            guard !Task.isCancelled, let self, let gate else { return }
            switch outcome {
            case .success(let payload):
                let tabBar = self.buildMainApp(payload)
                gate.playSuccess { [weak self] in
                    self?.present(root: tabBar)
                }
            case .failure(let failure):
                let hasOffline = DownloadManager.shared.items.contains { $0.state == .completed }
                gate.showFailure(
                    title: "Couldn't Reach \(connection.serverName)",
                    message: failure.message,
                    canOpenDownloads: hasOffline
                )
                gate.onOpenDownloads = { [weak self] in self?.showOfflineDownloads(connection: connection) }
            }
        }
    }

    private func installLaunchScreen() -> LaunchViewController {
        let gate = LaunchViewController()
        gate.onRetry = { [weak self] in self?.reconfigureRoot() }
        gate.onSwitchServer = { [weak self] in self?.presentServerSwitcher() }
        window?.rootViewController = gate
        return gate
    }

    private func buildMainApp(_ payload: LaunchPayload) -> TabBarController {
        let api = payload.api
        let connection = payload.connection
        APIClient.onBaseURLChanged.withLock { handler in
            handler = { [weak api] newURL in
                guard let api else { return }
                Task { @MainActor in
                    ImageLoader.shared.configure(baseURL: newURL, token: api.token, machineIdentifier: connection.machineIdentifier)
                    DownloadManager.shared.configure(baseURL: newURL, token: api.token)
                }
            }
        }
        ImageLoader.shared.configure(baseURL: connection.serverURI, token: connection.authToken, machineIdentifier: connection.machineIdentifier)
        DownloadManager.shared.configure(baseURL: connection.serverURI, token: connection.authToken)
        StatsManager.shared.configure(api: api)
        StatsManager.shared.kickBackgroundSync()
        return TabBarController(payload: payload)
    }

    private func present(root: UIViewController) {
        guard let window else { return }
        window.backgroundColor = .systemBackground
        UIView.transition(with: window, duration: 0.4, options: [.transitionCrossDissolve, .curveEaseOut]) {
            window.rootViewController = root
        } completion: { [weak self] _ in
            guard let self, let pending = self.pendingActivity else { return }
            self.pendingActivity = nil
            self.route(pending)
        }
    }

    private func showServerSetup() {
        let setup = ServerSetupViewController()
        setup.onConnected = { [weak self] connection in
            self?.launch(connection: connection)
        }
        let nav = UINavigationController(rootViewController: setup)
        window?.backgroundColor = .systemBackground
        window?.rootViewController = nav
    }

    private func presentServerSwitcher() {
        guard let gate = window?.rootViewController else { return }
        let setup = ServerSetupViewController()
        setup.allowsCancel = true
        setup.onConnected = { [weak self] _ in
            gate.dismiss(animated: true) { self?.reconfigureRoot() }
        }
        let nav = UINavigationController(rootViewController: setup)
        nav.modalPresentationStyle = .fullScreen
        gate.present(nav, animated: true)
    }

    private func showOfflineDownloads(connection: PlexConnection) {
        guard let gate = window?.rootViewController else { return }
        let api = APIClient(baseURL: connection.serverURI, token: connection.authToken)
        ImageLoader.shared.configure(baseURL: connection.serverURI, token: connection.authToken, machineIdentifier: connection.machineIdentifier)
        DownloadManager.shared.configure(baseURL: connection.serverURI, token: connection.authToken)
        let downloads = DownloadsViewController(api: api)
        downloads.closeItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak gate] _ in gate?.dismiss(animated: true) }
        )
        let nav = UINavigationController(rootViewController: downloads)
        nav.modalPresentationStyle = .fullScreen
        gate.present(nav, animated: true)
    }
}

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var pendingActivity: NSUserActivity?
    private var mainTabBar: TabBarController?
    private var revealTimer: Timer?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.tintColor = .systemOrange
        window.backgroundColor = .systemBackground
        self.window = window
        window.makeKeyAndVisible()

        if let connection = ServerBootstrap.connection() {
            establishMainApp(connection: connection)
        } else {
            showServerSetup()
        }

        if let activity = connectionOptions.userActivities.first {
            route(activity)
        }
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
        if let connection = ServerBootstrap.connection() {
            establishMainApp(connection: connection)
        } else {
            showServerSetup()
        }
    }
    /// Validates the saved route before wiring the app together: a stale plex.direct cert or a
    /// moved network previously surfaced as a permanent TLS error screen on every launch. Now a
    /// failed probe triggers re-discovery of the server's advertised connections, and the app
    /// either follows a working route or falls back to setup.
    private func establishMainApp(connection: PlexConnection) {
        let skeleton = UIViewController()
        skeleton.view.backgroundColor = .systemBackground
        window?.rootViewController = skeleton
        Task { @MainActor in
            let validated = await ServerConnectionResolver.validate(
                connection: connection,
                progress: { [weak self] message in
                    Task { @MainActor in self?.updateSkeleton(skeleton, message: message) }
                }
            )
            guard !Task.isCancelled else { return }
            switch validated {
            case .connection(let connection):
                showMainApp(connection: connection)
            case .needsSetup:
                showServerSetup()
            }
        }
    }

    private func updateSkeleton(_ vc: UIViewController, message: String) {
        guard vc.view.subviews.isEmpty else { return }
        let label = UILabel()
        label.text = message
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: vc.view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: vc.view.layoutMarginsGuide.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: vc.view.layoutMarginsGuide.trailingAnchor, constant: -24),
        ])
    }

    private func showMainApp(connection: PlexConnection) {
        let api = APIClient(baseURL: connection.serverURI, token: connection.authToken)
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
        let tabBar = TabBarController(api: api)
        if let homeNav = tabBar.viewControllers?.first as? UINavigationController,
           let homeVC = homeNav.viewControllers.first as? HomeViewController {
            homeVC.onReady = { [weak self] in
                self?.revealMainWindow()
            }
        }
        installOffscreen(tabBar)
        revealTimer?.invalidate()
        revealTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
            self?.revealMainWindow()
        }
    }

    private func installOffscreen(_ tabBar: TabBarController) {
        mainTabBar?.view.removeFromSuperview()
        guard let window else { return }
        tabBar.view.frame = window.bounds
        tabBar.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(tabBar.view)
        self.mainTabBar = tabBar
        if let pending = pendingActivity {
            pendingActivity = nil
            route(pending)
        }
    }

    private func revealMainWindow() {
        revealTimer?.invalidate()
        revealTimer = nil
        guard let tabBar = mainTabBar, tabBar.view.alpha < 1 else { return }
        window?.rootViewController = tabBar
        tabBar.view.alpha = 0
        UIView.transition(
            with: tabBar.view,
            duration: 0.35,
            options: [.curveEaseOut]
        ) {
            tabBar.view.alpha = 1
        }
    }

    private func showServerSetup() {
        let setup = ServerSetupViewController()
        setup.onConnected = { [weak self] connection in
            self?.showMainApp(connection: connection)
        }
        let nav = UINavigationController(rootViewController: setup)
        window?.rootViewController = nav
    }
}

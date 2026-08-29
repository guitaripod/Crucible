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
            showMainApp(connection: connection)
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
            showMainApp(connection: connection)
        } else {
            showServerSetup()
        }
    }

    private func showMainApp(connection: PlexConnection) {
        let api = APIClient(baseURL: connection.serverURI, token: connection.authToken)
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

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var pendingActivity: NSUserActivity?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.tintColor = .systemOrange
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

    func sceneDidEnterBackground(_ scene: UIScene) {
        DownloadManager.shared.handleEnteredBackground()
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
        ImageLoader.shared.configure(baseURL: connection.serverURI, token: connection.authToken)
        DownloadManager.shared.configure(baseURL: connection.serverURI, token: connection.authToken)
        let tabBar = TabBarController(api: api)
        window?.rootViewController = tabBar
        if let pending = pendingActivity {
            pendingActivity = nil
            route(pending)
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

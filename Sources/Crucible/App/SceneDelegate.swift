import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        self.window = window
        window.makeKeyAndVisible()

        if let connection = ServerBootstrap.connection() {
            showMainApp(connection: connection)
        } else {
            showServerSetup()
        }
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
        Task {
            await ImageLoader.shared.configure(baseURL: connection.serverURI, token: connection.authToken)
        }
        let tabBar = TabBarController(api: api)
        window?.rootViewController = tabBar
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

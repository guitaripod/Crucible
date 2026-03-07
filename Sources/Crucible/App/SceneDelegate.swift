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

        if let url = ServerBootstrap.savedServerURL() {
            showMainApp(url: url)
        } else {
            showServerSetup()
        }
    }

    func reconfigureRoot() {
        if let url = ServerBootstrap.savedServerURL() {
            showMainApp(url: url)
        } else {
            showServerSetup()
        }
    }

    private func showMainApp(url: URL) {
        let api = APIClient(baseURL: url)
        let tabBar = TabBarController(api: api)
        window?.rootViewController = tabBar
    }

    private func showServerSetup() {
        let setup = ServerSetupViewController()
        setup.onConnected = { [weak self] url in
            self?.showMainApp(url: url)
        }
        let nav = UINavigationController(rootViewController: setup)
        window?.rootViewController = nav
    }
}

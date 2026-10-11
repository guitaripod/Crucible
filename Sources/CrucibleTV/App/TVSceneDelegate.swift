import CrucibleDesign
import UIKit

final class TVSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var coordinator: TVAppCoordinator?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.tintColor = Theme.Color.accent
        window.backgroundColor = CrystalGlyphView.canvas
        #if DEBUG
        TVDebugSession.applyAppearance(to: window)
        #endif
        self.window = window
        window.makeKeyAndVisible()

        let coordinator = TVAppCoordinator(window: window)
        self.coordinator = coordinator
        coordinator.start(openingURLs: connectionOptions.urlContexts.map(\.url))
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        coordinator?.open(urls: URLContexts.map(\.url))
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        coordinator?.stop()
        coordinator = nil
    }
}

import CrucibleCore
import CrucibleDesign
import CrucibleStats
import UIKit

/// Owns the root of the window and the session behind it: saved connection, launch gate, main app,
/// onboarding. The tvOS twin of the iPhone scene delegate's routing, minus downloads,
/// notifications and Handoff.
@MainActor
final class TVAppCoordinator: TVSessionActions {
    private static let crossDissolveDuration: TimeInterval = 0.4

    private let window: UIWindow
    private let router = TVRouter()
    private var launchTask: Task<Void, Never>?

    init(window: UIWindow) {
        self.window = window
    }

    /// Queues any link the app was opened with, then routes to the right root.
    func start(openingURLs urls: [URL]) {
        #if DEBUG
        if let root = TVDebugRoot.rootIfRequested() {
            window.rootViewController = root
            return
        }
        #endif
        open(urls: urls)
        reconnect()
    }

    func open(urls: [URL]) {
        for url in urls {
            router.handle(url)
        }
    }

    func stop() {
        launchTask?.cancel()
        launchTask = nil
        router.deactivate()
        TVTopShelfRefresher.deactivate(clearing: false)
    }

    func sceneWillEnterForeground() {
        TVTopShelfRefresher.refresh()
    }

    func reconnect() {
        launchTask?.cancel()
        if let connection = ServerBootstrap.connection() {
            launch(connection: connection)
        } else {
            showOnboarding()
        }
    }

    func switchServer() {
        guard let presenter = topViewController else { return }
        let onboarding = TVScreens.onboarding(mode: .switchServer) { [weak presenter, weak self] _ in
            guard let presenter else { return }
            presenter.dismiss(animated: true) { self?.reconnect() }
        }
        let navigation = Self.navigationController(root: onboarding)
        navigation.modalPresentationStyle = .fullScreen
        presenter.present(navigation, animated: true)
    }

    func signOut() {
        AppLogger.notice("Signing out", .lifecycle)
        launchTask?.cancel()
        router.deactivate()
        TVTopShelfRefresher.deactivate(clearing: true)
        StatsManager.shared.handleSignOut()
        HomeSnapshotStore.destroy()
        Task { await ImageLoader.shared.clearCache() }
        APIClient.onBaseURLChanged.withLock { $0 = nil }
        ServerBootstrap.clear()
        showOnboarding()
    }

    /// The main UI is never on screen with a broken connection: the launch gate holds until the
    /// route is validated (healing it if needed) and both Home and Library payloads are in hand.
    private func launch(connection: PlexConnection) {
        if window.rootViewController is TVRootTabBarController {
            router.deactivate()
        }
        let gate = (window.rootViewController as? TVLaunchViewController) ?? installLaunchGate()
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
                gate.showFailure(title: "Couldn't Reach \(connection.serverName)", message: failure.message)
            }
        }
    }

    private func installLaunchGate() -> TVLaunchViewController {
        let gate = TVLaunchViewController()
        gate.onRetry = { [weak self] in self?.reconnect() }
        gate.onSwitchServer = { [weak self] in self?.switchServer() }
        window.backgroundColor = CrystalGlyphView.canvas
        window.rootViewController = gate
        return gate
    }

    private func buildMainApp(_ payload: LaunchPayload) -> TVRootTabBarController {
        let api = payload.api
        let connection = payload.connection
        APIClient.onBaseURLChanged.withLock { handler in
            handler = { [weak api] newURL in
                guard let api else { return }
                ImageLoader.shared.configure(baseURL: newURL, token: api.token, machineIdentifier: connection.machineIdentifier)
            }
        }
        ImageLoader.shared.configure(baseURL: connection.serverURI, token: connection.authToken, machineIdentifier: connection.machineIdentifier)
        StatsManager.shared.configure(api: api)
        StatsManager.shared.kickBackgroundSync()
        TVTopShelfRefresher.activate(api: api, machineIdentifier: connection.machineIdentifier)
        let environment = TVAppEnvironment(payload: payload, router: router, session: self)
        return TVRootTabBarController(environment: environment)
    }

    private func present(root: TVRootTabBarController) {
        window.backgroundColor = Theme.Color.canvas
        guard !UIAccessibility.isReduceMotionEnabled else {
            window.rootViewController = root
            router.activate(root)
            return
        }
        UIView.transition(with: window, duration: Self.crossDissolveDuration, options: [.transitionCrossDissolve, .curveEaseOut]) {
            self.window.rootViewController = root
        } completion: { [weak self] _ in
            self?.router.activate(root)
        }
    }

    private func showOnboarding() {
        let onboarding = TVScreens.onboarding(mode: .signIn) { [weak self] connection in
            self?.launch(connection: connection)
        }
        window.backgroundColor = Theme.Color.canvas
        window.rootViewController = Self.navigationController(root: onboarding)
    }

    private var topViewController: UIViewController? {
        var top = window.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    private static func navigationController(root: UIViewController) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: root)
        navigation.setNavigationBarHidden(true, animated: false)
        return navigation
    }
}

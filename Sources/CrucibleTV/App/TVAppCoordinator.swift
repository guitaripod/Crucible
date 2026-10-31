import CrucibleCore
import CrucibleDesign
import CrucibleStats
import MidgarCore
import UIKit

/// Owns the root of the window and the session behind it: saved connection, launch gate, main app,
/// onboarding. The tvOS twin of the iPhone scene delegate's routing, minus downloads,
/// notifications and Handoff.
@MainActor
final class TVAppCoordinator: TVSessionActions {
    private static let crossDissolveDuration: TimeInterval = 0.4

    let window: UIWindow
    let router = TVRouter()
    private var launchTask: Task<Void, Never>?
    var finaleTask: Task<Void, Never>?
    var proMomentObserver: UUID?

    init(window: UIWindow) {
        self.window = window
    }

    /// Queues any link the app was opened with, then routes to the right root.
    func start(openingURLs urls: [URL]) {
        installPro()
        installProMoments()
        installDemo()
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
        removePro()
        removeProMoments()
        removeDemo()
        router.deactivate()
        TVTopShelfRefresher.deactivate()
    }

    func sceneWillEnterForeground() {
        ProAccess.shared.refresh()
        TVTopShelfRefresher.refresh()
        Task { await presentTrialNoticeIfDue() }
    }

    /// A demo that was running when the app last quit is brought back before anything decides what to show; every other launch goes
    /// straight to the saved session.
    func reconnect() {
        launchTask?.cancel()
        guard DemoMode.shared.isActive else {
            routeToSavedSession()
            return
        }
        resumeDemo()
    }

    private func routeToSavedSession() {
        if let connection = ServerBootstrap.connection() {
            launch(connection: connection)
        } else {
            showOnboarding()
        }
    }

    /// Starts the demo library again behind the launch gate. When it cannot start, the session it left behind points at a library
    /// that is gone, so it is forgotten and the app returns to its welcome screen.
    private func resumeDemo() {
        if window.rootViewController is TVRootTabBarController {
            router.deactivate()
        }
        TVTopShelfRefresher.deactivate()
        let gate = (window.rootViewController as? TVLaunchViewController) ?? installLaunchGate()
        gate.showLoading(status: "Starting the demo…")
        launchTask = Task { @MainActor [weak self] in
            let resumed = await DemoMode.shared.resume()
            guard !Task.isCancelled, let self else { return }
            guard resumed else {
                forgetDemoThatCouldNotResume()
                return
            }
            routeToSavedSession()
        }
    }

    private func forgetDemoThatCouldNotResume() {
        DemoTour.shared.reset()
        TVDemoState.clearIntro()
        AccountSessionReset.signOut(.tv)
        showOnboarding()
    }

    func leaveDemo() {
        guard DemoMode.shared.isActive else { return }
        MidgarLog.notice("Leaving the demo", category: .lifecycle)
        finaleTask?.cancel()
        launchTask?.cancel()
        router.deactivate()
        TVTopShelfRefresher.deactivate()
        APIClient.onBaseURLChanged.withLock { $0 = nil }
        Task { @MainActor [weak self] in
            await TVPlayerCoordinator.endActive()
            await DemoMode.shared.exit(.tv)
            TVDemoState.clearIntro()
            self?.window.rootViewController?.dismiss(animated: false)
            self?.showOnboarding()
        }
    }

    func switchServer() {
        guard let presenter = topViewController else { return }
        presentOnboarding(.switchServer, over: presenter)
    }

    /// Signing in again keeps the saved server and replaces only the account token.
    private func signInAgain() {
        guard let presenter = topViewController else { return }
        presentOnboarding(.reauthenticate, over: presenter)
    }

    private func presentOnboarding(_ mode: TVOnboardingMode, over presenter: UIViewController) {
        let onboarding = TVScreens.onboarding(mode: mode) { [weak presenter, weak self] _ in
            guard let presenter else { return }
            presenter.dismiss(animated: true) { self?.reconnect() }
        }
        let navigation = TVNavigation.makeNavigationController(root: onboarding)
        navigation.modalPresentationStyle = .fullScreen
        presenter.present(navigation, animated: true)
    }

    func signOut() {
        MidgarLog.notice("Signing out", category: .lifecycle)
        launchTask?.cancel()
        router.deactivate()
        TVTopShelfRefresher.deactivate()
        APIClient.onBaseURLChanged.withLock { $0 = nil }
        AccountSessionReset.signOut(.tv)
        showOnboarding()
    }

    private func confirmSignOut() {
        guard let presenter = topViewController else { return }
        let alert = UIAlertController(
            title: "Sign Out?",
            message: "This removes your Plex account from this Apple TV.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Sign Out", style: .destructive) { [weak self] _ in self?.signOut() })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presenter.present(alert, animated: true)
    }

    /// The main UI is never on screen with a broken connection: the launch gate holds until the
    /// route is validated (healing it if needed) and both Home and Library payloads are in hand.
    private func launch(connection: PlexConnection) {
        if window.rootViewController is TVRootTabBarController {
            router.deactivate()
        }
        TVTopShelfRefresher.deactivate()
        AccountSessionReset.reconcileServer(machineIdentifier: connection.machineIdentifier, .tv)
        let gate = (window.rootViewController as? TVLaunchViewController) ?? installLaunchGate()
        gate.showLoading(status: "Connecting to \(connection.serverName)…")
        launchTask = Task { @MainActor [weak self, weak gate] in
            let outcome = await AppLaunchSession.run(connection: connection) { message in
                Task { @MainActor in gate?.showProgress(message) }
            }
            guard !Task.isCancelled, let self, let gate else { return }
            switch outcome {
            case .success(let payload):
                let tabBar = self.buildMainApp(payload)
                gate.playSuccess { [weak self] in
                    self?.present(root: tabBar)
                }
            case .failure(.signInExpired):
                gate.showSignInExpired()
            case .failure(let failure):
                gate.showFailure(
                    title: "Couldn’t Reach \(connection.serverName)",
                    message: failure.message,
                    secondaryTitle: DemoMode.shared.isActive ? "Leave the Demo" : "Switch Server"
                )
            }
        }
    }

    private func installLaunchGate() -> TVLaunchViewController {
        let gate = TVLaunchViewController()
        gate.onRetry = { [weak self] in self?.reconnect() }
        gate.onSwitchServer = { [weak self] in
            if DemoMode.shared.isActive { self?.leaveDemo() } else { self?.switchServer() }
        }
        gate.onSignInAgain = { [weak self] in self?.signInAgain() }
        gate.onSignOut = { [weak self] in self?.confirmSignOut() }
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
        let environment = TVAppEnvironment(payload: payload, router: router, session: TVWeakSession(self))
        return TVRootTabBarController(environment: environment)
    }

    private func present(root: TVRootTabBarController) {
        window.backgroundColor = Theme.Color.canvas
        guard !UIAccessibility.isReduceMotionEnabled else {
            window.rootViewController = root
            router.activate(root)
            presentDemoIntroIfPending()
            Task { await presentTrialNoticeIfDue() }
            return
        }
        UIView.transition(with: window, duration: Self.crossDissolveDuration, options: [.transitionCrossDissolve, .curveEaseOut]) {
            self.window.rootViewController = root
        } completion: { [weak self] _ in
            self?.router.activate(root)
            self?.presentDemoIntroIfPending()
            Task { await self?.presentTrialNoticeIfDue() }
        }
    }

    private func showOnboarding() {
        let onboarding = TVScreens.onboarding(mode: .signIn) { [weak self] connection in
            self?.launch(connection: connection)
        }
        window.backgroundColor = Theme.Color.canvas
        window.rootViewController = TVNavigation.makeNavigationController(root: onboarding)
    }

    var topViewController: UIViewController? {
        var top = window.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

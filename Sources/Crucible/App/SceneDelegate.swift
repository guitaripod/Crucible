import CrucibleCore
import CrucibleDesign
import CrucibleStats
import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var pendingActivity: NSUserActivity?
    private var launchTask: Task<Void, Never>?

    /// The window that connects to the server on behalf of every window. The others hold their launch screen and take its result, so
    /// several windows never validate the route or fetch the library at the same time.
    private static weak var launchLeader: SceneDelegate?
    /// What the last successful connection produced, kept so a window opened later shows the library at once.
    private static var latestPayload: LaunchPayload?
    private static let minimumWindowSize = CGSize(width: 320, height: 480)

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        windowScene.sizeRestrictions?.minimumSize = Self.minimumWindowSize
        let window = UIWindow(windowScene: windowScene)
        window.tintColor = Theme.Color.accent
        AppearanceController.apply(to: window)
        window.backgroundColor = CrystalGlyphView.canvas
        self.window = window
        window.makeKeyAndVisible()

        pendingActivity = connectionOptions.userActivities.first ?? session.stateRestorationActivity
        AppLogger.notice("Window connected (\(UIApplication.shared.connectedScenes.count) open, activity: \(pendingActivity?.activityType ?? "none"))", .lifecycle)
        connectToLibrary()
    }

    /// A new window joins whatever the app is doing: the library when another window already shows it, the connection in progress, or a
    /// fresh connection when nothing is running.
    private func connectToLibrary() {
        if let payload = Self.latestPayload {
            adopt(payload, freshHome: false)
        } else if Self.launchLeader != nil {
            follow()
        } else {
            reconfigureRoot()
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        route(userActivity)
    }

    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        (window?.rootViewController as? TabBarController)?.restorationActivity()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        guard Self.isFirstWindowInForeground(scene) else { return }
        DownloadManager.shared.handleEnteredForeground()
        ProAccess.shared.refresh()
        AutoDownloadPolicy.shared.evaluateOnForeground()
        refreshDemoLibrary()
    }

    /// The work that follows the app coming back runs once, for the first window to return, not again for every other window.
    private static func isFirstWindowInForeground(_ scene: UIScene) -> Bool {
        !UIApplication.shared.connectedScenes.contains { other in
            other !== scene && (other.activationState == .foregroundActive || other.activationState == .foregroundInactive)
        }
    }

    /// A window closed while it was connecting hands the connection to another window, so the rest never wait on a launch nobody runs.
    func sceneDidDisconnect(_ scene: UIScene) {
        AppLogger.notice("Window closed", .lifecycle)
        guard Self.launchLeader === self else { return }
        launchTask?.cancel()
        launchTask = nil
        Self.launchLeader = nil
        Self.otherWindows(than: self).first?.reconfigureRoot()
    }

    /// The demo library lives inside the app, so a long stay in the background can end it. Coming back asks it to start again, and if it
    /// answers somewhere new the app signs in to the new address, or returns to the welcome screen when it cannot start.
    private func refreshDemoLibrary() {
        guard DemoMode.shared.isActive, let previous = DemoMode.shared.endpoint?.serverURL else { return }
        Task { @MainActor [weak self] in
            let resumed = await DemoMode.shared.resume()
            guard let self else { return }
            if !resumed { AccountSessionReset.signOut(.phone) }
            if !resumed || DemoMode.shared.endpoint?.serverURL != previous { reconfigureRoot() }
        }
    }

    private func route(_ activity: NSUserActivity) {
        guard let tabBar = window?.rootViewController as? TabBarController else {
            pendingActivity = activity
            return
        }
        tabBar.restore(from: activity)
    }

    /// Starts over in every window: this one connects, the others wait on it and then show what it found.
    func reconfigureRoot() {
        launchTask?.cancel()
        Self.latestPayload = nil
        Self.launchLeader = self
        Self.otherWindows(than: self).forEach { $0.follow() }
        guard DemoMode.shared.isActive else {
            showConnectionOrSetup()
            return
        }
        resumeDemo()
    }

    private static func otherWindows(than scene: SceneDelegate) -> [SceneDelegate] {
        UIApplication.shared.connectedScenes.compactMap { $0.delegate as? SceneDelegate }.filter { $0 !== scene }
    }

    private var followers: [SceneDelegate] {
        Self.launchLeader === self ? Self.otherWindows(than: self) : []
    }

    /// Waits on the window that connects. A sign-in already on screen stays, so whatever was typed there is kept.
    private func follow() {
        launchTask?.cancel()
        launchTask = nil
        guard !isShowingServerSetup else { return }
        launchGate().showLoading(status: "Connecting…")
    }

    private var isShowingServerSetup: Bool {
        (window?.rootViewController as? UINavigationController)?.viewControllers.first is ServerSetupViewController
    }

    private func showConnectionOrSetup() {
        if let connection = ServerBootstrap.connection() {
            launch(connection: connection)
        } else {
            showServerSetup()
            followers.forEach { $0.showServerSetup() }
        }
    }

    /// A demo that was running when the app last quit starts its library again before anything is shown, because the library comes back
    /// on a new address. When it cannot, the app falls back to the welcome screen like after a sign-out.
    private func resumeDemo() {
        showLoading(DemoPhoneCopy.startingStatus)
        launchTask = Task { @MainActor [weak self] in
            let resumed = await DemoMode.shared.resume()
            guard !Task.isCancelled, let self else { return }
            if !resumed { AccountSessionReset.signOut(.phone) }
            showConnectionOrSetup()
        }
    }

    private func showLoading(_ status: String) {
        launchGate().showLoading(status: status)
        followers.forEach { $0.launchGate().showLoading(status: status) }
    }

    /// The main UI is never on screen with a broken connection: the launch screen holds until the
    /// route is validated (healing it if needed) and both Home and Library payloads are in hand.
    private func launch(connection: PlexConnection) {
        AccountSessionReset.reconcileServer(machineIdentifier: connection.machineIdentifier, .phone)
        let gate = launchGate()
        showLoading("Connecting to \(connection.serverName)…")
        launchTask = Task { @MainActor [weak self, weak gate] in
            let outcome = await AppLaunchSession.run(connection: connection) { message in
                Task { @MainActor in self?.showLoading(message) }
            }
            guard !Task.isCancelled, let self, let gate else { return }
            launchTask = nil
            switch outcome {
            case .success(let payload):
                let tabBar = self.buildMainApp(payload)
                let followers = self.followers
                Self.launchLeader = nil
                Self.latestPayload = payload
                gate.playSuccess { [weak self] in
                    self?.present(root: tabBar)
                }
                followers.forEach { $0.adopt(payload, freshHome: true) }
            case .failure(let failure):
                let followers = self.followers
                Self.launchLeader = nil
                showFailure(failure, connection: connection)
                followers.forEach { $0.showFailure(failure, connection: connection) }
            }
        }
    }

    private func showFailure(_ failure: LaunchFailure, connection: PlexConnection) {
        let gate = launchGate()
        let hasOffline = DownloadManager.shared.items.contains { $0.state == .completed }
        gate.showFailure(
            title: "Couldn't Reach \(connection.serverName)",
            message: failure.message,
            canOpenDownloads: hasOffline
        )
        gate.onOpenDownloads = { [weak self] in self?.showOfflineDownloads(connection: connection) }
    }

    /// Shows the library another window connected to, without connecting again. Home loads its own shelves when the payload is no longer
    /// fresh.
    private func adopt(_ payload: LaunchPayload, freshHome: Bool) {
        launchTask?.cancel()
        launchTask = nil
        let tabBar = TabBarController(payload: payload, preloadsHome: freshHome)
        if let gate = window?.rootViewController as? LaunchViewController {
            gate.playSuccess { [weak self] in self?.present(root: tabBar) }
        } else {
            present(root: tabBar)
        }
    }

    private func launchGate() -> LaunchViewController {
        (window?.rootViewController as? LaunchViewController) ?? installLaunchScreen()
    }

    private func installLaunchScreen() -> LaunchViewController {
        let gate = LaunchViewController()
        gate.onRetry = { [weak self] in self?.reconfigureRoot() }
        gate.onSwitchServer = { [weak self] in self?.switchServerFromLaunchFailure() }
        gate.switchTitle = DemoMode.shared.isActive ? DemoPhoneCopy.leaveTitle : "Switch Server"
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
        window.backgroundColor = Theme.Color.canvas
        UIView.transition(with: window, duration: 0.4, options: [.transitionCrossDissolve, .curveEaseOut]) {
            window.rootViewController = root
        } completion: { [weak self] _ in
            guard let self else { return }
            if let tabBar = root as? TabBarController { DemoCoordinator.shared.mainAppDidAppear(tabBar) }
            guard let pending = self.pendingActivity else { return }
            self.pendingActivity = nil
            self.route(pending)
        }
    }

    private func showServerSetup() {
        launchTask?.cancel()
        launchTask = nil
        guard !isShowingServerSetup else { return }
        let setup = ServerSetupViewController()
        setup.onConnected = { [weak self] connection in
            self?.lead(connection: connection)
        }
        let nav = UINavigationController(rootViewController: setup)
        window?.backgroundColor = Theme.Color.canvas
        window?.rootViewController = nav
    }

    /// The window where the sign-in finished connects for every window.
    private func lead(connection: PlexConnection) {
        Self.latestPayload = nil
        Self.launchLeader = self
        Self.otherWindows(than: self).forEach { $0.follow() }
        launch(connection: connection)
    }

    /// Switching server means signing in to another one, which a demo that cannot start has no use for: leaving the demo shows the welcome
    /// screen instead.
    private func switchServerFromLaunchFailure() {
        guard DemoMode.shared.isActive else {
            presentServerSwitcher()
            return
        }
        DemoCoordinator.shared.leave(scene: self)
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
        let offlineHome = OfflineHomeViewController(api: api, connection: connection)
        let nav = UINavigationController(rootViewController: offlineHome)
        nav.modalPresentationStyle = .fullScreen
        gate.present(nav, animated: true)
    }
}

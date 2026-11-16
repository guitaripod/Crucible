import CrucibleCore
import CrucibleStats
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// What a sign-out or a server change resets above Core on Linux: the statistics mirror and the image cache.
@MainActor
enum LinuxSession {
    static var imageCacheDirectory: URL { AppPlatform.cachesDirectory.appendingPathComponent("images") }

    /// Where the measured artwork shapes of one server are kept between launches.
    static func artworkShapesFile(machineIdentifier: String) -> URL {
        let name = machineIdentifier.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        return AppPlatform.cachesDirectory.appendingPathComponent("artwork-shapes").appendingPathComponent("\(name.isEmpty ? "server" : name).json")
    }

    static var collaborators: AccountSessionCollaborators {
        AccountSessionCollaborators(
            resetStats: { StatsManager.shared.handleSignOut() },
            clearImageCache: { try? FileManager.default.removeItem(at: imageCacheDirectory) }
        )
    }
}

/// Owns the first window's root and the session behind it (`TVAppCoordinator`): the saved connection, the launch gate, the
/// main app and onboarding, and the windows opened beside it on the same connection. The main UI never shows with a broken
/// connection: the gate holds until the route is validated and Home and the libraries are in hand.
@MainActor
final class AppCoordinator: WindowDelegate {
    /// The first window; another one takes its place when it closes while others are open.
    private(set) var window: Window
    var onQuit: (() -> Void)?
    let router = Router()
    private var launchTask: Task<Void, Never>?
    private var finaleTask: Task<Void, Never>?
    private var root: RootView?
    private var payload: LaunchPayload?
    private var onboarding: OnboardingView?
    private var notifications: DesktopNotifications?
    private var newsWatcher: LibraryNewsWatcher?
    /// The windows beside the first, oldest first.
    private var scenes: [SceneWindow] = []
    private weak var activeWindow: Window?
    private var focusedWindows: Set<ObjectIdentifier> = []

    /// Every open window, the first one first.
    var allWindows: [Window] { [window] + scenes.map(\.window) }

    private static let finaleSettleDelay: Duration = .milliseconds(1200)
    private static let finaleRetryInterval: Duration = .milliseconds(800)

    init(window: Window) {
        self.window = window
        window.delegate = self
        DemoTour.shared.onFinale = { [weak self] in self?.scheduleFinale() }
        PreferenceSetting.didChange = { setting in
            if setting.notificationKind != nil || setting == .notifyWhileClosed { NewsTimer.sync() }
        }
        if let loop = window.loop, let notifications = DesktopNotifications(loop: loop) {
            notifications.onOpen = { [weak self] link, token in self?.open([link], activationToken: token) }
            self.notifications = notifications
            newsWatcher = LibraryNewsWatcher(notifications: notifications)
        }
    }

    func start() {
        reconnect()
    }

    /// A demo that was running when the app last quit comes back first; otherwise a saved server launches, a Plex sign-in
    /// without a saved server goes straight to choosing one, and nothing starts at the welcome screen.
    func reconnect() {
        launchTask?.cancel()
        if DemoMode.shared.isActive {
            resumeDemo()
        } else if let connection = ServerBootstrap.connection() {
            launch(connection)
        } else if ServerBootstrap.accountToken != nil {
            showOnboarding(.switchServer)
        } else {
            showOnboarding(.signIn)
        }
    }

    /// The launch gate, its failure buttons wired: in the demo Switch Server is Leave the Demo.
    private func makeGate() -> LaunchView {
        let gate = LaunchView()
        gate.onRetry = { [weak self] in self?.reconnect() }
        gate.onSwitchServer = { [weak self] in
            if DemoMode.shared.isActive { self?.leaveDemo() } else { self?.showOnboarding(.switchServer) }
        }
        gate.onSignInAgain = { [weak self] in self?.showOnboarding(.reauthenticate) }
        gate.onSignOut = { [weak self] in self?.confirmSignOut() }
        return gate
    }

    /// Connects to `connection` behind the launch gate, `existing` when one already shows (a demo starting again).
    private func launch(_ connection: PlexConnection, gate existing: LaunchView? = nil) {
        AccountSessionReset.reconcileServer(machineIdentifier: connection.machineIdentifier, LinuxSession.collaborators)
        let gate = existing ?? makeGate()
        if existing == nil || gate.window == nil { install(gate) }
        gate.showLoading(String(localized: "Connecting to \(connection.serverName)…"))
        launchTask = Task { [weak self, weak gate] in
            let outcome = await AppLaunchSession.run(connection: connection) { message in
                Task { @MainActor in gate?.showProgress(message) }
            }
            guard !Task.isCancelled, let self, let gate else { return }
            switch outcome {
            case .success(let payload):
                UserDefaults.standard.synchronize()
                gate.playSuccess { [weak self] in
                    guard let self else { return }
                    self.showMain(payload)
                    if let root = self.root { self.dissolve(gate, over: root) }
                    self.presentDemoIntroIfPending()
                }
            case .failure(.signInExpired):
                gate.showSignInExpired()
            case .failure(let failure):
                gate.showFailure(title: String(localized: "Couldn’t Reach \(connection.serverName)"), message: failure.message)
            }
        }
    }

    private func showMain(_ payload: LaunchPayload) {
        StatsManager.shared.configure(api: payload.api)
        StatsManager.shared.kickBackgroundSync()
        Artwork.pipeline = PlexArtworkPipeline(baseURL: payload.connection.serverURI)
        window.useImages(diskDirectory: LinuxSession.imageCacheDirectory, fetch: PlexArtworkPipeline.fetcher(token: payload.connection.authToken))
        ArtworkShapes.shared.use(file: LinuxSession.artworkShapesFile(machineIdentifier: payload.connection.machineIdentifier))
        let main = RootView(payload: payload)
        wire(main) { [weak self] in self?.closeFirstWindow() }
        APIClient.onBaseURLChanged.withLock { handler in
            handler = { url in Task { @MainActor in Artwork.pipeline = PlexArtworkPipeline(baseURL: url) } }
        }
        ServerRouteMonitor.shared.mainAppReady()
        self.payload = payload
        root = main
        install(main)
        router.activate(main)
        let restored = WindowRestoration.restoreAll()
        main.restoreWindow(restored.first)
        for state in restored.dropFirst() { openWindow(restoring: state) }
        newsWatcher?.start()
        NewsTimer.sync()
    }

    /// What a main UI asks of the app, in any window: the session's changes go through the first window, `closing` closes
    /// the window the UI is in.
    private func wire(_ main: RootView, closing: @escaping () -> Void) {
        main.onSignOut = { [weak self] in self?.signOut() }
        main.onLeaveDemo = { [weak self] in self?.leaveDemo() }
        main.onSwitchServer = { [weak self] in self?.showOnboarding(.switchServer) }
        main.onReconnect = { [weak self] in self?.reconnect() }
        main.onQuit = { [weak self] in self?.onQuit?() }
        main.onNewWindow = { [weak self] link in self?.openWindow(link: link) }
        main.onCloseWindow = closing
    }

    // MARK: Windows

    /// Opens another window on the connection the first one holds (Ctrl+N, Open in New Window, a middle click), on `link`
    /// when there is one, or on the tab and title `state` kept from the last run; nothing until the main UI is up.
    func openWindow(link: URL? = nil, restoring state: WindowRestoration.State? = nil) {
        guard let payload, root != nil, let loop = window.loop else { return }
        let opened: Window
        do {
            opened = try Window(title: "Crucible", appID: "org.guitaripod.Crucible", loop: loop,
                                shaderCache: AppPlatform.cachesDirectory.appendingPathComponent("shaders.cache"))
        } catch {
            MidgarLog.error("Opening a new window failed: \(error)", category: .lifecycle)
            return
        }
        opened.makeTooltip = { TooltipView(text: $0) }
        DesktopAccessibility.apply(to: opened)
        opened.useImages(diskDirectory: LinuxSession.imageCacheDirectory, fetch: PlexArtworkPipeline.fetcher(token: payload.connection.authToken))
        let main = RootView(payload: payload)
        let scene = SceneWindow(window: opened, root: main)
        wire(main) { [weak self, weak scene] in
            guard let self, let scene else { return }
            self.close(scene)
        }
        scene.onClose = { [weak self] scene in self?.close(scene) }
        scene.onQuit = { [weak self] in self?.onQuit?() }
        scene.onFocusChange = { [weak self] scene, focused in self?.windowFocus(scene.window, focused: focused) }
        scene.onOpenInNewWindow = { [weak self] link in self?.openWindow(link: link) }
        scenes.append(scene)
        main.restoreWindow(state)
        if let link { scene.router.handle(link) }
        MidgarLog.notice("Opened window \(scenes.count + 1)", category: .lifecycle)
    }

    /// A window beside the first closed on its own: what it played stops and it is not reopened next time.
    private func close(_ scene: SceneWindow) {
        scenes.removeAll { $0 === scene }
        WindowRestoration.untrack(scene.root)
        scene.close()
    }

    /// The session behind every window ended (sign-out, another server, the demo leaving): the windows beside the first
    /// close with it.
    private func closeScenes() {
        let closing = scenes
        scenes.removeAll()
        WindowRestoration.untrackAll()
        closing.forEach { $0.close() }
    }

    /// The first window's close button or Ctrl+W: Crucible quits with it unless other windows are open; then the oldest of
    /// them becomes the first, keeping the connection, and this one closes.
    private func closeFirstWindow() {
        guard let next = scenes.first, let root else {
            onQuit?()
            return
        }
        scenes.removeFirst()
        WindowRestoration.untrack(root)
        root.closePlayer()
        router.deactivate()
        let closing = window
        next.handOver()
        window = next.window
        self.root = next.root
        wire(next.root) { [weak self] in self?.closeFirstWindow() }
        window.delegate = self
        router.activate(next.root)
        closing.close()
    }

    /// Stops what plays in every window, before quitting.
    func closeAllPlayers() {
        root?.closePlayer()
        for scene in scenes { scene.root.closePlayer() }
    }

    /// Crucible is active while any of its windows has the keyboard: coming back refreshes what is shared across screens,
    /// as the Apple TV does on returning to the foreground, and leaving lets the route monitor rest.
    private func windowFocus(_ window: Window, focused: Bool) {
        let wasActive = !focusedWindows.isEmpty
        if focused {
            focusedWindows.insert(ObjectIdentifier(window))
            activeWindow = window
        } else {
            focusedWindows.remove(ObjectIdentifier(window))
        }
        if focusedWindows.isEmpty, wasActive { ServerRouteMonitor.shared.appResignedActive() }
        guard !focusedWindows.isEmpty, !wasActive else { return }
        ServerRouteMonitor.shared.appBecameActive()
        guard root != nil else { return }
        Task { _ = await GuideStore.shared.refresh() }
    }

    /// The launch gate stays a moment over the app it hands to, fading out (`TVAppCoordinator`'s 0.4 s cross-dissolve).
    private func dissolve(_ gate: LaunchView, over root: RootView) {
        root.addSubview(gate)
        gate.frame = root.bounds
        gate.dissolveAway()
    }

    /// Links a later launch or a notification handed over: the window last used comes to the front with the token and
    /// each link opens in it.
    func open(_ urls: [URL], activationToken: String?) {
        let scene = scenes.first { $0.window === activeWindow }
        if let activationToken { (scene?.window ?? window).activate(token: activationToken) }
        for url in urls { _ = (scene?.router ?? router).handle(url) }
    }

    private func showOnboarding(_ mode: OnboardingView.Mode) {
        closeScenes()
        payload = nil
        newsWatcher?.stop()
        launchTask?.cancel()
        finaleTask?.cancel()
        APIClient.onBaseURLChanged.withLock { $0 = nil }
        router.deactivate()
        root = nil
        let flow = OnboardingView(mode: mode)
        flow.onConnected = { [weak self] connection in
            self?.onboarding = nil
            self?.launch(connection)
        }
        flow.onDemo = { [weak self] connection in
            LinuxDemoState.markIntroPending()
            self?.onboarding = nil
            self?.launch(connection)
        }
        flow.onCancel = { [weak self] in
            self?.onboarding = nil
            self?.reconnect()
        }
        onboarding = flow
        install(flow)
    }

    /// The expired-sign-in gate's Sign Out, which removes the account, asks first.
    private func confirmSignOut() {
        AlertView.confirm(title: String(localized: "Sign Out?"), message: String(localized: "This removes your Plex account from this computer."),
                          confirm: String(localized: "Sign Out"), in: window) { [weak self] in self?.signOut() }
    }

    func signOut() {
        MidgarLog.notice("Signing out", category: .lifecycle)
        launchTask?.cancel()
        AccountSessionReset.signOut(LinuxSession.collaborators)
        WindowRestoration.forget()
        NewsTimer.sync()
        root = nil
        showOnboarding(.signIn)
    }

    // MARK: Demo

    /// Starts the demo library again behind the launch gate: it answers on a new port, so the saved address moves to it.
    /// When it cannot start, the session it left behind points at a library that is gone, so it is forgotten and the
    /// welcome screen returns.
    private func resumeDemo() {
        closeScenes()
        payload = nil
        router.deactivate()
        root = nil
        let gate = makeGate()
        install(gate)
        gate.showLoading(String(localized: "Starting the demo…"))
        launchTask = Task { [weak self, weak gate] in
            let resumed = await DemoMode.shared.resume()
            guard !Task.isCancelled, let self else { return }
            guard resumed, let connection = ServerBootstrap.connection() else {
                self.forgetDemoThatCouldNotResume()
                return
            }
            self.launch(connection, gate: gate)
        }
    }

    private func forgetDemoThatCouldNotResume() {
        DemoTour.shared.reset()
        LinuxDemoState.clearIntro()
        AccountSessionReset.signOut(LinuxSession.collaborators)
        showOnboarding(.signIn)
    }

    /// Leaves the demo, from You, the tour, the finale or the launch gate: playback ends, the library stops, its session,
    /// statistics and tour are forgotten like a sign-out, and the welcome screen returns.
    func leaveDemo() {
        guard DemoMode.shared.isActive else { return }
        MidgarLog.notice("Leaving the demo", category: .lifecycle)
        finaleTask?.cancel()
        launchTask?.cancel()
        closeScenes()
        router.deactivate()
        root?.closePlayer()
        APIClient.onBaseURLChanged.withLock { $0 = nil }
        Task { [weak self] in
            await DemoMode.shared.exit(LinuxSession.collaborators)
            LinuxDemoState.clearIntro()
            self?.root = nil
            self?.showOnboarding(.signIn)
        }
    }

    /// Shows the demo's welcome once, over the main UI, the first time a demo session reaches it.
    private func presentDemoIntroIfPending() {
        guard DemoMode.shared.isActive, LinuxDemoState.isIntroPending, root != nil else { return }
        LinuxDemoState.clearIntro()
        DemoSheetView(title: DemoCopy.introTitle, message: DemoCopy.introBody, steps: DemoTour.shared.steps,
                      actions: [.init(title: DemoCopy.introStart, isPrimary: true) {}], quietest: 0).present(in: window)
    }

    /// The finale never covers the player, an alert, a menu or another sheet: it waits, a little after the step that earned
    /// it, until the main UI is free, and gives up if the demo ends first.
    private func scheduleFinale() {
        MidgarLog.notice("Demo finale scheduled", category: .lifecycle)
        finaleTask?.cancel()
        finaleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.finaleSettleDelay)
            while !Task.isCancelled, let self, DemoMode.shared.isActive {
                if let root = self.root, root.isUnobstructed {
                    MidgarLog.notice("Demo finale presented", category: .lifecycle)
                    self.presentFinale()
                    return
                }
                try? await Task.sleep(for: Self.finaleRetryInterval)
            }
        }
    }

    /// "Enjoying the demo?": connect a Plex server (after the same question Leave the Demo asks) or keep exploring. Crucible
    /// Pro is not on Linux, so where the Apple TV sells it the finale says how to use Crucible with one's own library.
    private func presentFinale() {
        let connect = DemoSheetView.Action(title: DemoCopy.connectTitle, isPrimary: true) { [weak self] in
            guard let self else { return }
            DemoLeave.confirm(connecting: true, in: self.window) { [weak self] in self?.leaveDemo() }
        }
        DemoSheetView(title: DemoCopy.finaleTitle, message: DemoCopy.connectBody,
                      actions: [connect, .init(title: DemoCopy.finaleKeepExploring, isPrimary: false) {}], quietest: 1).present(in: window)
    }

    private func install(_ view: View) {
        window.contentView = view
        window.background = Theme.current.palette.canvas
        window.focus.focus(view, animated: false)
    }

    // MARK: WindowDelegate

    func window(_ window: Window, unhandledKey event: KeyEvent) -> Bool {
        if event.key == Key.character("q") && event.modifiers == .control {
            onQuit?()
            return true
        }
        if let onboarding {
            if event.key == .f11 {
                window.setFullscreen(!window.isFullscreen)
                return true
            }
            let back = event.key == .escape || event.key == .back || (event.key == .left && event.modifiers == .alt)
            return back && onboarding.handleBack()
        }
        return root?.handleWindowKey(event, in: window) ?? false
    }

    func window(_ window: Window, zoomScrolled event: ScrollEvent) -> Bool {
        onboarding == nil && root?.zoomScrolled(event) == true
    }

    func window(_ window: Window, unhandledButton button: MouseButton) -> Bool {
        switch button {
        case .back:
            if let onboarding { return onboarding.handleBack() }
            return root?.handleBack() ?? false
        case .forward:
            return onboarding == nil && root?.handleForward() == true
        default:
            return false
        }
    }

    /// Coming back to the window refreshes what is shared across screens, as the Apple TV does on returning to the foreground,
    /// and the desktop's motion and contrast settings.
    func window(_ window: Window, keyboardFocusChanged focused: Bool) {
        if focused {
            DesktopAccessibility.apply(to: window)
            onboarding?.windowBecameActive()
        }
        windowFocus(window, focused: focused)
    }

    func window(_ window: Window, openInNewWindow link: URL) {
        openWindow(link: link)
    }

    func windowShouldClose(_ window: Window) {
        closeFirstWindow()
    }
}

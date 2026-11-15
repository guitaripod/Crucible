import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// What a sign-out or a server change resets above Core on Linux: the image cache.
@MainActor
enum LinuxSession {
    static var imageCacheDirectory: URL { AppPlatform.cachesDirectory.appendingPathComponent("images") }

    static var collaborators: AccountSessionCollaborators {
        AccountSessionCollaborators(
            resetStats: {},
            clearImageCache: { try? FileManager.default.removeItem(at: imageCacheDirectory) }
        )
    }
}

/// Owns the window's root and the session behind it (`TVAppCoordinator`): the saved connection, the launch gate, the main
/// app and onboarding. The main UI never shows with a broken connection: the gate holds until the route is validated and
/// Home and the libraries are in hand.
@MainActor
final class AppCoordinator: WindowDelegate {
    let window: Window
    var onQuit: (() -> Void)?
    private var launchTask: Task<Void, Never>?
    private var root: RootView?
    private var onboarding: OnboardingView?

    init(window: Window) {
        self.window = window
        window.delegate = self
    }

    func start() {
        reconnect()
    }

    /// A saved server launches; a Plex sign-in without a saved server goes straight to choosing one; nothing starts at
    /// the welcome screen.
    func reconnect() {
        launchTask?.cancel()
        if let connection = ServerBootstrap.connection() {
            launch(connection)
        } else if ServerBootstrap.accountToken != nil {
            showOnboarding(.switchServer)
        } else {
            showOnboarding(.signIn)
        }
    }

    private func launch(_ connection: PlexConnection) {
        AccountSessionReset.reconcileServer(machineIdentifier: connection.machineIdentifier, LinuxSession.collaborators)
        let gate = LaunchView()
        gate.onRetry = { [weak self] in self?.reconnect() }
        gate.onSwitchServer = { [weak self] in self?.showOnboarding(.switchServer) }
        gate.onSignInAgain = { [weak self] in self?.showOnboarding(.reauthenticate) }
        gate.onSignOut = { [weak self] in self?.signOut() }
        install(gate)
        gate.showLoading(String(localized: "Connecting to \(connection.serverName)…"))
        launchTask = Task { [weak self, weak gate] in
            let outcome = await AppLaunchSession.run(connection: connection) { message in
                Task { @MainActor in gate?.showProgress(message) }
            }
            guard !Task.isCancelled, let self, let gate else { return }
            switch outcome {
            case .success(let payload):
                UserDefaults.standard.synchronize()
                self.showMain(payload)
            case .failure(.signInExpired):
                gate.showSignInExpired()
            case .failure(let failure):
                gate.showFailure(title: String(localized: "Couldn’t Reach \(connection.serverName)"), message: failure.message)
            }
        }
    }

    private func showMain(_ payload: LaunchPayload) {
        Artwork.pipeline = PlexArtworkPipeline(baseURL: payload.connection.serverURI)
        window.useImages(diskDirectory: LinuxSession.imageCacheDirectory, fetch: PlexArtworkPipeline.fetcher(token: payload.connection.authToken))
        let main = RootView(payload: payload)
        main.onSignOut = { [weak self] in self?.signOut() }
        main.onSwitchServer = { [weak self] in self?.showOnboarding(.switchServer) }
        root = main
        install(main)
    }

    private func showOnboarding(_ mode: OnboardingView.Mode) {
        launchTask?.cancel()
        let flow = OnboardingView(mode: mode)
        flow.onConnected = { [weak self] connection in
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

    func signOut() {
        MidgarLog.notice("Signing out", category: .lifecycle)
        launchTask?.cancel()
        AccountSessionReset.signOut(LinuxSession.collaborators)
        root = nil
        showOnboarding(.signIn)
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
        if event.key == .f11 {
            window.setFullscreen(!window.isFullscreen)
            return true
        }
        if event.key == Key.character("p") && event.modifiers == [.control, .shift] {
            window.showsPerformanceHUD.toggle()
            return true
        }
        if event.key == .escape || event.key == .back || (event.key == .left && event.modifiers == .alt) {
            if let onboarding { return onboarding.handleBack() }
            return root?.handleBack() ?? false
        }
        return root?.handleCommand(event) ?? false
    }

    func window(_ window: Window, unhandledButton button: MouseButton) -> Bool {
        guard button == .back else { return false }
        if let onboarding { return onboarding.handleBack() }
        return root?.handleBack() ?? false
    }

    func windowShouldClose(_ window: Window) {
        onQuit?()
    }
}

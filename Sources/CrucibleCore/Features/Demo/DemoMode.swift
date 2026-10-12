import Foundation

/// Where the demo library answers: a Plex server and a plex.tv stand-in, both fictional, plus the credentials the app signs in with.
package struct DemoEndpoint: Equatable, Sendable {
    package var serverURL: URL
    package var plexTVURL: URL
    package var token: String
    package var machineIdentifier: String
    package var serverName: String
    package var accountName: String

    package init(serverURL: URL, plexTVURL: URL, token: String, machineIdentifier: String, serverName: String, accountName: String) {
        self.serverURL = serverURL
        self.plexTVURL = plexTVURL
        self.token = token
        self.machineIdentifier = machineIdentifier
        self.serverName = serverName
        self.accountName = accountName
    }
}

/// The fictional library behind the demo. The App Store builds link `CrucibleDemo`, which serves it from inside the app; source builds
/// have no provider, so the demo is simply not offered there.
package protocol DemoProviding: AnyObject, Sendable {
    /// Starts the library and returns where it answers. Starting an already running library returns the same endpoint.
    func start() async throws -> DemoEndpoint

    func stop() async
}

/// The demo: a fictional Plex library that runs inside the app so nobody needs a server, an account or a Plex Pass to try Crucible.
/// While it is on, the saved session points at it, everything is unlocked and the Statistics are the demo's own; leaving it forgets
/// all of that like a sign-out does.
@MainActor
package final class DemoMode {
    package static let shared = DemoMode()

    package typealias Observer = @MainActor (Bool) -> Void

    package static let activeKey = "crucible_demo_active"

    package private(set) var provider: (any DemoProviding)?
    package private(set) var endpoint: DemoEndpoint?

    private let defaults: UserDefaults
    private let access: ProAccess
    private var observers: [UUID: Observer] = [:]

    package init(defaults: UserDefaults = .standard, access: ProAccess? = nil) {
        self.defaults = defaults
        self.access = access ?? .shared
    }

    package var isAvailable: Bool { provider != nil }

    package var isActive: Bool { defaults.bool(forKey: Self.activeKey) }

    /// Offers the demo. Called once by an app entry point that links `CrucibleDemo`.
    package func install(_ provider: any DemoProviding) {
        self.provider = provider
    }

    /// Starts the library and signs the app in to it. Throws when the library cannot start; nothing has changed then.
    package func enter() async throws {
        guard let provider else { throw DemoError.unavailable }
        let endpoint = try await provider.start()
        configureSession(for: endpoint)
        self.endpoint = endpoint
        defaults.set(true, forKey: Self.activeKey)
        access.setDemoUnlocked(true)
        DemoTour.shared.begin()
        AppLogger.notice("Demo started", .lifecycle)
        notify()
    }

    /// Brings a demo that was running when the app last quit back to life. The library starts on a new port, so the saved server address
    /// is replaced. When it cannot start the demo is left and the app returns to its welcome screen.
    @discardableResult
    package func resume() async -> Bool {
        guard isActive else { return false }
        guard let provider, let endpoint = try? await provider.start() else {
            AppLogger.error("The demo could not resume; leaving it", .lifecycle)
            defaults.set(false, forKey: Self.activeKey)
            PlexTVHost.setOverride(nil)
            access.setDemoUnlocked(false)
            return false
        }
        configureSession(for: endpoint)
        self.endpoint = endpoint
        access.setDemoUnlocked(true)
        notify()
        return true
    }

    /// Leaves the demo: stops the library and forgets the session, the statistics and the tour, exactly like a sign-out.
    package func exit(_ collaborators: AccountSessionCollaborators) async {
        await provider?.stop()
        defaults.set(false, forKey: Self.activeKey)
        PlexTVHost.setOverride(nil)
        endpoint = nil
        access.setDemoUnlocked(false)
        DemoTour.shared.reset()
        AccountSessionReset.signOut(collaborators)
        AppLogger.notice("Demo left", .lifecycle)
        notify()
    }

    @discardableResult
    package func observe(_ observer: @escaping Observer) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    package func stopObserving(_ token: UUID) {
        observers[token] = nil
    }

    private func configureSession(for endpoint: DemoEndpoint) {
        PlexTVHost.setOverride(endpoint.plexTVURL)
        ServerBootstrap.clear()
        ServerBootstrap.saveToken(endpoint.token)
        ServerBootstrap.saveServer(uri: endpoint.serverURL, name: endpoint.serverName, machineIdentifier: endpoint.machineIdentifier)
        defaults.set(endpoint.accountName, forKey: PlexAccountName.defaultsKey)
    }

    private func notify() {
        let active = isActive
        for observer in observers.values { observer(active) }
    }
}

package enum DemoError: Error, Equatable, Sendable {
    case unavailable
}

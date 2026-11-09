import Foundation
import MidgarCore

/// Where the demo's stand-in Seerr answers while the demo runs.
package enum SeerrConfig {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var standIn: URL?

    package static var standInAddress: URL? { lock.withLock { standIn } }
    package static var isStandIn: Bool { standInAddress != nil }

    package static func setStandIn(_ url: URL?) {
        lock.withLock { standIn = url }
    }
}

/// The Seerr a viewer connected on one Plex server, as saved on the device. The secrets sit in the Keychain.
package struct SeerrConnection: Codable, Equatable, Sendable {
    /// Where Seerr last answered.
    package var address: URL
    package var auth: SeerrTarget.Auth
    package var user: SeerrUser?
    package var title: String?
    package var partialRequests: Bool
    /// Other addresses this Seerr answered at, such as one the viewer typed for away from home (`SeerrRoutes`).
    package var remembered: [URL]

    package init(address: URL, auth: SeerrTarget.Auth, user: SeerrUser? = nil, title: String? = nil, partialRequests: Bool = true, remembered: [URL] = []) {
        self.address = address
        self.auth = auth
        self.user = user
        self.title = title
        self.partialRequests = partialRequests
        self.remembered = remembered
    }

    private enum CodingKeys: String, CodingKey {
        case address, auth, user, title, partialRequests, remembered
    }

    /// A connection saved before addresses were remembered reads as remembering only its own.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        address = try container.decode(URL.self, forKey: .address)
        auth = try container.decode(SeerrTarget.Auth.self, forKey: .auth)
        user = try container.decodeIfPresent(SeerrUser.self, forKey: .user)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        partialRequests = try container.decodeIfPresent(Bool.self, forKey: .partialRequests) ?? true
        remembered = try container.decodeIfPresent([URL].self, forKey: .remembered) ?? [address]
    }

    /// Seerr's own name for itself, when its owner renamed it, otherwise its address.
    package var displayName: String {
        if let title, !title.isEmpty, title != "Seerr", title != "Overseerr", title != "Jellyseerr" { return title }
        return SeerrDiscovery.displayAddress(address)
    }
}

/// Where Seerr stands for the viewer watching now on the server Crucible is connected to. Screens observe it.
@MainActor
package final class SeerrAccount {
    package static let shared = SeerrAccount()

    package enum Status: Equatable, Sendable {
        /// A restricted Plex Home profile, which cannot ask for titles.
        case restricted
        case disconnected
        case connected(SeerrConnection)
        /// Seerr ended the session and a new sign-in failed: the viewer must connect again.
        case needsReconnect(SeerrConnection)
    }

    package private(set) var status: Status = .disconnected
    private var observers: [UUID: @MainActor () -> Void] = [:]
    private let client: SeerrClient
    private let defaults: UserDefaults
    private let server: () -> String?
    private let owner: () -> String
    private let standIn: () -> URL?
    private let serverRoutes: () -> (routes: [URL], inUse: URL?)
    private var routeObservation: UUID?
    /// While a connect signs in, a route change must not point the client back at the connection being replaced.
    private var isConnecting = false

    /// - Parameters:
    ///   - owner: who the connection belongs to, `currentOwner` outside tests.
    ///   - standIn: the demo's stand-in Seerr while the demo runs.
    package init(
        client: SeerrClient = .shared,
        defaults: UserDefaults = .standard,
        server: @escaping () -> String? = { ServerBootstrap.savedMachineIdentifier },
        owner: @escaping () -> String = { SeerrAccount.currentOwner },
        standIn: @escaping () -> URL? = { SeerrConfig.standInAddress },
        serverRoutes: @escaping () -> (routes: [URL], inUse: URL?) = SeerrAccount.liveServerRoutes
    ) {
        self.client = client
        self.defaults = defaults
        self.server = server
        self.owner = owner
        self.standIn = standIn
        self.serverRoutes = serverRoutes
    }

    /// Every route Crucible knows to the Plex server, and the one in use.
    package nonisolated static func liveServerRoutes() -> (routes: [URL], inUse: URL?) {
        guard let connection = ServerBootstrap.connection() else { return ([], nil) }
        return (connection.candidateURIs, connection.serverURI)
    }

    /// Who the connection belongs to: the Home profile watching now, or the account itself, apart in the demo.
    package nonisolated static var currentOwner: String {
        (SeerrConfig.isStandIn ? "standin." : "") + (HomeProfiles.active?.id ?? "account")
    }

    package var connection: SeerrConnection? {
        switch status {
        case .connected(let connection), .needsReconnect(let connection): return connection
        case .disconnected, .restricted: return nil
        }
    }

    package var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    package var permissions: SeerrPermissions { connection?.user?.rights ?? [] }

    package var managesRequests: Bool { isConnected && permissions.managesRequests }

    /// A line for the Integrations category on the first Settings screen when Seerr is the only integration on.
    package var summary: String? {
        switch status {
        case .connected(let connection): return "Seerr · \(connection.displayName)"
        case .needsReconnect: return String(localized: "Seerr · Connect again", comment: "Integrations summary when Seerr signed Crucible out")
        case .disconnected, .restricted: return nil
        }
    }

    private var serverKey: String { (standIn() != nil ? "standin." : "") + (server() ?? "none") }
    private var connectionKey: String { "seerr.connection.\(owner()).\(server() ?? "none")" }
    private var knownAddressKey: String { "seerr.known.\(serverKey)" }

    private func target(for connection: SeerrConnection, at address: URL? = nil) -> SeerrTarget {
        SeerrTarget(address: address ?? connection.address, auth: connection.auth, secretKey: "seerr.\(owner()).\(server() ?? "none")")
    }

    /// The addresses `connection` is tried at on this network, best first. The demo's stand-in has one.
    private func addresses(for connection: SeerrConnection) -> [URL] {
        guard standIn() == nil else { return [connection.address] }
        let server = serverRoutes()
        return SeerrRoutes.ordered(address: connection.address, remembered: connection.remembered, serverRoutes: server.routes, serverInUse: server.inUse)
    }

    /// Points the client at the best address for this network, with the others to move to.
    private func useBestAddress(for connection: SeerrConnection) async {
        let addresses = addresses(for: connection)
        await client.use(target(for: connection, at: addresses.first), alternates: addresses)
    }

    /// Follows Plex: when Crucible moves to another route to the server, Seerr moves to the address that matches it, and an
    /// address the client moved to on its own becomes the one saved.
    private func followRoutes() async {
        guard routeObservation == nil else { return }
        routeObservation = ServerRouteMonitor.shared.observe { [weak self] _ in
            guard let self, !self.isConnecting, let connection = self.connection else { return }
            Task { await self.useBestAddress(for: connection) }
        }
        await client.onAddressMove { [weak self] address in
            Task { @MainActor in self?.moved(to: address) }
        }
    }

    private func moved(to address: URL) {
        guard var connection, connection.address != address, standIn() == nil else { return }
        connection.address = address
        connection.remembered = SeerrRoutes.remembering(address, in: connection.remembered)
        save(connection)
        switch status {
        case .connected: set(.connected(connection))
        case .needsReconnect: set(.needsReconnect(connection))
        case .disconnected, .restricted: break
        }
    }

    /// The saved connection; in the demo it follows the stand-in, whose address changes with each launch.
    private var saved: SeerrConnection? {
        guard var connection = defaults.data(forKey: connectionKey).flatMap({ try? JSONDecoder().decode(SeerrConnection.self, from: $0) }) else { return nil }
        if let standIn = standIn() { connection.address = standIn }
        return connection
    }

    private func save(_ connection: SeerrConnection?) {
        if let connection, let data = try? JSONEncoder().encode(connection) {
            defaults.set(data, forKey: connectionKey)
            defaults.set(connection.address.absoluteString, forKey: knownAddressKey)
        } else {
            defaults.removeObject(forKey: connectionKey)
        }
    }

    /// Reads what is saved for the viewer watching now and checks the session is still good. Call at launch and after a Home
    /// profile switch.
    package func load() async {
        if HomeProfiles.active?.isRestricted == true {
            await client.use(nil)
            return set(.restricted)
        }
        guard let connection = saved else {
            await client.use(nil)
            return set(.disconnected)
        }
        await followRoutes()
        await useBestAddress(for: connection)
        set(.connected(connection))
        await refreshUser()
    }

    /// Asks Seerr who the viewer is, which also renews a session that ran out.
    /// Asks Seerr who the viewer is, which also renews a session that ran out. Only the user is written back, onto the
    /// connection as it is once Seerr answered, and only for the viewer who asked.
    package func refreshUser() async {
        guard connection != nil else { return }
        let asked = owner()
        do {
            let user = try await client.send(.me, as: SeerrUser.self)
            guard owner() == asked, var connection = connection else { return }
            connection.user = user
            save(connection)
            set(.connected(connection))
        } catch SeerrError.signedOut, SeerrError.invalidAPIKey {
            guard owner() == asked, let connection = connection else { return }
            set(.needsReconnect(connection))
        } catch {
            MidgarLog.notice("Seerr user not refreshed: \(error.localizedDescription)", category: .seerr)
        }
    }

    /// The address another profile on this device connected to on this server, offered first.
    package var knownAddress: URL? {
        defaults.string(forKey: knownAddressKey).flatMap(URL.init(string:))
    }

    /// Looks for Seerr where it usually runs: the address someone on this device used, then Seerr's port on each address the
    /// Plex server answers at on the home network or the tailnet.
    package func discover(serverRoutes: [URL]) async -> (URL, SeerrPublicSettings)? {
        var addresses = [knownAddress, standIn()].compactMap { $0 }
        addresses += SeerrDiscovery.candidates(serverRoutes: serverRoutes).filter { !addresses.contains($0) }
        switch await SeerrDiscovery.survey(addresses, client: client) {
        case .ready(let address, let settings): return (address, settings)
        case .needsSetup(let address): return (address, SeerrPublicSettings(initialized: false))
        case .notPlex, .notFound, .looking: return nil
        }
    }

    /// Connects to the Seerr at `address`: signs in with the viewer's Plex account, or checks `apiKey` when one is given.
    package func connect(address: URL, settings: SeerrPublicSettings, apiKey: String? = nil) async throws {
        let auth: SeerrTarget.Auth = apiKey == nil ? .plex : .apiKey
        var connection = SeerrConnection(address: address, auth: auth, title: settings.applicationTitle, partialRequests: settings.partialRequestsEnabled ?? true, remembered: [address])
        let target = target(for: connection)
        let previous = await client.current
        await followRoutes()
        isConnecting = true
        defer { isConnecting = false }
        await client.use(target, alternates: addresses(for: connection))
        if let apiKey { await client.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: target) }
        do {
            connection.user = try await client.signIn()
        } catch {
            await client.forget(target)
            if let kept = self.connection, previous != nil {
                await useBestAddress(for: kept)
            } else {
                await client.use(previous)
            }
            MidgarLog.notice("Seerr connect failed: \(error.localizedDescription)", category: .seerr)
            throw error
        }
        save(connection)
        MidgarLog.notice("Seerr connected (\(auth.rawValue))", category: .seerr)
        set(.connected(connection))
    }

    /// Signs out of Seerr and forgets the connection of the viewer watching now.
    package func disconnect() async {
        guard let connection else { return }
        if connection.auth == .plex { try? await client.sendVoid(.signOut) }
        await client.forget(target(for: connection))
        await client.use(nil)
        save(nil)
        SeerrTitles.shared.forgetAll()
        MidgarLog.notice("Seerr disconnected", category: .seerr)
        set(.disconnected)
    }

    /// Forgets the Seerr connection of every Plex account and Home profile on this device, for a Plex sign-out.
    package func forgetEveryProfile() async {
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("seerr.connection.") || $0.hasPrefix("seerr.known.") }
        for key in keys {
            if key.hasPrefix("seerr.connection."), let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(SeerrConnection.self, from: data) {
                let secretKey = "seerr." + key.dropFirst("seerr.connection.".count)
                await client.forget(SeerrTarget(address: saved.address, auth: saved.auth, secretKey: secretKey))
            }
            defaults.removeObject(forKey: key)
        }
        await client.use(nil)
        SeerrTitles.shared.forgetAll()
        set(.disconnected)
    }

    // MARK: - Observing

    package func observe(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    package func stopObserving(_ id: UUID) {
        observers[id] = nil
    }

    private func set(_ status: Status) {
        guard status != self.status else { return }
        self.status = status
        for handler in observers.values { handler() }
    }
}

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
    package var address: URL
    package var auth: SeerrTarget.Auth
    package var user: SeerrUser?
    package var title: String?
    package var partialRequests: Bool

    package init(address: URL, auth: SeerrTarget.Auth, user: SeerrUser? = nil, title: String? = nil, partialRequests: Bool = true) {
        self.address = address
        self.auth = auth
        self.user = user
        self.title = title
        self.partialRequests = partialRequests
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

    /// - Parameters:
    ///   - owner: who the connection belongs to, `currentOwner` outside tests.
    ///   - standIn: the demo's stand-in Seerr while the demo runs.
    package init(
        client: SeerrClient = .shared,
        defaults: UserDefaults = .standard,
        server: @escaping () -> String? = { ServerBootstrap.savedMachineIdentifier },
        owner: @escaping () -> String = { SeerrAccount.currentOwner },
        standIn: @escaping () -> URL? = { SeerrConfig.standInAddress }
    ) {
        self.client = client
        self.defaults = defaults
        self.server = server
        self.owner = owner
        self.standIn = standIn
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

    private func target(for connection: SeerrConnection) -> SeerrTarget {
        SeerrTarget(address: connection.address, auth: connection.auth, secretKey: "seerr.\(owner()).\(server() ?? "none")")
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
        await client.use(target(for: connection))
        set(.connected(connection))
        await refreshUser()
    }

    /// Asks Seerr who the viewer is, which also renews a session that ran out.
    package func refreshUser() async {
        guard var connection = connection else { return }
        do {
            let user = try await client.send(.me, as: SeerrUser.self)
            connection.user = user
            save(connection)
            set(.connected(connection))
        } catch SeerrError.signedOut, SeerrError.invalidAPIKey {
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
    /// Plex server answers at on the home network.
    package func discover(serverRoutes: [URL]) async -> (URL, SeerrPublicSettings)? {
        var addresses = [knownAddress, standIn()].compactMap { $0 }
        addresses += SeerrDiscovery.candidates(serverRoutes: serverRoutes).filter { !addresses.contains($0) }
        return await SeerrDiscovery.firstSeerr(among: addresses, client: client)
    }

    /// Connects to the Seerr at `address`: signs in with the viewer's Plex account, or checks `apiKey` when one is given.
    package func connect(address: URL, settings: SeerrPublicSettings, apiKey: String? = nil) async throws {
        let auth: SeerrTarget.Auth = apiKey == nil ? .plex : .apiKey
        var connection = SeerrConnection(address: address, auth: auth, title: settings.applicationTitle, partialRequests: settings.partialRequestsEnabled ?? true)
        let target = target(for: connection)
        let previous = await client.current
        await client.use(target)
        if let apiKey { await client.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: target) }
        do {
            connection.user = try await client.signIn()
        } catch {
            await client.forget(target)
            await client.use(previous)
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

import Foundation
import MidgarCore

/// The Trakt account a Plex account or Home profile connected, as Settings shows it.
package struct TraktProfile: Codable, Equatable, Sendable {
    package let username: String
    package let name: String?
    package let isVIP: Bool
    package let avatarURL: URL?

    package init(username: String, name: String?, isVIP: Bool, avatarURL: URL?) {
        self.username = username
        self.name = name
        self.isVIP = isVIP
        self.avatarURL = avatarURL
    }

    package init(_ settings: TraktUserSettings) {
        let avatar = settings.user.images?.avatar?.full.flatMap { $0.hasPrefix("http") ? URL(string: $0) : URL(string: "https://\($0)") }
        self.init(username: settings.user.username, name: settings.user.name, isVIP: settings.user.vip ?? false, avatarURL: avatar)
    }

    package var displayName: String {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return username }
        return name
    }
}

/// The viewer's choices about Trakt, kept per Plex account or Home profile alongside the token.
package struct TraktChoices: Codable, Equatable, Sendable {
    /// Send what plays to Trakt as it plays.
    package var scrobbles = true
    /// Send Mark Watched, ratings and check-ins.
    package var sendsChanges = true
    /// Marking a title unwatched also removes its plays from Trakt.
    package var removesPlaysOnUnwatch = false
    /// Another app (Trakt's own Plex sync, PlexTraktSync, a webhook) already records this profile's plays, so Crucible
    /// does not scrobble them a second time.
    package var anotherAppScrobbles = false
    /// The double-play question was answered for these servers.
    package var askedAboutPlexLink: Set<String> = []

    package init() {}
}

/// Where Trakt stands for the viewer watching now: whether this build can use Trakt, who is connected, and what they
/// chose to send. Screens observe it.
@MainActor
package final class TraktAccount {
    package static let shared = TraktAccount()

    package enum Status: Equatable, Sendable {
        /// This build carries no Trakt app.
        case unavailable
        /// A restricted Plex Home profile, which cannot connect services.
        case restricted
        case disconnected
        case connected(TraktProfile?)
        /// Trakt stopped accepting the token: the viewer must connect again.
        case needsReconnect
    }

    package private(set) var status: Status = .disconnected
    package private(set) var choices = TraktChoices()
    private var observers: [UUID: @MainActor () -> Void] = [:]
    private let tokens: TraktTokenStore
    private let defaults: UserDefaults
    private let client: TraktClient

    package init(tokens: TraktTokenStore = .shared, defaults: UserDefaults = .standard, client: TraktClient = .shared) {
        self.tokens = tokens
        self.defaults = defaults
        self.client = client
    }

    package var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    package var profile: TraktProfile? {
        if case .connected(let profile) = status { return profile }
        return nil
    }

    /// A line for the Integrations category on the first Settings screen.
    /// The status on a row already titled Trakt: the account's name, or what to do next.
    package var rowStatus: String {
        switch status {
        case .connected(let profile): return profile?.username ?? String(localized: "Connected", comment: "Trakt row status while Trakt is connected")
        case .needsReconnect: return String(localized: "Connect again", comment: "Trakt row status when Trakt signed Crucible out")
        case .disconnected, .restricted, .unavailable: return String(localized: "Off", comment: "Integrations summary when nothing is connected")
        }
    }

    package var summary: String {
        switch status {
        case .connected(let profile): return profile.map { "Trakt · \($0.username)" } ?? String(localized: "Trakt · Connected", comment: "Integrations summary while Trakt is connected")
        case .needsReconnect: return String(localized: "Trakt · Connect again", comment: "Integrations summary when Trakt signed Crucible out")
        case .disconnected, .restricted, .unavailable: return String(localized: "Off", comment: "Integrations summary when nothing is connected")
        }
    }

    private var owner: String { TraktTokenStore.currentOwner }
    private var profileKey: String { "trakt.profile.\(owner)" }
    private var choicesKey: String { "trakt.choices.\(owner)" }

    /// Reads what is saved for the viewer watching now. Call at launch and after a Home profile switch.
    package func load() async {
        choices = defaults.data(forKey: choicesKey).flatMap { try? JSONDecoder().decode(TraktChoices.self, from: $0) } ?? TraktChoices()
        guard TraktConfig.isAvailable else { return set(.unavailable) }
        if HomeProfiles.active?.isRestricted == true { return set(.restricted) }
        guard await tokens.isConnected else { return set(.disconnected) }
        let cached = defaults.data(forKey: profileKey).flatMap { try? JSONDecoder().decode(TraktProfile.self, from: $0) }
        set(.connected(cached))
        await refreshProfile()
    }

    /// Fetches who the token belongs to; a refused token turns the status into a request to connect again.
    package func refreshProfile() async {
        do {
            let settings = try await client.send(.userSettings, as: TraktUserSettings.self)
            let profile = TraktProfile(settings)
            if let data = try? JSONEncoder().encode(profile) { defaults.set(data, forKey: profileKey) }
            if isConnected { set(.connected(profile)) }
        } catch TraktError.unauthorized, TraktError.signedOut {
            set(.needsReconnect)
        } catch {
            MidgarLog.notice("Trakt profile not refreshed: \(error.localizedDescription)", category: .trakt)
        }
    }

    /// Stores the token a sign-in produced and reads who it belongs to.
    package func connect(with token: TraktToken) async {
        await tokens.save(token)
        MidgarLog.notice("Trakt connected", category: .trakt)
        set(.connected(nil))
        await refreshProfile()
    }

    /// Revokes the token with Trakt and forgets everything Crucible kept for this account.
    package func disconnect() async {
        if let token = await tokens.token {
            try? await client.sendVoid(.revoke(accessToken: token.accessToken))
        }
        await forgetEverything()
        MidgarLog.notice("Trakt disconnected", category: .trakt)
    }

    /// Forgets the token, the account, the matches and the queue, without telling Trakt (the Plex account signed out).
    package func forgetEverything() async {
        await tokens.clear()
        defaults.removeObject(forKey: profileKey)
        defaults.removeObject(forKey: choicesKey)
        choices = TraktChoices()
        TraktOutbox.shared.clear(owner: owner)
        set(TraktConfig.isAvailable ? .disconnected : .unavailable)
    }

    /// Forgets the Trakt link of every Plex account and Home profile on this device, for a Plex sign-out.
    package func forgetEveryProfile() async {
        let prefixes = ["trakt.profile.", "trakt.choices."]
        let owners = Set(defaults.dictionaryRepresentation().keys.compactMap { key in
            prefixes.first(where: key.hasPrefix).map { String(key.dropFirst($0.count)) }
        })
        await tokens.clearAll(owners: Array(owners) + ["standin.account"])
        for owner in owners {
            for prefix in prefixes { defaults.removeObject(forKey: prefix + owner) }
        }
        choices = TraktChoices()
        TraktResolver.shared.forgetAll()
        TraktOutbox.shared.clear()
        set(TraktConfig.isAvailable ? .disconnected : .unavailable)
    }

    package func update(_ change: (inout TraktChoices) -> Void) {
        change(&choices)
        if let data = try? JSONEncoder().encode(choices) { defaults.set(data, forKey: choicesKey) }
        notify()
    }

    /// Trakt refused the token outright; the viewer is asked to connect again.
    package func tokenRefused() {
        guard isConnected else { return }
        set(.needsReconnect)
    }

    // MARK: - Trakt's own Plex link

    /// Whether Trakt's own Plex scrobbler or sync records plays for this account, which would count every play Crucible
    /// sends a second time.
    package func traktRecordsPlexPlays() async -> Bool {
        guard isConnected, let settings = try? await client.send(.plexSettings, as: TraktPlexSettings.self),
              settings.connection?.connected == true else { return false }
        let scrobbler = settings.scrobbler?.toggles?.recordsPlays == true
        let sync = settings.sync?.configured == true && settings.sync?.toggles?.recordsPlays == true
        return scrobbler || sync
    }

    /// The viewer chose Crucible to record plays: Trakt's real-time Plex scrobbler is turned off, its other settings kept.
    package func letCrucibleRecordPlays(server: String) async throws {
        try await client.sendVoid(.disablePlexScrobbler)
        update { $0.anotherAppScrobbles = false; $0.askedAboutPlexLink.insert(server) }
    }

    /// The viewer chose Trakt's own Plex link to keep recording plays.
    package func letTraktRecordPlays(server: String) {
        update { $0.anotherAppScrobbles = true; $0.askedAboutPlexLink.insert(server) }
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

    nonisolated private static let linkedLock = NSLock()
    nonisolated(unsafe) private static var linked = false

    /// Whether the viewer watching now has Trakt connected, as last loaded, readable anywhere without the Keychain.
    package nonisolated static var isLinked: Bool { linkedLock.withLock { linked } }

    private func set(_ status: Status) {
        let linked: Bool
        switch status {
        case .connected, .needsReconnect: linked = true
        case .disconnected, .restricted, .unavailable: linked = false
        }
        Self.linkedLock.withLock { Self.linked = linked }
        guard status != self.status else { return }
        self.status = status
        notify()
    }

    private func notify() {
        for handler in observers.values { handler() }
    }
}

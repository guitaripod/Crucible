import Foundation
import MidgarCore

/// Where a Trakt token is kept: one Keychain item per Plex account or Home profile, so each person who watches links their
/// own Trakt account.
package struct TraktTokenKeychain: Sendable {
    package var load: @Sendable (_ key: String) -> TraktToken?
    package var save: @Sendable (_ key: String, _ token: TraktToken) -> Void
    package var delete: @Sendable (_ key: String) -> Void

    package init(
        load: @escaping @Sendable (_ key: String) -> TraktToken?,
        save: @escaping @Sendable (_ key: String, _ token: TraktToken) -> Void,
        delete: @escaping @Sendable (_ key: String) -> Void
    ) {
        self.load = load
        self.save = save
        self.delete = delete
    }

    package static let live = TraktTokenKeychain(
        load: { key in
            guard let text = KeychainHelper.load(key: key), let data = text.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(TraktToken.self, from: data)
        },
        save: { key, token in
            guard let data = try? JSONEncoder().encode(token), let text = String(data: data, encoding: .utf8) else { return }
            KeychainHelper.save(key: key, value: text)
        },
        delete: { key in KeychainHelper.delete(key: key) }
    )

    /// An in-memory store for tests and the demo.
    package static func memory() -> TraktTokenKeychain {
        let box = TokenBox()
        return TraktTokenKeychain(
            load: { key in box.get(key) },
            save: { key, token in box.set(key, token) },
            delete: { key in box.set(key, nil) }
        )
    }

    private final class TokenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [String: TraktToken] = [:]
        func get(_ key: String) -> TraktToken? { lock.withLock { tokens[key] } }
        func set(_ key: String, _ token: TraktToken?) { lock.withLock { tokens[key] = token } }
    }
}

/// The viewer's Trakt token. Refreshes happen one at a time, and each new pair is saved before the token is handed out: a
/// refresh token works once, so losing the answer to a refresh would sign the viewer out.
package actor TraktTokenStore {
    package static let shared = TraktTokenStore()

    private let keychain: TraktTokenKeychain
    private let owner: @Sendable () -> String
    private var refreshing: Task<TraktToken, Error>?

    package init(keychain: TraktTokenKeychain = .live, owner: @escaping @Sendable () -> String = { TraktTokenStore.currentOwner }) {
        self.keychain = keychain
        self.owner = owner
    }

    /// Who the token belongs to: the Home profile watching now, or the account itself.
    package nonisolated static var currentOwner: String {
        (TraktConfig.isStandIn ? "standin." : "") + (HomeProfiles.active?.id ?? "account")
    }

    private static let keyPrefix = "trakt.token."

    /// Whether the viewer watching now has a Trakt token, read straight from the Keychain for places that cannot wait.
    package nonisolated static var hasToken: Bool {
        KeychainHelper.load(key: keyPrefix + currentOwner) != nil
    }
    private var key: String { Self.keyPrefix + owner() }

    package var token: TraktToken? { keychain.load(key) }

    package var isConnected: Bool { token != nil }

    package func save(_ token: TraktToken) {
        keychain.save(key, token)
    }

    package func clear() {
        refreshing?.cancel()
        refreshing = nil
        keychain.delete(key)
    }

    /// Forgets the tokens of every profile on this device, for a Plex sign-out.
    package func clearAll(owners: [String]) {
        for owner in Set(owners + ["account"]) { keychain.delete(Self.keyPrefix + owner) }
    }

    /// The access token to send, refreshed first when it is within a day of running out.
    package func validAccessToken(refresh: @escaping @Sendable (String) async throws -> TraktToken) async throws -> String {
        guard let token else { throw TraktError.signedOut }
        guard token.needsRefresh() else { return token.accessToken }
        return try await runRefresh(from: token, refresh: refresh).accessToken
    }

    /// Refreshes now because Trakt refused the token it has.
    package func forceRefresh(refresh: @escaping @Sendable (String) async throws -> TraktToken) async throws -> String {
        guard let token else { throw TraktError.signedOut }
        return try await runRefresh(from: token, refresh: refresh).accessToken
    }

    private func runRefresh(from token: TraktToken, refresh: @escaping @Sendable (String) async throws -> TraktToken) async throws -> TraktToken {
        if let refreshing { return try await refreshing.value }
        let key = key
        let keychain = keychain
        let task = Task<TraktToken, Error> {
            do {
                let fresh = try await refresh(token.refreshToken)
                keychain.save(key, fresh)
                return fresh
            } catch TraktError.unauthorized {
                MidgarLog.error("Trakt refused the refresh token; the viewer must connect again", category: .trakt)
                keychain.delete(key)
                throw TraktError.unauthorized
            }
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }
}

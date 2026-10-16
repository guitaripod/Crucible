import Foundation

/// The Tailscale API access token the person may give Crucible so it can list their tailnet's
/// computers and find a server whose name does not match its Plex name. Optional, kept in the
/// Keychain, used only to read the device list.
package enum TailnetAccess {
    package enum State: Equatable, Sendable {
        case none
        case saved
        case rejected
    }

    private static let tokenKey = "tailscale_api_token"
    private static let rejectedKey = "tailscale_token_rejected"

    package static var token: String? {
        guard let stored = KeychainHelper.load(key: tokenKey), !stored.isEmpty else { return nil }
        return stored
    }

    package static var state: State {
        guard token != nil else { return .none }
        return UserDefaults.standard.bool(forKey: rejectedKey) ? .rejected : .saved
    }

    package static func save(_ token: String) {
        KeychainHelper.save(key: tokenKey, value: token)
        UserDefaults.standard.removeObject(forKey: rejectedKey)
    }

    package static func clear() {
        KeychainHelper.delete(key: tokenKey)
        UserDefaults.standard.removeObject(forKey: rejectedKey)
    }

    /// Tailscale refused the token (expired or revoked). It stays stored so the person can see it
    /// needs replacing, but discovery stops sending it.
    package static func markRejected() {
        UserDefaults.standard.set(true, forKey: rejectedKey)
    }
}

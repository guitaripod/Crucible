import Foundation

/// What every platform does once plex.tv hands over an account token.
package enum PlexSignIn {
    /// Stores the token in the Keychain and refreshes the account name shown on the You tab in the
    /// background.
    package static func complete(token: String) {
        ServerBootstrap.saveToken(token)
        Task { await PlexAccountName.refresh(token: token) }
    }
}

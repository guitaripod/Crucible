import Foundation

/// The invitation a title page shows where Trakt's community would be, while Trakt is not connected: what connecting adds to this
/// title, Connect Trakt, and Not Now, which puts it away on this device for good. Settings keeps the way to Trakt either way.
package struct TraktInvite: Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
        /// Trakt was never connected.
        case connect
        /// Trakt signed Crucible out, so the scores and the community stopped.
        case reconnect
    }

    package let kind: Kind
    package let title: String
    package let message: String
    package let action: String

    /// The invitation due for `status`, or nil where none is: Trakt connected, not in this build, a restricted Home profile, or put
    /// away with Not Now.
    package static func due(status: TraktAccount.Status, dismissed: Bool, titleName: String) -> TraktInvite? {
        guard !dismissed else { return nil }
        switch status {
        case .disconnected:
            return TraktInvite(kind: .connect, title: WelcomeCopy.traktInviteTitle, message: message(titleName), action: TraktCopy.connect)
        case .needsReconnect:
            return TraktInvite(kind: .reconnect, title: TraktCopy.name, message: TraktCopy.needsReconnect, action: TraktCopy.reconnect)
        case .connected, .unavailable, .restricted:
            return nil
        }
    }

    /// The invitation for the viewer watching now, read from the shared account and ledger.
    @MainActor
    package static func current(titleName: String, account: TraktAccount = .shared, ledger: WelcomeLedger = .shared) -> TraktInvite? {
        due(status: account.status, dismissed: ledger.isTraktInviteDismissed, titleName: titleName)
    }

    package static let notNow = String(localized: "Not Now")

    private static func message(_ titleName: String) -> String {
        guard !titleName.isEmpty else {
            return String(localized: "Connect Trakt to see its score beside IMDb and Rotten Tomatoes, the reviews, and what people say about this title.", comment: "Title page invitation to connect Trakt, when the title has no name yet")
        }
        return String(localized: "Connect Trakt to see its score beside IMDb and Rotten Tomatoes, the reviews, and what people say about \(titleName).", comment: "Title page invitation to connect Trakt, naming the film or show")
    }
}

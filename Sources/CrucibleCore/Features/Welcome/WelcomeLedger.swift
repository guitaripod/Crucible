import Foundation

/// What Crucible remembers about a viewer's first steps on this device: whether the welcome is still owed, and whether the viewer put
/// the Trakt invitation on title pages away. It lives in the defaults alone, so deleting the app, or anything else that clears its
/// data, makes the next library a first one again, while an update from a version that had no welcome counts as already welcomed.
/// Earlier versions leave nothing behind a sign-out that tells them apart from a new install (the keychain outlives a reinstall), so
/// an update that finds no server saved, because its viewer had signed out, welcomes the next library they open like a new one.
package final class WelcomeLedger: @unchecked Sendable {
    package static let shared = WelcomeLedger()

    private static let stateKey = "welcome.v1.state"
    private static let traktInviteKey = "welcome.v1.traktInviteDismissed"
    /// A key every earlier version wrote once a server was chosen. Finding it on the first launch with a ledger means an update, not a
    /// new install.
    private static let earlierInstallKey = "plex_server_uri"

    private enum State: String {
        case owed
        case shown
    }

    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Decides once per install whether the welcome is owed. Call at launch, before a sign-in can save a server.
    package func settleAtLaunch() {
        guard defaults.string(forKey: Self.stateKey) == nil else { return }
        let updated = defaults.object(forKey: Self.earlierInstallKey) != nil
        defaults.set((updated ? State.shown : State.owed).rawValue, forKey: Self.stateKey)
    }

    /// True from a new install until the welcome has been shown.
    package var isWelcomeOwed: Bool {
        defaults.string(forKey: Self.stateKey) == State.owed.rawValue
    }

    package func welcomeWasShown() {
        defaults.set(State.shown.rawValue, forKey: Self.stateKey)
    }

    /// The viewer answered Not Now to the Trakt invitation on a title page; it does not come back on this device.
    package var isTraktInviteDismissed: Bool {
        defaults.bool(forKey: Self.traktInviteKey)
    }

    package func dismissTraktInvite() {
        defaults.set(true, forKey: Self.traktInviteKey)
    }

    #if DEBUG
    /// Stages a debug launch that starts as a new install (`CRUCIBLE_FRESH=1`): the welcome is owed only when the launch asks for it
    /// (`CRUCIBLE_WELCOME=1`), so UI tests that sign in from scratch never meet it unless they test it, and the Trakt invitation is back.
    package func stageFreshInstall(owesWelcome: Bool) {
        defaults.set((owesWelcome ? State.owed : State.shown).rawValue, forKey: Self.stateKey)
        defaults.removeObject(forKey: Self.traktInviteKey)
    }
    #endif
}

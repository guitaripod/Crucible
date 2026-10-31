import Foundation
import MidgarCore

/// The parts of a session reset that live above Core: the statistics database, the image cache,
/// the Top Shelf announcement and, on the iPhone, downloads. Each platform builds its own value
/// once and hands it to `AccountSessionReset`.
@MainActor
package struct AccountSessionCollaborators {
    package var resetStats: @MainActor () -> Void
    package var clearImageCache: @MainActor () -> Void
    package var topShelfDidChange: @MainActor () -> Void
    package var resetDownloads: @MainActor () -> Void

    package init(
        resetStats: @escaping @MainActor () -> Void,
        clearImageCache: @escaping @MainActor () -> Void,
        topShelfDidChange: @escaping @MainActor () -> Void = {},
        resetDownloads: @escaping @MainActor () -> Void = {}
    ) {
        self.resetStats = resetStats
        self.clearImageCache = clearImageCache
        self.topShelfDidChange = topShelfDidChange
        self.resetDownloads = resetDownloads
    }
}

/// The one place that forgets what belongs to an account or to a server: sign out wipes both, and
/// connecting to a different server wipes what was bound to the previous one (statistics, Home
/// cache, library choices, recent searches, route status, images, Top Shelf) so nothing of one
/// server is ever shown against another.
///
/// Call `reconcileServer` when a launch starts: it compares the server about to be used with the
/// one the saved state belongs to, which covers Switch Server and Add Server by Address on every
/// platform without each caller having to know about it.
@MainActor
package enum AccountSessionReset {
    private static let sessionMachineKey = "plex_session_machine_id"

    /// Forgets the account, the server and everything bound to either.
    package static func signOut(_ collaborators: AccountSessionCollaborators, defaults: UserDefaults = .standard) {
        collaborators.resetDownloads()
        resetServerBoundState(collaborators)
        RememberedServerAddress.forget(in: defaults)
        ServerBootstrap.clear()
        defaults.removeObject(forKey: sessionMachineKey)
    }

    /// Records the server the saved state now belongs to. When it is a different server than the
    /// one the state was built for, forgets everything bound to the old one and returns true. A
    /// first launch with no record only adopts the server.
    @discardableResult
    package static func reconcileServer(
        machineIdentifier: String,
        _ collaborators: AccountSessionCollaborators,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let previous = defaults.string(forKey: sessionMachineKey)
        defaults.set(machineIdentifier, forKey: sessionMachineKey)
        guard let previous, previous != machineIdentifier else { return false }
        MidgarLog.notice("Server changed; resetting state bound to the previous server", category: .lifecycle)
        resetServerBoundState(collaborators)
        return true
    }

    private static func resetServerBoundState(_ collaborators: AccountSessionCollaborators) {
        collaborators.resetStats()
        HomeSnapshotStore.destroy()
        collaborators.clearImageCache()
        LibraryVisibility.forgetServerLibraries()
        Preferences.recentSearches = []
        YouConnectionStatus.shared.reset()
        TopShelfUpdater.clear(notify: collaborators.topShelfDidChange)
    }
}

import CrucibleCore
import TVServices

/// Keeps the Top Shelf current for the signed-in session: the coordinator activates it with the
/// session's API client on launch and calls `refresh()` when the app returns to the foreground;
/// the player calls it when playback ends. Each refresh fetches Home's hubs, rewrites the
/// snapshot in the App Group when something changed and tells the system.
@MainActor
enum TVTopShelfRefresher {
    private static var session: (api: APIClient, machineIdentifier: String)?
    private static var task: Task<Void, Never>?

    static func activate(api: APIClient, machineIdentifier: String) {
        session = (api, machineIdentifier)
        refresh()
    }

    /// Does nothing without an active session. A refresh already running is replaced.
    static func refresh() {
        guard let session else { return }
        task?.cancel()
        task = Task {
            await TopShelfUpdater.refresh(api: session.api, machineIdentifier: session.machineIdentifier) {
                TVTopShelfContentProvider.topShelfContentDidChange()
            }
        }
    }

    /// Ends the session and cancels a refresh in flight, so it cannot write after the snapshot is
    /// cleared. Clearing the snapshot itself is part of `AccountSessionReset`.
    static func deactivate() {
        task?.cancel()
        task = nil
        session = nil
    }
}

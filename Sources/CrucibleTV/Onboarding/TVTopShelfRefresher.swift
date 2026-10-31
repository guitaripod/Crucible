import CrucibleCore
import MidgarCore
import TVServices

/// Keeps the Top Shelf current for the signed-in session: the coordinator activates it with the
/// session's API client on launch and calls `refresh()` when the app returns to the foreground;
/// the player calls it when playback ends. Each refresh fetches Home's hubs, rewrites the
/// snapshot in the App Group when something changed and tells the system.
///
/// Top Shelf is a Crucible Pro feature. A free install publishes nothing and empties what an earlier
/// version or an ended plan left, so the extension returns no content; a status the store has not
/// answered yet changes nothing. The demo never publishes: its titles are fictional and must not reach the real Home screen, so
/// while it runs the Top Shelf is kept empty. The refresher follows `ProAccess`, so turning Pro on fills the
/// Top Shelf at once and losing it empties it.
@MainActor
enum TVTopShelfRefresher {
    private static var session: (api: APIClient, machineIdentifier: String)?
    private static var task: Task<Void, Never>?
    private static var proObserver: UUID?

    static func activate(api: APIClient, machineIdentifier: String) {
        session = (api, machineIdentifier)
        MidgarLog.info(TopShelfStore.shared.diagnostics.logSummary, category: .persistence)
        observePro()
        refresh()
    }

    /// Does nothing without an active session. A refresh already running is replaced.
    static func refresh() {
        guard let session else { return }
        switch action {
        case .publish:
            publish(session)
        case .clear:
            clear()
        case .wait:
            break
        }
    }

    private static var action: ProTVTopShelf.Action {
        DemoMode.shared.isActive ? .clear : ProTVTopShelf.action(for: ProAccess.shared.status)
    }

    /// Ends the session and cancels a refresh in flight, so it cannot write after the snapshot is
    /// cleared. Clearing the snapshot itself is part of `AccountSessionReset`.
    static func deactivate() {
        task?.cancel()
        task = nil
        session = nil
        if let proObserver { ProAccess.shared.stopObserving(proObserver) }
        proObserver = nil
    }

    private static func publish(_ session: (api: APIClient, machineIdentifier: String)) {
        task?.cancel()
        task = Task {
            await TopShelfUpdater.refresh(api: session.api, machineIdentifier: session.machineIdentifier) {
                TVTopShelfContentProvider.topShelfContentDidChange()
            }
        }
    }

    private static func clear() {
        task?.cancel()
        task = nil
        TopShelfUpdater.clear {
            TVTopShelfContentProvider.topShelfContentDidChange()
        }
    }

    private static func observePro() {
        guard proObserver == nil else { return }
        proObserver = ProAccess.shared.observe { _ in refresh() }
    }
}

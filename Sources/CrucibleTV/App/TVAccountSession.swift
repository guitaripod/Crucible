import CrucibleCore
import CrucibleDesign
import CrucibleStats
import TVServices

extension AccountSessionCollaborators {
    /// What a session reset touches above Core on Apple TV: statistics, the image cache and the
    /// Top Shelf announcement. There are no downloads.
    @MainActor
    static var tv: AccountSessionCollaborators {
        AccountSessionCollaborators(
            resetStats: { StatsManager.shared.handleSignOut() },
            clearImageCache: { Task { await ImageLoader.shared.clearCache() } },
            topShelfDidChange: { TVTopShelfContentProvider.topShelfContentDidChange() }
        )
    }
}

/// The coordinator seen through a weak reference, so the environment handed to every screen
/// cannot keep the coordinator, and through it the window, alive.
@MainActor
final class TVWeakSession: TVSessionActions {
    private weak var target: (any TVSessionActions)?

    init(_ target: any TVSessionActions) {
        self.target = target
    }

    func switchServer() { target?.switchServer() }
    func signOut() { target?.signOut() }
    func leaveDemo() { target?.leaveDemo() }
    func reconnect() { target?.reconnect() }
}

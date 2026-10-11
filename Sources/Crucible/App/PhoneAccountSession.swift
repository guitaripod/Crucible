import CrucibleCore
import CrucibleDesign
import CrucibleStats

extension AccountSessionCollaborators {
    /// What a session reset touches above Core on iPhone: statistics, the image cache and, when
    /// signing out, downloads. Switching server keeps downloads, which stay playable offline.
    @MainActor
    static var phone: AccountSessionCollaborators {
        AccountSessionCollaborators(
            resetStats: { StatsManager.shared.handleSignOut() },
            clearImageCache: { Task { await ImageLoader.shared.clearCache() } },
            resetDownloads: { DownloadManager.shared.handleSignOut() }
        )
    }
}

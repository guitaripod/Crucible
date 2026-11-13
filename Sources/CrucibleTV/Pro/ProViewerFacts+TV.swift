import CrucibleCore
import CrucibleStats

extension ProViewerFacts {
    /// What this Apple TV knows about the viewer as the paywall opens: the mirrored watch history and the titles stopped partway
    /// through here. The demo's library is fictional, so it says nothing about anyone.
    @MainActor
    static var live: ProViewerFacts {
        #if DEBUG
        if let staged = ProViewerFacts.staged() { return staged }
        #endif
        guard !DemoMode.shared.isActive else { return ProViewerFacts() }
        return ProViewerFacts(
            history: StatsManager.shared.viewerHistory,
            titlesInProgress: PlaybackResumeStore.shared.inProgressCount()
        )
    }
}

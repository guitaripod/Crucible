import CrucibleCore
import CrucibleStats

extension ProViewerFacts {
    /// What this iPhone knows about the viewer as the Pro sheet opens: the mirrored watch history and the titles downloaded here.
    /// The demo's library is fictional, so it says nothing about anyone.
    @MainActor
    static var live: ProViewerFacts {
        #if DEBUG
        if let staged = ProViewerFacts.staged() { return staged }
        #endif
        guard !DemoMode.shared.isActive else { return ProViewerFacts() }
        return ProViewerFacts(
            history: StatsManager.shared.viewerHistory,
            downloadedTitles: DownloadManager.shared.items.filter { $0.state == .completed }.count
        )
    }
}

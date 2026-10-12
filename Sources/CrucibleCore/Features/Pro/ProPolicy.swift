import Foundation

/// The rules that decide what the free app does and what needs Pro.
package enum ProPolicy {
    /// A free install downloads one title at a time, and never a batch.
    package static let freeDownloadLimit = 1

    package enum DownloadDecision: Equatable, Sendable {
        case allow
        case requiresPro
    }

    /// `activeDownloads` counts the titles queued or downloading right now; `adding` is how many the user asked for.
    package static func downloadDecision(isPro: Bool, activeDownloads: Int, adding: Int = 1) -> DownloadDecision {
        guard !isPro else { return .allow }
        return activeDownloads + adding <= freeDownloadLimit ? .allow : .requiresPro
    }

    /// Keeping the next episodes downloaded fills the queue without being asked, so it is Pro.
    package static func allowsKeepNextEpisodes(isPro: Bool) -> Bool { isPro }
}

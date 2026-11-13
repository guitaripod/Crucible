import Foundation

/// What Crucible Pro unlocks, in the order the paywall lists it. Playback, browsing, search and the
/// whole Apple TV app are never in this list.
package enum ProFeature: String, CaseIterable, Sendable {
    case whatToWatch
    case previouslyOn
    case unlimitedDownloads
    case fullStatistics
    case yearInReviewPoster
    case topShelf
    case manageRequests

    package var title: String {
        switch self {
        case .whatToWatch: return WatchCopy.title
        case .previouslyOn: return CompanionCopy.previouslyOn
        case .unlimitedDownloads: return String(localized: "Unlimited downloads")
        case .fullStatistics: return String(localized: "Full Statistics")
        case .yearInReviewPoster: return String(localized: "Year in Review poster")
        case .topShelf: return String(localized: "Top Shelf")
        case .manageRequests: return String(localized: "Manage Requests", comment: "Pro feature: approve and decline Seerr requests")
        }
    }

    package var summary: String {
        switch self {
        case .whatToWatch: return String(localized: "Say what you feel like and get picks from your own library, with a reason for each.", comment: "Pro feature summary for What to Watch")
        case .previouslyOn: return String(localized: "A recap of your last episodes, written before you press play.", comment: "Pro feature summary for Previously On")
        case .unlimitedDownloads: return String(localized: "Download whole seasons, queue as many titles as you like and keep the next episodes ready.")
        case .fullStatistics: return String(localized: "Every range, the library filter, patterns, binges and taste, built from your own Plex history and, with Trakt connected, everything you watch elsewhere.", comment: "Pro feature summary for Full Statistics")
        case .yearInReviewPoster: return String(localized: "Preview and share your year as a Story or Square poster.")
        case .topShelf: return String(localized: "Continue Watching and Up Next on the Apple TV Home screen.")
        case .manageRequests: return String(localized: "Approve, decline and retry everyone's Seerr requests from the couch.", comment: "Pro feature summary for managing Seerr requests")
        }
    }

    package var symbol: String {
        switch self {
        case .whatToWatch: return "wand.and.stars"
        case .previouslyOn: return "text.quote"
        case .unlimitedDownloads: return "arrow.down.circle"
        case .fullStatistics: return "chart.bar.xaxis"
        case .yearInReviewPoster: return "sparkles.rectangle.stack"
        case .topShelf: return "tv"
        case .manageRequests: return "tray.full"
        }
    }

    /// The features worth showing on the current platform: downloads exist only on the iPhone and Top Shelf only on Apple TV.
    /// Managing requests shows only to someone who approves requests on a connected Seerr, or who reached for it.
    /// What to Watch and Previously On show where Crucible has its hosted AI, which a source build and the demo do not.
    package static func listed(isTV: Bool = AppPlatform.isTV, includingRequests: Bool = false, includingHosted: Bool = HostedBrain.isAvailable) -> [ProFeature] {
        allCases.filter { feature in
            switch feature {
            case .whatToWatch, .previouslyOn: return includingHosted
            case .unlimitedDownloads: return !isTV
            case .topShelf: return isTV
            case .fullStatistics, .yearInReviewPoster: return true
            case .manageRequests: return includingRequests
            }
        }
    }
}

import Foundation

/// What the Top Shelf does for the current Pro status. Top Shelf is a Pro feature: free installs publish nothing, so the
/// extension returns no content.
package enum ProTVTopShelf {
    package enum Action: Equatable, Sendable {
        case publish
        case clear
        case wait
    }

    /// Pro publishes; a free install clears whatever an earlier version or an expired plan left. An unanswered store waits,
    /// so a Pro user's Top Shelf is not wiped and rewritten while the first answer is on its way.
    package static func action(for status: ProStatus) -> Action {
        switch status {
        case .pro: return .publish
        case .free: return .clear
        case .unknown: return .wait
        }
    }
}

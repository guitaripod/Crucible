import Foundation
import MidgarCore

/// Takes a title off Continue Watching and Up Next on the server, the way Plex's own apps do: the title keeps its watched state
/// and its position, it only stops being offered until it is played again.
package enum ContinueWatchingRemoval {
    /// The menu item names the row the card sits in, so an Up Next episode the viewer never meant to start can be sent away
    /// from there without marking it watched.
    package static func title(for bucket: HomeBucket) -> String {
        bucket == .upNext
            ? String(localized: "Remove from Up Next", comment: "Menu item that takes an episode off the Up Next row without marking it watched")
            : String(localized: "Remove from Continue Watching", comment: "Menu item that takes a title off the Continue Watching and Up Next rows without marking it watched")
    }
    package static let symbol = "minus.circle"

    /// Cards in the rows Plex calls Continue Watching can leave them; Recently Added is not one of those rows.
    package static func applies(to item: PlexMetadata, in bucket: HomeBucket) -> Bool {
        guard ["movie", "episode", "season", "show"].contains(item.mediaType) else { return false }
        switch bucket {
        case .hero, .continueWatching, .upNext: return true
        case .recentlyAdded: return false
        }
    }

    /// Asks the server to drop the title; a refusal is logged and rethrown so the screen can say so.
    package static func remove(ratingKey: String, api: APIClient) async throws {
        do {
            try await api.requestConfirmed(.removeFromContinueWatching(ratingKey: ratingKey))
        } catch {
            MidgarLog.error("Remove from Continue Watching ratingKey=\(ratingKey) failed: \(error.localizedDescription)", category: .networking)
            throw error
        }
    }

    package static let failureTitle = String(localized: "Couldn’t Remove", comment: "Alert title when the server refused to take a title off Continue Watching")
    package static let failureMessage = String(localized: "The server didn’t take this title off Continue Watching. Try again in a moment.", comment: "Alert message when the server refused to take a title off Continue Watching")
}

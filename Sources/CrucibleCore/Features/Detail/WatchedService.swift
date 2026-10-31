import Foundation
import MidgarCore

/// Marks a movie, episode, season or show watched or unwatched.
package enum WatchedService {
    /// The title of the action that flips `isWatched`, the item's current state: Mark Watched for an unwatched title.
    package static func title(isWatched: Bool) -> String {
        isWatched ? "Mark Unwatched" : "Mark Watched"
    }

    /// Scrobbles or unscrobbles `ratingKey`, then drops the container cache so the reload the caller
    /// performs next (the cache lives 120 seconds) shows the new watched state. Failures are logged and rethrown.
    package static func setWatched(_ watched: Bool, ratingKey: String, api: APIClient) async throws {
        do {
            if watched {
                try await api.requestConfirmed(.scrobble(ratingKey: ratingKey))
            } else {
                try await api.requestConfirmed(.unscrobble(ratingKey: ratingKey))
            }
            await api.invalidateCache()
        } catch {
            MidgarLog.error("Mark watched=\(watched) failed ratingKey=\(ratingKey): \(error.localizedDescription)", category: .networking)
            throw error
        }
    }
}

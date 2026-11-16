import Foundation
import MidgarCore

/// Marks a movie, episode, season or show watched or unwatched.
package enum WatchedService {
    /// The title of the action that flips `isWatched`, the item's current state: Mark Watched for an unwatched title.
    package static func title(isWatched: Bool) -> String {
        isWatched ? String(localized: "Mark Unwatched") : String(localized: "Mark Watched")
    }

    /// Scrobbles or unscrobbles `ratingKey`, then drops the container cache so the reload the caller performs next shows the
    /// new watched state, and tells every other screen, in every window, that the title changed. Failures are logged and
    /// rethrown.
    package static func setWatched(_ watched: Bool, ratingKey: String, api: APIClient) async throws {
        do {
            if watched {
                try await api.requestConfirmed(.scrobble(ratingKey: ratingKey))
            } else {
                try await api.requestConfirmed(.unscrobble(ratingKey: ratingKey))
            }
            await api.invalidateCache()
            await MainActor.run {
                Integrations.watchedChanged(ratingKey, watched: watched, api: api)
                ServerStateSync.shared.post(.titles([ratingKey]))
            }
        } catch {
            MidgarLog.error("Mark watched=\(watched) failed ratingKey=\(ratingKey): \(error.localizedDescription)", category: .networking)
            throw error
        }
    }
}

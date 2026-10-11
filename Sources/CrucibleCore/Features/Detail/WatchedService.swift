import Foundation

/// Marks a movie, episode, season or show watched or unwatched.
package enum WatchedService {
    /// Scrobbles or unscrobbles `ratingKey`, then drops the container cache so the reload the caller
    /// performs next (the cache lives 120 seconds) shows the new watched state. Failures are logged and rethrown.
    package static func setWatched(_ watched: Bool, ratingKey: String, api: APIClient) async throws {
        do {
            if watched {
                try await api.requestVoid(.scrobble(ratingKey: ratingKey))
            } else {
                try await api.requestVoid(.unscrobble(ratingKey: ratingKey))
            }
            await api.invalidateCache()
        } catch {
            AppLogger.error("Mark watched=\(watched) failed ratingKey=\(ratingKey): \(error.localizedDescription)", .networking)
            throw error
        }
    }
}

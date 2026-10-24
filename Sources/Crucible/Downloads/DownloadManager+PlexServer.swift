import CrucibleCore
import Foundation

extension DownloadManager {
    /// Downloads mint a fresh Plex transcode session per resolve; tell the server to reap it as soon
    /// as the job ends (complete/fail/pause/delete/re-resolve) instead of leaving it to idle-timeout.
    func stopTranscodeSession(_ ratingKey: String) {
        guard let sessionID = transcodeSessions.removeValue(forKey: ratingKey) else { return }
        stopTranscode(sessionID: sessionID)
    }

    /// Covers the mid-resolve teardown race: a pause/delete may stop-and-forget the session while the
    /// playlist fetches are still in flight and about to (re)start it server-side, so bail-out paths
    /// stop the planned session directly instead of relying on the (already cleared) map entry.
    func abandonTranscodeSession(_ sessionID: String, ratingKey: String) {
        if transcodeSessions[ratingKey] == sessionID { transcodeSessions[ratingKey] = nil }
        stopTranscode(sessionID: sessionID)
    }

    private func stopTranscode(sessionID: String) {
        guard let cfg = config else { return }
        let api = APIClient(baseURL: cfg.baseURL, token: cfg.token)
        Task.detached(priority: .utility) {
            try? await api.requestVoid(.stopTranscode(session: sessionID))
        }
    }

    /// Marks a download watched on the server the moment local playback crosses the watched
    /// threshold, so On Deck stays honest even when the item is then auto-deleted.
    func scrobbleBestEffort(_ ratingKey: String) {
        guard let cfg = config else { return }
        let api = APIClient(baseURL: cfg.baseURL, token: cfg.token)
        Task.detached(priority: .utility) {
            try? await api.requestVoid(.scrobble(ratingKey: ratingKey))
        }
    }

    func fetchPoster(path: String, ratingKey: String, baseURL: URL, token: String) {
        guard let url = DownloadResolver.posterURL(baseURL: baseURL, token: token, path: path, width: 400, height: 600) else { return }
        Task { [store] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            for (key, value) in PlexHeaders.allHeaders(token: token) {
                request.setValue(value, forHTTPHeaderField: key)
            }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return }
            await store.savePoster(data, ratingKey: ratingKey)
        }
    }
}

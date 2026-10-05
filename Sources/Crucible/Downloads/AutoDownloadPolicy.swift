import Foundation
import UIKit

/// "Keep next N downloaded": a per-show setting that keeps the next unwatched episodes queued or
/// downloaded as the user watches. Settings live in UserDefaults keyed by the show's rating key.
@MainActor
final class AutoDownloadPolicy {
    static let shared = AutoDownloadPolicy()
    static let defaultCount = 3

    struct Setting: Codable, Equatable {
        var count: Int
        var quality: Int
    }

    private static let storageKey = "autoDownloadPolicies"
    private static let observerThrottle: TimeInterval = 30

    private var observerToken: UUID?
    private var latestAPI: APIClient?
    private var isEvaluating = false
    private var needsAnotherPass = false
    private var lastFinishedAt: Date?

    static func setting(forShow showRatingKey: String) -> Setting? {
        let all = loadAll()
        guard let setting = all[showRatingKey], setting.count > 0 else { return nil }
        return setting
    }

    static func count(forShow showRatingKey: String) -> Int {
        setting(forShow: showRatingKey)?.count ?? 0
    }

    /// Enables the policy for a show with `count` episodes ahead, or removes it when `count` is 0.
    static func set(count: Int, quality: DownloadQuality, forShow showRatingKey: String) {
        var all = loadAll()
        if count > 0 {
            all[showRatingKey] = Setting(count: count, quality: quality.rawValue)
        } else {
            all[showRatingKey] = nil
        }
        save(all)
    }

    static var hasAnyPolicy: Bool {
        loadAll().values.contains { $0.count > 0 }
    }

    private static func loadAll() -> [String: Setting] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: Setting].self, from: data) else { return [:] }
        return decoded
    }

    private static func save(_ all: [String: Setting]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// Entry point for the scene's foreground hook: builds a client from the stored connection, if any.
    func evaluateOnForeground() {
        guard Self.hasAnyPolicy, let connection = ServerBootstrap.connection() else { return }
        evaluate(api: APIClient(baseURL: connection.serverURI, token: connection.authToken))
    }

    /// Tops up every show that has a policy. Concurrent calls coalesce into one extra pass.
    func evaluate(api: APIClient) {
        latestAPI = api
        registerObserverIfNeeded()
        guard Self.hasAnyPolicy else { return }
        guard UIApplication.shared.applicationState != .background else {
            AppLogger.info("Auto-download skipped while backgrounded", .persistence)
            return
        }
        guard !isEvaluating else {
            needsAnotherPass = true
            return
        }
        isEvaluating = true
        Task { [weak self] in
            await self?.runPasses(api: api)
        }
    }

    private func registerObserverIfNeeded() {
        guard observerToken == nil else { return }
        observerToken = DownloadManager.shared.addObserver { [weak self] event in
            guard case .finished = event else { return }
            self?.downloadFinished()
        }
    }

    private func downloadFinished() {
        guard Self.hasAnyPolicy, let api = latestAPI else { return }
        if let last = lastFinishedAt, Date().timeIntervalSince(last) < Self.observerThrottle { return }
        evaluate(api: api)
    }

    private func runPasses(api: APIClient) async {
        repeat {
            needsAnotherPass = false
            await evaluateAllShows(api: api)
        } while needsAnotherPass
        lastFinishedAt = Date()
        isEvaluating = false
    }

    private func evaluateAllShows(api: APIClient) async {
        for (showKey, setting) in Self.loadAll() where setting.count > 0 {
            guard !Task.isCancelled else { return }
            do {
                let upcoming = try await upcomingEpisodes(showKey: showKey, count: setting.count, api: api)
                let missing = upcoming.filter { DownloadManager.shared.item(for: $0.id) == nil }
                guard !missing.isEmpty else { continue }
                let quality = DownloadQuality(rawValue: setting.quality) ?? Preferences.downloadQuality
                let added = DownloadManager.shared.enqueueAll(missing, quality: quality)
                AppLogger.notice("Auto-download queued \(added) episodes for show \(showKey)", .persistence)
            } catch {
                AppLogger.error("Auto-download evaluation failed for show \(showKey): \(error.localizedDescription)", .networking)
                if Self.isConnectivityFailure(error) { return }
            }
        }
    }

    private static func isConnectivityFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    /// The first `count` unwatched episodes after the last watched one. Seasons that are fully watched
    /// only reset the window, and seasons with nothing watched are not fetched once the window is full.
    private func upcomingEpisodes(showKey: String, count: Int, api: APIClient) async throws -> [PlexMetadata] {
        await api.invalidate(ratingKey: showKey)
        let seasonContainer = try await api.requestContainer(.children(ratingKey: showKey))
        let seasons = (seasonContainer.Metadata ?? [])
            .filter { $0.mediaType == "season" && ($0.index ?? 0) > 0 }
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

        var window: [PlexMetadata] = []
        for season in seasons {
            let leaves = season.leafCount ?? 0
            let viewed = season.viewedLeafCount ?? 0
            if leaves > 0, viewed >= leaves {
                window.removeAll()
                continue
            }
            if viewed == 0, window.count >= count { continue }
            await api.invalidate(ratingKey: season.id)
            let container = try await api.requestContainer(.children(ratingKey: season.id))
            let episodes = (container.Metadata ?? [])
                .filter { $0.mediaType == "episode" }
                .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
            for episode in episodes {
                if episode.isWatched {
                    window.removeAll()
                } else {
                    window.append(episode)
                }
            }
        }
        return Array(window.prefix(count))
    }
}

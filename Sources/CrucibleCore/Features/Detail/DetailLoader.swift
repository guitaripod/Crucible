import Foundation

/// Messages for a detail screen whose item the server no longer has.
package enum DetailMessage {
    package static let itemUnavailable = "This item is no longer available on the server."
    package static let showUnavailable = "This show is no longer available on the server."
}

/// Loads the movie or episode behind a detail screen.
package enum MovieDetailLoader {
    /// Fetches the item's metadata with markers and related titles. Returns nil when the server no
    /// longer has it; throws on a failed request and `CancellationError` when the task was cancelled.
    package static func load(
        api: APIClient,
        ratingKey: String,
        showRatingKey: String? = nil,
        seasonRatingKey: String? = nil
    ) async throws -> MovieDetailModel? {
        let container = try await api.requestContainer(.metadata(ratingKey: ratingKey))
        try Task.checkCancellation()
        guard let item = container.Metadata?.first else { return nil }
        return MovieDetailModel(item: item, showRatingKey: showRatingKey, seasonRatingKey: seasonRatingKey)
    }

    /// The episode after `ratingKey` within the season `seasonKey`; nil at the end of the season.
    package static func nextEpisode(after ratingKey: String, inSeason seasonKey: String, api: APIClient) async throws -> PlexMetadata? {
        let container = try await api.requestContainer(.children(ratingKey: seasonKey))
        return MovieDetailModel.nextEpisode(after: ratingKey, in: container.Metadata ?? [])
    }
}

/// Loads the show, its seasons and episodes behind a show detail screen.
package enum ShowDetailLoader {
    /// Fetches the show, its seasons, the episodes of the selected season and every episode of the
    /// show. Returns nil when the server no longer has the show; throws on a failed show or season
    /// request and `CancellationError` when the task was cancelled. A failing season or all-episodes
    /// request does not fail the load: the season shows no episodes and up next falls back to the season.
    ///
    /// `onShow` runs as soon as the show itself arrives, so the screen can set its title and artwork
    /// while seasons are still loading. `selectedSeasonKey` is read once the seasons have arrived so a
    /// season picked meanwhile is honoured.
    package static func load(
        api: APIClient,
        showRatingKey: String,
        initialSeasonKey: String?,
        selectedSeasonKey: @MainActor () -> String?,
        onShow: @MainActor (PlexMetadata) -> Void
    ) async throws -> ShowDetailModel? {
        let showContainer = try await api.requestContainer(.metadata(ratingKey: showRatingKey))
        try Task.checkCancellation()
        guard let show = showContainer.Metadata?.first else { return nil }
        await onShow(show)

        async let leaves = try? api.requestContainer(.folderPath("/library/metadata/\(showRatingKey)/allLeaves"))
        let seasonsContainer = try await api.requestContainer(.children(ratingKey: showRatingKey))
        try Task.checkCancellation()
        let seasons = (seasonsContainer.Metadata ?? []).filter { $0.mediaType == "season" }

        let selected = ShowDetailModel.resolvedSeasonKey(
            current: await selectedSeasonKey(),
            seasons: seasons,
            preferred: initialSeasonKey
        )

        var seasonEpisodes: [PlexMetadata] = []
        if let selected {
            guard let loaded = await episodes(inSeason: selected, api: api) else { throw CancellationError() }
            seasonEpisodes = loaded
        }
        let allEpisodes = (await leaves)?.Metadata?.filter { $0.mediaType == "episode" } ?? []
        try Task.checkCancellation()
        return ShowDetailModel(show: show, seasons: seasons, selectedSeasonKey: selected, episodes: seasonEpisodes, allEpisodes: allEpisodes)
    }

    /// The episodes of one season. A failed request is logged and yields no episodes; nil means the task was cancelled.
    package static func episodes(inSeason seasonKey: String, api: APIClient) async -> [PlexMetadata]? {
        do {
            let container = try await api.requestContainer(.children(ratingKey: seasonKey))
            guard !Task.isCancelled else { return nil }
            return container.Metadata ?? []
        } catch {
            guard !Task.isCancelled else { return nil }
            AppLogger.error("Season load failed ratingKey=\(seasonKey): \(error.localizedDescription)", .networking)
            return []
        }
    }
}

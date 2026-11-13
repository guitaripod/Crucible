import Foundation
import MidgarCore

/// Where a card was asked for, and so which cards it can be: a movie is only itself; an episode is itself, its season or
/// its show; a season is itself or its show; a show is only itself.
package struct WatchCardOrigin: Hashable, Sendable {
    package let initial: WatchCardScope
    package let movieKey: String?
    package let episodeKey: String?
    package let seasonKey: String?
    package let seasonIndex: Int?
    package let showKey: String?

    package init(
        initial: WatchCardScope,
        movieKey: String? = nil,
        episodeKey: String? = nil,
        seasonKey: String? = nil,
        seasonIndex: Int? = nil,
        showKey: String? = nil
    ) {
        self.initial = initial
        self.movieKey = movieKey
        self.episodeKey = episodeKey
        self.seasonKey = seasonKey
        self.seasonIndex = seasonIndex
        self.showKey = showKey
    }

    /// The card for a movie, episode, season or show as the server describes it; nil for anything else.
    package init?(item: PlexMetadata) {
        switch item.mediaType {
        case "movie":
            self.init(initial: .movie, movieKey: item.id)
        case "episode":
            self.init(initial: .episode, episodeKey: item.id, seasonKey: item.parentRatingKey, seasonIndex: item.parentIndex, showKey: item.grandparentRatingKey)
        case "season":
            self.init(initial: .season, seasonKey: item.id, seasonIndex: item.index, showKey: item.parentRatingKey)
        case "show":
            self.init(initial: .show, showKey: item.id)
        default:
            return nil
        }
    }

    /// The card for a title the viewer was asked to rate: the movie, the season they closed, or the show.
    package init(ask: RatingAsk) {
        guard ask.isShow else {
            self.init(initial: .movie, movieKey: ask.ratingKey)
            return
        }
        if case .finishedSeason(let season?) = ask.reason {
            self.init(initial: .season, seasonIndex: season, showKey: ask.ratingKey)
        } else {
            self.init(initial: .show, showKey: ask.ratingKey)
        }
    }

    /// The card for a show's page: the season on screen when the viewer has finished it and not the whole show yet,
    /// the show otherwise, with the other one a tap away.
    package init(show: PlexMetadata, selectedSeason: PlexMetadata?) {
        let seasonDone = selectedSeason.map { season in
            (season.leafCount ?? 0) > 0 && (season.viewedLeafCount ?? 0) >= (season.leafCount ?? 0)
        } ?? false
        let showDone = (show.leafCount ?? 0) > 0 && (show.viewedLeafCount ?? 0) >= (show.leafCount ?? 0)
        self.init(
            initial: seasonDone && !showDone ? .season : .show,
            seasonKey: selectedSeason?.id,
            seasonIndex: selectedSeason?.index,
            showKey: show.id
        )
    }

    /// The card for a play in the watch history: the movie, the show, or the episode with its season and show a tap away.
    package init(history destination: HistoryDestination) {
        switch destination {
        case .movie(let ratingKey):
            self.init(initial: .movie, movieKey: ratingKey)
        case .show(let ratingKey):
            self.init(initial: .show, showKey: ratingKey)
        case .episode(let ratingKey, let showRatingKey, let seasonRatingKey):
            self.init(initial: .episode, episodeKey: ratingKey, seasonKey: seasonRatingKey, showKey: showRatingKey)
        }
    }

    /// The card for what just finished playing: the movie, or for the last episode of a show, the show it closed, with
    /// the episode and its season a tap away.
    package init?(finished request: PlaybackRequest) {
        switch request.mediaType {
        case "movie":
            self.init(initial: .movie, movieKey: request.ratingKey)
        case "episode":
            self.init(
                initial: .show,
                episodeKey: request.ratingKey,
                seasonKey: request.seasonRatingKey,
                seasonIndex: request.metadata?.seasonNumber,
                showKey: request.showRatingKey
            )
        default:
            return nil
        }
    }

    /// The same cards, opening on `scope`: the one the viewer just rated, so the card carries the stars they gave.
    package func starting(at scope: WatchCardScope) -> WatchCardOrigin {
        WatchCardOrigin(initial: scope, movieKey: movieKey, episodeKey: episodeKey, seasonKey: seasonKey, seasonIndex: seasonIndex, showKey: showKey)
    }

    /// The card the screen opens on: the one asked for, or the narrowest there is when that one cannot be made.
    package var startingScope: WatchCardScope {
        scopes.contains(initial) ? initial : (scopes.first ?? initial)
    }

    /// The cards this origin can switch between, narrowest first.
    package var scopes: [WatchCardScope] {
        var scopes: [WatchCardScope] = []
        if movieKey != nil { scopes.append(.movie) }
        if episodeKey != nil { scopes.append(.episode) }
        if seasonKey != nil || (seasonIndex != nil && showKey != nil) { scopes.append(.season) }
        if showKey != nil { scopes.append(.show) }
        return scopes
    }

    /// The label of `scope` in the switch between cards: Episode, "Season 2", Show.
    package func title(for scope: WatchCardScope) -> String {
        switch scope {
        case .movie: return String(localized: "Movie")
        case .episode: return String(localized: "Episode")
        case .season: return seasonIndex.map { String(localized: "Season \($0)") } ?? String(localized: "Season", comment: "A season of a TV show")
        case .show: return String(localized: "Show")
        }
    }
}

/// Loads what a card says about its title: the item, the show around it and the episodes behind its counts and dates.
@MainActor
package enum WatchCardLoader {
    /// The subject of `scope` for `origin`; nil when the server no longer has it. Throws on a failed request and
    /// `CancellationError` when the task was cancelled.
    package static func load(_ scope: WatchCardScope, origin: WatchCardOrigin, api: APIClient) async throws -> WatchCardSubject? {
        switch scope {
        case .movie:
            guard let key = origin.movieKey, let item = try await metadata(key, api: api) else { return nil }
            let scores = await TraktScores.shared.scores(ratingKey: key, api: api)
            return WatchCardSubject(scope: .movie, item: item, scores: scores)
        case .episode:
            guard let key = origin.episodeKey, let item = try await metadata(key, api: api) else { return nil }
            let show = try await optionalMetadata(item.grandparentRatingKey ?? origin.showKey, api: api)
            let scores = await TraktScores.shared.scores(ratingKey: key, api: api)
            return WatchCardSubject(scope: .episode, item: item, show: show, scores: scores)
        case .season:
            guard let key = try await seasonKey(for: origin, api: api), let season = try await metadata(key, api: api) else { return nil }
            async let children = api.requestContainer(.children(ratingKey: key))
            let show = try await optionalMetadata(season.parentRatingKey ?? origin.showKey, api: api)
            let episodes = try await children.Metadata ?? []
            return WatchCardSubject(scope: .season, item: season, show: show, episodes: episodes)
        case .show:
            guard let key = origin.showKey, let show = try await metadata(key, api: api) else { return nil }
            async let children = api.requestContainer(.children(ratingKey: key))
            let leaves = await allLeaves(of: key, api: api)
            let scores = await TraktScores.shared.scores(ratingKey: key, api: api)
            let seasons = try await children.Metadata ?? []
            return WatchCardSubject(scope: .show, item: show, seasons: seasons, episodes: leaves?.Metadata ?? [], scores: scores)
        }
    }

    private static func metadata(_ key: String, api: APIClient) async throws -> PlexMetadata? {
        let container = try await api.requestContainer(.metadata(ratingKey: key))
        try Task.checkCancellation()
        return container.Metadata?.first
    }

    /// The show around an episode or season, which only adds to the card, so a failed request leaves it out.
    private static func optionalMetadata(_ key: String?, api: APIClient) async throws -> PlexMetadata? {
        guard let key else { return nil }
        do {
            return try await metadata(key, api: api)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// Every episode of a show, which only adds the running time and the dates to its card, so a failed request leaves
    /// them out rather than the card.
    private static func allLeaves(of key: String, api: APIClient) async -> PlexMediaContainer? {
        do {
            return try await api.requestContainer(.folderPath("/library/metadata/\(key)/allLeaves"))
        } catch {
            MidgarLog.notice("Watch card episodes of show \(key) not loaded: \(error.localizedDescription)", category: .networking)
            return nil
        }
    }

    /// The season's own key, found among the show's seasons by its number when only the number is known.
    private static func seasonKey(for origin: WatchCardOrigin, api: APIClient) async throws -> String? {
        if let key = origin.seasonKey { return key }
        guard let show = origin.showKey, let index = origin.seasonIndex else { return nil }
        let seasons = try await api.requestContainer(.children(ratingKey: show)).Metadata ?? []
        try Task.checkCancellation()
        return seasons.first { $0.mediaType == "season" && $0.index == index }?.id
    }
}

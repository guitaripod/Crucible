import Foundation

/// The next episode on offer and how it came about.
package struct UpNextOffer: Sendable {
    package enum Reason: Sendable {
        case credits
        case playbackEnded
        case requested
    }

    package static let countdownSeconds = 10

    package let episode: PlexMetadata
    package let seasonRatingKey: String
    package let reason: Reason
    package let autoplays: Bool

    package init(episode: PlexMetadata, seasonRatingKey: String, reason: Reason, autoplays: Bool) {
        self.episode = episode
        self.seasonRatingKey = seasonRatingKey
        self.reason = reason
        self.autoplays = autoplays
    }

    package var playbackEnded: Bool { reason == .playbackEnded }

    /// The request that plays this episode from its start, keeping the show it belongs to, the streams the
    /// viewer chose on the episode before, and the resume point of a downloaded copy.
    package func nextRequest(
        showRatingKey: String?,
        offline: OfflinePlaybackSource? = nil,
        selectedSubtitleId: Int? = nil,
        selectedAudioStreamId: Int? = nil
    ) -> PlaybackRequest {
        PlaybackRequest(
            ratingKey: episode.id,
            mediaType: "episode",
            showRatingKey: showRatingKey,
            seasonRatingKey: seasonRatingKey,
            resumePosition: offline?.resumeSecs ?? 0,
            metadata: PlaybackMetadata(
                title: episode.title,
                showName: episode.grandparentTitle,
                seasonNumber: episode.parentIndex,
                episodeNumber: episode.index,
                posterPath: episode.grandparentThumb ?? episode.thumb,
                duration: episode.durationSecs
            ),
            selectedSubtitleId: selectedSubtitleId,
            selectedAudioStreamId: selectedAudioStreamId,
            offline: offline
        )
    }
}

/// Finds the episode after the one playing and says when the credits ask for it. The next episode is the
/// following entry of the season, and a season's last episode is followed by the first episode of the next
/// season that has one, so a show plays on through its finale instead of dead-ending there. The credits
/// trigger fires at most once per playback.
package struct UpNextResolver: Sendable {
    private let ratingKey: String
    private let isEpisode: Bool
    private let seasonRatingKey: String?
    private let showRatingKey: String?
    package let creditsStartSecs: Double?
    private var creditsTriggered = false

    package init(
        ratingKey: String,
        isEpisode: Bool,
        seasonRatingKey: String?,
        showRatingKey: String? = nil,
        markers: [PlexMarker]
    ) {
        self.ratingKey = ratingKey
        self.isEpisode = isEpisode
        self.seasonRatingKey = seasonRatingKey
        self.showRatingKey = showRatingKey
        self.creditsStartSecs = markers.first(where: \.isCredits)?.startSecs
    }

    /// Whether an episode in a known season can have a successor at all.
    package var canOfferNext: Bool { isEpisode && seasonRatingKey != nil }

    /// True exactly once, the first time the playhead reaches the credits of an episode.
    package mutating func creditsReached(at absolute: Double) -> Bool {
        guard !creditsTriggered, isEpisode, let creditsStartSecs, absolute >= creditsStartSecs else { return false }
        creditsTriggered = true
        return true
    }

    package static func nextEpisode(after ratingKey: String, in episodes: [PlexMetadata]) -> PlexMetadata? {
        EpisodeOrder.next(after: ratingKey, in: episodes)
    }

    /// Loads the season and returns the offer for the next episode, or nil when this is the last episode of
    /// the show. The end of a season crosses into the next one, which costs a few extra requests only there.
    package func loadOffer(api: APIClient, reason: UpNextOffer.Reason) async throws -> UpNextOffer? {
        guard let seasonRatingKey else { return nil }
        let container = try await api.requestContainer(.children(ratingKey: seasonRatingKey))
        if let next = EpisodeOrder.next(after: ratingKey, in: container.Metadata ?? []) {
            return Self.offer(next, season: seasonRatingKey, reason: reason)
        }
        guard let (episode, season) = try await firstEpisodeOfNextSeason(api: api, from: seasonRatingKey) else {
            return nil
        }
        return Self.offer(episode, season: season, reason: reason)
    }

    private static func offer(_ episode: PlexMetadata, season: String, reason: UpNextOffer.Reason) -> UpNextOffer {
        UpNextOffer(episode: episode, seasonRatingKey: season, reason: reason, autoplays: Preferences.autoplayNextEpisode)
    }

    /// The first episode of the season after `seasonKey`, skipping seasons with nothing in them and never
    /// wrapping back to the specials (season zero) that sort before the show's first real season.
    private func firstEpisodeOfNextSeason(api: APIClient, from seasonKey: String) async throws -> (PlexMetadata, String)? {
        let showKey: String
        if let showRatingKey {
            showKey = showRatingKey
        } else {
            let season = try await api.requestContainer(.metadata(ratingKey: seasonKey)).Metadata?.first
            guard let parent = season?.parentRatingKey else { return nil }
            showKey = parent
        }
        let seasons = (try await api.requestContainer(.children(ratingKey: showKey)).Metadata ?? [])
            .filter { $0.mediaType == "season" }
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        guard let current = seasons.firstIndex(where: { $0.id == seasonKey }) else { return nil }
        for season in seasons[(current + 1)...] {
            let children = try await api.requestContainer(.children(ratingKey: season.id)).Metadata ?? []
            let episodes = children.filter { $0.mediaType == "episode" }
            if let first = EpisodeOrder.sorted(episodes).first {
                return (first, season.id)
            }
        }
        return nil
    }
}

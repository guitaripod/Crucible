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

    /// The request that plays this episode from its start, keeping the show it belongs to.
    package func nextRequest(showRatingKey: String?, offline: OfflinePlaybackSource? = nil) -> PlaybackRequest {
        PlaybackRequest(
            ratingKey: episode.id,
            mediaType: "episode",
            showRatingKey: showRatingKey,
            seasonRatingKey: seasonRatingKey,
            resumePosition: 0,
            metadata: PlaybackMetadata(
                title: episode.title,
                showName: episode.grandparentTitle,
                seasonNumber: episode.parentIndex,
                episodeNumber: episode.index,
                posterPath: episode.grandparentThumb ?? episode.thumb,
                duration: episode.durationSecs
            ),
            offline: offline
        )
    }
}

/// Finds the episode after the one playing and says when the credits ask for it. The next episode is
/// the following entry of the season's children by position; seasons are never crossed. The credits
/// trigger fires at most once per playback.
package struct UpNextResolver: Sendable {
    private let ratingKey: String
    private let isEpisode: Bool
    private let seasonRatingKey: String?
    package let creditsStartSecs: Double?
    private var creditsTriggered = false

    package init(ratingKey: String, isEpisode: Bool, seasonRatingKey: String?, markers: [PlexMarker]) {
        self.ratingKey = ratingKey
        self.isEpisode = isEpisode
        self.seasonRatingKey = seasonRatingKey
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
        guard let index = episodes.firstIndex(where: { $0.id == ratingKey }), index + 1 < episodes.count else { return nil }
        return episodes[index + 1]
    }

    /// Loads the season and returns the offer for the next episode, or nil when this is the last one.
    package func loadOffer(api: APIClient, reason: UpNextOffer.Reason) async throws -> UpNextOffer? {
        guard let seasonRatingKey else { return nil }
        let container = try await api.requestContainer(.children(ratingKey: seasonRatingKey))
        guard let next = Self.nextEpisode(after: ratingKey, in: container.Metadata ?? []) else { return nil }
        return UpNextOffer(
            episode: next,
            seasonRatingKey: seasonRatingKey,
            reason: reason,
            autoplays: Preferences.autoplayNextEpisode
        )
    }
}

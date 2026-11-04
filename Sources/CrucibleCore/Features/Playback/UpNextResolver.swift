import Foundation

/// The next episode on offer and how it came about.
package struct UpNextOffer: Sendable {
    package enum Reason: Sendable {
        case credits
        case playbackEnded
        case requested
    }

    /// How long the card counts down, as chosen in Settings (10 seconds unless changed).
    package static var countdownSeconds: Int { Preferences.upNextCountdown }

    package let episode: PlexMetadata
    package let seasonRatingKey: String
    package let reason: Reason
    package let autoplays: Bool
    /// The queue standing on this entry when the offer comes from a playlist, which then carries on from it.
    package let queue: PlaybackQueue?

    package init(episode: PlexMetadata, seasonRatingKey: String, reason: Reason, autoplays: Bool, queue: PlaybackQueue? = nil) {
        self.episode = episode
        self.seasonRatingKey = seasonRatingKey
        self.reason = reason
        self.autoplays = autoplays
        self.queue = queue
    }

    package var playbackEnded: Bool { reason == .playbackEnded }

    /// The same offer without its countdown, for a sleep timer that stops at the end of the episode.
    package func withoutAutoplay() -> UpNextOffer {
        UpNextOffer(episode: episode, seasonRatingKey: seasonRatingKey, reason: reason, autoplays: false, queue: queue)
    }

    /// The request that plays this episode from its start, keeping the show it belongs to, the languages the
    /// viewer chose on the episode before, and the resume point of a downloaded copy.
    package func nextRequest(
        showRatingKey: String?,
        offline: OfflinePlaybackSource? = nil,
        trackLanguages: TrackLanguages? = nil
    ) -> PlaybackRequest {
        PlaybackRequest(
            ratingKey: episode.id,
            mediaType: queue == nil ? "episode" : episode.mediaType,
            showRatingKey: queue == nil ? showRatingKey : episode.grandparentRatingKey,
            seasonRatingKey: seasonRatingKey.isEmpty ? nil : seasonRatingKey,
            resumePosition: offline?.resumeSecs ?? 0,
            metadata: PlaybackMetadata(
                title: episode.title,
                showName: episode.grandparentTitle,
                seasonNumber: episode.parentIndex,
                episodeNumber: episode.index,
                posterPath: episode.grandparentThumb ?? episode.thumb,
                duration: episode.durationSecs,
                showPosterPath: episode.grandparentThumb,
                librarySectionID: episode.librarySectionID
            ),
            trackLanguages: trackLanguages,
            offline: offline,
            queue: queue
        )
    }
}

/// Whether the Up Next card counts down and starts what comes next on its own. Autoplay Next Episode means just that, at the
/// credits as much as at the end: a card that waited for the remote at the credits used to stay up until someone pressed a
/// button, and on Apple TV it also held back the end-of-episode autoplay. Skip Credits set to Skip Automatically moves on
/// from the credits even with autoplay off; a playlist plays on at the end of every entry, as it is made to.
package enum AutoplayRule {
    package static func autoplays(
        reason: UpNextOffer.Reason,
        isQueue: Bool,
        autoplayNext: Bool = Preferences.autoplayNextEpisode,
        skipCredits: Preferences.SkipOutroMode = Preferences.skipOutroMode
    ) -> Bool {
        switch reason {
        case .credits: return autoplayNext || skipCredits == .automatic
        case .playbackEnded: return isQueue || autoplayNext
        case .requested: return true
        }
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
    private let queue: PlaybackQueue?
    package let creditsStartSecs: Double?
    private var creditsTriggered = false

    package init(
        ratingKey: String,
        isEpisode: Bool,
        seasonRatingKey: String?,
        showRatingKey: String? = nil,
        queue: PlaybackQueue? = nil,
        markers: [PlexMarker]
    ) {
        self.ratingKey = ratingKey
        self.isEpisode = isEpisode
        self.seasonRatingKey = seasonRatingKey
        self.showRatingKey = showRatingKey
        self.queue = queue
        self.creditsStartSecs = markers.first(where: \.isCredits)?.startSecs
    }

    /// Whether there can be a successor at all: another entry of the queue, or for an episode in a known season the next one of the show.
    package var canOfferNext: Bool {
        if let queue { return queue.hasNext }
        return isEpisode && seasonRatingKey != nil
    }

    /// True exactly once, the first time the playhead reaches the credits of an episode.
    package mutating func creditsReached(at absolute: Double) -> Bool {
        guard !creditsTriggered, isEpisode || queue != nil, let creditsStartSecs, absolute >= creditsStartSecs else { return false }
        creditsTriggered = true
        return true
    }

    package static func nextEpisode(after ratingKey: String, in episodes: [PlexMetadata]) -> PlexMetadata? {
        EpisodeOrder.next(after: ratingKey, in: episodes)
    }

    /// Loads the season and returns the offer for the next episode, or nil when this is the last episode of
    /// the show or Skip Outro keeps the credits to themselves. The end of a season crosses into the next
    /// one, which costs a few extra requests only there. A credits offer waits for the viewer unless Skip
    /// Outro is set to start the next episode automatically; the end of the item follows Autoplay Next
    /// Episode.
    package func loadOffer(api: APIClient, reason: UpNextOffer.Reason) async throws -> UpNextOffer? {
        if let queue {
            return try await queuedOffer(after: queue, reason: reason)
        }
        guard let seasonRatingKey else { return nil }
        if reason == .credits, Preferences.skipOutroMode == .off { return nil }
        let container = try await api.requestContainer(.children(ratingKey: seasonRatingKey))
        if let next = EpisodeOrder.next(after: ratingKey, in: container.Metadata ?? []) {
            return Self.offer(next, season: seasonRatingKey, reason: reason)
        }
        guard let (episode, season) = try await firstEpisodeOfNextSeason(api: api, from: seasonRatingKey) else {
            return nil
        }
        return Self.offer(episode, season: season, reason: reason)
    }

    /// The next entry of a playlist. Nothing is fetched: the queue already holds what plays next. A credits offer waits for the viewer
    /// unless Skip Outro is set to start the next one automatically; the end of an item plays on, as a playlist is made to.
    private func queuedOffer(after queue: PlaybackQueue, reason: UpNextOffer.Reason) async throws -> UpNextOffer? {
        if reason == .credits, Preferences.skipOutroMode == .off { return nil }
        guard let advanced = queue.advanced() else { return nil }
        return UpNextOffer(
            episode: advanced.current,
            seasonRatingKey: advanced.current.parentRatingKey ?? "",
            reason: reason,
            autoplays: AutoplayRule.autoplays(reason: reason, isQueue: true),
            queue: advanced
        )
    }

    private static func offer(_ episode: PlexMetadata, season: String, reason: UpNextOffer.Reason) -> UpNextOffer {
        UpNextOffer(
            episode: episode,
            seasonRatingKey: season,
            reason: reason,
            autoplays: AutoplayRule.autoplays(reason: reason, isQueue: false)
        )
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

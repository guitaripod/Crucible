import Foundation

/// Display metadata a playback surface needs for its title card, Now Playing entry and Up Next hand-off.
package struct PlaybackMetadata: Sendable, Equatable {
    package let title: String
    package let showName: String?
    package let seasonNumber: Int?
    package let episodeNumber: Int?
    package let posterPath: String?
    package let duration: Double?
    /// The show's own poster for an episode, which is what asking to rate the show shows.
    package let showPosterPath: String?

    package init(
        title: String,
        showName: String?,
        seasonNumber: Int?,
        episodeNumber: Int?,
        posterPath: String?,
        duration: Double?,
        showPosterPath: String? = nil
    ) {
        self.title = title
        self.showName = showName
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.posterPath = posterPath
        self.duration = duration
        self.showPosterPath = showPosterPath
    }

    package init(item: PlexMetadata) {
        self.init(
            title: item.title,
            showName: item.grandparentTitle,
            seasonNumber: item.parentIndex,
            episodeNumber: item.index,
            posterPath: item.thumb ?? item.grandparentThumb,
            duration: item.durationSecs,
            showPosterPath: item.grandparentThumb
        )
    }
}

/// A downloaded copy of an item served from disk instead of the Plex server.
package struct OfflinePlaybackSource: Sendable {
    package let fileURL: URL
    package let markers: [PlexMarker]
    package let durationSecs: Double
    /// Where the downloaded copy itself was left, for an episode played before it is offered as Up Next.
    package let resumeSecs: Double

    package init(fileURL: URL, markers: [PlexMarker], durationSecs: Double, resumeSecs: Double = 0) {
        self.fileURL = fileURL
        self.markers = markers
        self.durationSecs = durationSecs
        self.resumeSecs = resumeSecs
    }
}

/// Everything needed to start playing one item: identity, where to resume, which streams the user
/// already chose, and the offline copy to prefer.
package struct PlaybackRequest: Sendable {
    package let ratingKey: String
    package let mediaType: String
    package let showRatingKey: String?
    package let seasonRatingKey: String?
    package let resumePosition: Double
    package let metadata: PlaybackMetadata?
    package let selectedSubtitleId: Int?
    package let selectedAudioStreamId: Int?
    /// The languages to start in when no stream is chosen by id: the ones the viewer had on the episode before.
    package let trackLanguages: TrackLanguages?
    package let offline: OfflinePlaybackSource?
    package let queue: PlaybackQueue?

    package init(
        ratingKey: String,
        mediaType: String,
        showRatingKey: String?,
        seasonRatingKey: String?,
        resumePosition: Double,
        metadata: PlaybackMetadata? = nil,
        selectedSubtitleId: Int? = nil,
        selectedAudioStreamId: Int? = nil,
        trackLanguages: TrackLanguages? = nil,
        offline: OfflinePlaybackSource? = nil,
        queue: PlaybackQueue? = nil
    ) {
        self.trackLanguages = trackLanguages
        self.ratingKey = ratingKey
        self.mediaType = mediaType
        self.showRatingKey = showRatingKey
        self.seasonRatingKey = seasonRatingKey
        self.resumePosition = resumePosition
        self.metadata = metadata
        self.selectedSubtitleId = selectedSubtitleId
        self.selectedAudioStreamId = selectedAudioStreamId
        self.offline = offline
        self.queue = queue
    }

    /// Plays `item` from the position the server last stored for it unless `resumePosition` says otherwise.
    /// A watched item starts from the beginning: whatever offset the server still holds is not a place to
    /// resume, it is where the last watching stopped.
    package init(
        item: PlexMetadata,
        resumePosition: Double? = nil,
        selectedSubtitleId: Int? = nil,
        selectedAudioStreamId: Int? = nil,
        offline: OfflinePlaybackSource? = nil,
        queue: PlaybackQueue? = nil
    ) {
        self.init(
            ratingKey: item.id,
            mediaType: item.mediaType,
            showRatingKey: item.grandparentRatingKey,
            seasonRatingKey: item.parentRatingKey,
            resumePosition: resumePosition ?? (item.isWatched ? 0 : item.positionSecs),
            metadata: PlaybackMetadata(item: item),
            selectedSubtitleId: selectedSubtitleId,
            selectedAudioStreamId: selectedAudioStreamId,
            offline: offline,
            queue: queue
        )
    }

    /// The same request starting at `position`, for a retry that should continue where playback
    /// stopped. The audio and subtitle streams default to the ones this request chose; pass the ones
    /// the viewer switched to since.
    package func resuming(
        at position: Double,
        selectedSubtitleId: Int?? = nil,
        selectedAudioStreamId: Int?? = nil
    ) -> PlaybackRequest {
        PlaybackRequest(
            ratingKey: ratingKey,
            mediaType: mediaType,
            showRatingKey: showRatingKey,
            seasonRatingKey: seasonRatingKey,
            resumePosition: position,
            metadata: metadata,
            selectedSubtitleId: selectedSubtitleId ?? self.selectedSubtitleId,
            selectedAudioStreamId: selectedAudioStreamId ?? self.selectedAudioStreamId,
            trackLanguages: trackLanguages,
            offline: offline,
            queue: queue
        )
    }

    package var isEpisode: Bool { mediaType == "episode" }

    /// A trailer or other clip: it plays, but leaves no trace on the server (no timeline, no place to resume from).
    package var isExtra: Bool { mediaType == Self.extraMediaType }

    package static let extraMediaType = "clip"

    /// Plays `extra` (a trailer, a featurette) of `title`.
    package static func extra(_ extra: PlexMetadata, of title: PlexMetadata) -> PlaybackRequest {
        PlaybackRequest(
            ratingKey: extra.id,
            mediaType: extraMediaType,
            showRatingKey: nil,
            seasonRatingKey: nil,
            resumePosition: 0,
            metadata: PlaybackMetadata(
                title: extra.title,
                showName: title.title,
                seasonNumber: nil,
                episodeNumber: nil,
                posterPath: title.posterPath ?? extra.posterPath,
                duration: extra.durationSecs
            )
        )
    }

    /// The URL offset the transcoder is asked to start at, or nil when playback starts at the beginning.
    package var transcodeStartSecs: Double? { resumePosition > 0 ? resumePosition : nil }

    package var durationSecs: Double {
        if let offline, offline.durationSecs > 0 { return offline.durationSecs }
        return metadata?.duration ?? 0
    }
}

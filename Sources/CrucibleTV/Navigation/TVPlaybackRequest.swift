import CrucibleCore

/// Everything the player needs to start an item: identity, where the show and season sit for Up
/// Next, the resume position and the user's explicit stream picks.
struct TVPlaybackRequest: Sendable, Equatable {
    /// What the info panel and Now Playing show while the stream is still resolving.
    struct Display: Sendable, Equatable {
        let title: String
        let showName: String?
        let seasonNumber: Int?
        let episodeNumber: Int?
        let posterPath: String?
        let durationSeconds: Double?
    }

    let ratingKey: String
    let mediaType: String
    let showRatingKey: String?
    let seasonRatingKey: String?
    let resumeSeconds: Double
    let selectedAudioStreamID: Int?
    let selectedSubtitleStreamID: Int?
    let display: Display?

    init(
        ratingKey: String,
        mediaType: String,
        showRatingKey: String? = nil,
        seasonRatingKey: String? = nil,
        resumeSeconds: Double = 0,
        selectedAudioStreamID: Int? = nil,
        selectedSubtitleStreamID: Int? = nil,
        display: Display? = nil
    ) {
        self.ratingKey = ratingKey
        self.mediaType = mediaType
        self.showRatingKey = showRatingKey
        self.seasonRatingKey = seasonRatingKey
        self.resumeSeconds = resumeSeconds
        self.selectedAudioStreamID = selectedAudioStreamID
        self.selectedSubtitleStreamID = selectedSubtitleStreamID
        self.display = display
    }

    /// Builds the request for `item`, resuming where the server says it was left unless
    /// `resumeSeconds` overrides it (pass 0 for Play from Beginning).
    init(
        item: PlexMetadata,
        resumeSeconds: Double? = nil,
        selectedAudioStreamID: Int? = nil,
        selectedSubtitleStreamID: Int? = nil
    ) {
        self.init(
            ratingKey: item.id,
            mediaType: item.mediaType,
            showRatingKey: item.grandparentRatingKey,
            seasonRatingKey: item.parentRatingKey,
            resumeSeconds: resumeSeconds ?? item.positionSecs,
            selectedAudioStreamID: selectedAudioStreamID,
            selectedSubtitleStreamID: selectedSubtitleStreamID,
            display: Display(
                title: item.title,
                showName: item.grandparentTitle,
                seasonNumber: item.parentIndex,
                episodeNumber: item.index,
                posterPath: item.thumb ?? item.grandparentThumb,
                durationSeconds: item.durationSecs
            )
        )
    }
}

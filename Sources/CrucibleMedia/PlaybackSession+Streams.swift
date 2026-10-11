import AVFoundation
import CrucibleCore
import Foundation

extension PlaybackSession {
    /// Where the credits begin on the item's timeline, if the server marked them.
    package var creditsStartSecs: Double? { upNext.creditsStartSecs }

    /// The next episode on offer, or nil for a movie, a last episode or when the season cannot be read.
    /// Lets a surface prepare its own "up next" presentation ahead of the credits.
    package func nextEpisodeOffer() async -> UpNextOffer? {
        guard upNext.canOfferNext else { return nil }
        return try? await upNext.loadOffer(api: api, reason: .credits)
    }

    /// Switches the audio track or subtitle by re-resolving the stream at the playhead: a non-default
    /// audio track or a burned-in subtitle makes the server transcode it, choosing none of them
    /// returns to the original stream when it can direct play. The item is replaced in the same
    /// player; a failed resolve throws and leaves playback untouched.
    package func selectStreams(subtitleId: Int?, audioStreamId: Int?) async throws {
        guard !isStopped, let player, !isChangingStreams else { return }
        isChangingStreams = true
        defer { isChangingStreams = false }
        let position = absolutePosition ?? request.resumePosition
        let wasPlaying = player.rate > 0
        let resolved = try await StreamResolver.resolve(
            api: api,
            ratingKey: request.ratingKey,
            startSecs: position > 0 ? position : nil,
            selectedSubtitleId: subtitleId,
            selectedAudioStreamId: audioStreamId
        )
        guard !isStopped else {
            discardTranscode(of: resolved)
            return
        }
        if let previous = stream { discardTranscode(of: previous) }
        selectedSubtitleId = subtitleId
        selectedAudioStreamId = audioStreamId
        stream = resolved
        streamOffset = ResumeStrategy.streamOffset(resumePosition: position, isDirectPlay: resolved.isDirectPlay)
        lastPlayhead = resolved.isDirectPlay ? position : 0
        isRestarting = false
        pendingRestartTarget = nil
        restartItemObserver?.invalidate()
        restartItemObserver = nil
        reporter?.setStreamOffset(streamOffset)
        if resolved.isDirectPlay {
            pingTask?.cancel()
            pingTask = nil
        } else {
            startPing(session: resolved.sessionId)
        }
        let item = AVPlayerItem(url: resolved.url)
        configureItem?(item)
        player.replaceCurrentItem(with: item)
        watchCurrentItem()
        startPlayback(player: player, stream: resolved, resumePosition: position, autoplay: wasPlaying)
    }
}

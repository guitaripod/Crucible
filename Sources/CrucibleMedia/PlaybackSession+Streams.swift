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

    /// Keeps the viewer's pick on an episode for its show, so the show's other episodes start in the same languages.
    func rememberLanguagesForShow() {
        guard request.isEpisode, let languages = trackLanguages else { return }
        ShowTrackMemory.remember(languages, forShow: request.showRatingKey, server: serverID)
    }

    /// Plays `subtitleId` (nil for none) with `audioStreamId` (nil for the file's default). Showing or hiding the subtitle that
    /// already travels with the stream is instant; anything else re-resolves the stream at the playhead in the same player. A
    /// choice made while another is still resolving is not dropped: the running change takes the latest one up when it finishes.
    /// A failed resolve throws and leaves playback as it was.
    package func selectStreams(subtitleId: Int?, audioStreamId: Int?) async throws {
        guard !isStopped, player != nil, let stream else { return }
        if subtitleId != selectedSubtitleId { subtitlesTurnedOff = subtitleId == nil }
        let choice = merged(StreamChoice(subtitleId: subtitleId, audioStreamId: audioStreamId))
        if !isChangingStreams, canShowWithoutResolving(choice, on: stream) {
            showDeliveredSubtitle(subtitleId)
            return
        }
        try await changeStreams(choice)
    }

    /// A pick made while another change still resolves names the track the viewer changed and, for the other one, the track
    /// playing before that change. The other one is taken from the change on its way instead, so the earlier pick is kept.
    private func merged(_ choice: StreamChoice) -> StreamChoice {
        guard let base = pendingStreamChoice ?? resolvingStreamChoice else { return choice }
        return StreamChoice(
            subtitleId: choice.subtitleId != selectedSubtitleId ? choice.subtitleId : base.subtitleId,
            audioStreamId: choice.audioStreamId != selectedAudioStreamId ? choice.audioStreamId : base.audioStreamId
        )
    }

    /// Whether `choice` only shows or hides what `stream` already carries, and the item playing really has the subtitle track
    /// when it is to be shown.
    private func canShowWithoutResolving(_ choice: StreamChoice, on stream: ResolvedStream) -> Bool {
        choice.keepsStream(of: stream, playingAudio: selectedAudioStreamId) && (choice.subtitleId == nil || carriesSubtitleTrack)
    }

    /// Re-resolves the stream for `choice`, and for any choice that arrives while it runs. `rebuild` resolves even a choice the
    /// stream already carries, for a stream whose route is gone. A failed resolve is only reported when no newer choice waits.
    func changeStreams(_ choice: StreamChoice, rebuild: Bool = false) async throws {
        pendingStreamChoice = choice
        pendingRebuild = pendingRebuild || rebuild
        guard !isChangingStreams else { return }
        isChangingStreams = true
        defer { isChangingStreams = false }
        defer { resolvingStreamChoice = nil }
        while let next = pendingStreamChoice, !isStopped {
            pendingStreamChoice = nil
            resolvingStreamChoice = next
            let mustResolve = pendingRebuild
            pendingRebuild = false
            if !mustResolve, let stream, canShowWithoutResolving(next, on: stream) {
                showDeliveredSubtitle(next.subtitleId)
                continue
            }
            do {
                try await resolveStreams(next)
            } catch {
                guard pendingStreamChoice == nil else { continue }
                throw error
            }
        }
    }

    /// Switches the audio track or subtitle by re-resolving the stream at the playhead: a non-default audio track or a
    /// subtitle the file cannot show makes the server convert it, choosing none of them returns to the original stream when it
    /// can direct play. The item is replaced in the same player; a failed resolve throws and leaves playback untouched.
    private func resolveStreams(_ choice: StreamChoice) async throws {
        guard !isStopped, let player else { return }
        let position = absolutePosition ?? request.resumePosition
        let wasPlaying = player.rate > 0
        await selectionUpdateTask?.value
        let resolved = try await StreamResolver.resolve(
            api: api,
            ratingKey: request.ratingKey,
            startSecs: position > 0 ? position : nil,
            selectedSubtitleId: choice.subtitleId,
            selectedAudioStreamId: choice.audioStreamId
        )
        guard !isStopped else {
            discardTranscode(of: resolved)
            return
        }
        if let previous = stream { discardTranscode(of: previous) }
        selectedSubtitleId = resolved.chosenSubtitleId
        selectedAudioStreamId = resolved.chosenAudioStreamId
        stream = resolved
        rememberLanguagesForShow()
        let start = ResumeStrategy.streamStart(resumePosition: position, isDirectPlay: resolved.isDirectPlay)
        tracker.beginStream(start: start, isTranscode: !resolved.isDirectPlay)
        lastPlayhead = resolved.isDirectPlay ? position : start - streamOffset
        tracker.moved(to: resolved.isDirectPlay ? position : start)
        isRestarting = false
        pendingRestart = nil
        restartItemObserver?.invalidate()
        restartItemObserver = nil
        if resolved.isDirectPlay {
            pingTask?.cancel()
            pingTask = nil
            liveness = nil
        } else {
            liveness = TranscodeLiveness(confirmedAt: now())
            startPing(session: resolved.sessionId)
        }
        let item = AVPlayerItem(url: resolved.url)
        SubtitleStyle.apply(to: item)
        configureItem?(item)
        player.replaceCurrentItem(with: item)
        watchCurrentItem()
        startPlayback(player: player, stream: resolved, resumePosition: position, autoplay: wasPlaying)
        emit(.tracksChanged)
    }
}

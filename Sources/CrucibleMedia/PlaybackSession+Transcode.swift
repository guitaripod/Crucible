import AVFoundation
import CrucibleCore
import Foundation

/// A transcode restart asked for while another one is still being built.
struct PendingRestart {
    var target: Double
    var resumesPlayback: Bool
    var freshSession: Bool
    var reason: String
}

extension PlaybackSession {
    func watchCurrentItem() {
        itemWatcher?.invalidate()
        itemWatcher = nil
        guard let item = player?.currentItem, let stream else { return }
        let watched = ObjectIdentifier(item)
        itemWatcher = PlayerItemWatcher(item: item, isTranscode: !stream.isDirectPlay) { [weak self] event in
            guard let self, let current = player?.currentItem, ObjectIdentifier(current) == watched else { return }
            handle(event)
        }
    }

    private func handle(_ event: PlayerItemWatcher.Event) {
        guard !noticeAbsence(trigger: "item event") else { return }
        switch event {
        case .ended:
            handleEnd()
        case .failed(let message):
            handleFailure(message)
        case .jumped:
            handleJump()
        case .segmentLoaded:
            liveness?.confirm(at: now())
        case .segmentRefused(let status):
            guard TranscodeLiveness.isGoneStatus(status) else { return }
            transcodeGone(session: stream?.sessionId, reason: "segment \(status)")
        case .stalled:
            guard let liveness, liveness.mayBeGone(at: now()) else { return }
            heal(reason: "stalled with no word from the server")
        }
    }

    /// A jump of the playhead inside a transcode is the viewer scrubbing: the transcode restarts at the new
    /// place, playing or paused as the player was. Jumps while the session moves the player itself, or before
    /// the item is ready to show the new place, are the item settling and not the viewer.
    private func handleJump() {
        guard let player else { return }
        if player.rate == 0, pausedSince != nil, !isRecovering { pausedSince = now() }
        guard stream?.isDirectPlay == false else { return }
        guard !tracker.isHeld, !isRestarting, !isRecovering, let item = player.currentItem, item.status == .readyToPlay else { return }
        let now = item.currentTime().seconds
        guard now.isFinite else { return }
        let previous = lastPlayhead
        lastPlayhead = now
        guard TranscodeSeekPolicy.isJump(from: previous, to: now) else { return }
        let toStaleClock = staleClock.map { abs($0 - now) < 1.5 } ?? false
        if toStaleClock || settlingUntil.map({ self.now() < $0 }) == true {
            settleRebuiltItem(item, movedTo: now)
            return
        }
        guard TranscodeSeekPolicy.needsRestart(from: previous, to: now, loaded: item.loadedRanges) else {
            noteViewerAction()
            return
        }
        noteViewerAction()
        let plays = player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        restartTranscode(atAbsolute: streamOffset + max(0, now), resumesPlayback: plays, reason: "scrub from \(Int(previous)) to \(Int(now))")
    }

    /// The system player moves a rebuilt item to where its previous item was, as if that were still the
    /// viewer's place: right after it became ready, or later while it stays paused (the paused transport bar
    /// commits the time it still shows). The rebuilt stream already starts at the viewer's place, so the item
    /// goes back to its own start instead of being taken for a scrub that would skip ahead.
    private func settleRebuiltItem(_ item: AVPlayerItem, movedTo seconds: Double) {
        AppLogger.notice("Settling a rebuilt item ratingKey=\(request.ratingKey): the player moved it to \(Int(seconds)) s, back to the start at \(Int(streamOffset))", .playback)
        lastPlayhead = 0
        tracker.moved(to: streamOffset)
        item.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
    }

    /// The end of the item. A transcode that ends short of the credits and of the end of the timeline is a
    /// stream the server cut, not the end of the episode: it is rebuilt at the playhead once, and a second
    /// early end at the same place is shown as a failure, never as the next episode.
    private func handleEnd() {
        guard let stream, !stream.isDirectPlay, request.offline == nil else {
            loadUpNext(reason: .playbackEnded)
            return
        }
        let position = bestKnownPosition
        guard !ItemEndRule.isGenuineEnd(absolute: position, duration: request.durationSecs, creditsStart: creditsStartSecs) else {
            loadUpNext(reason: .playbackEnded)
            return
        }
        guard !isRestarting, !isRecovering else { return }
        if let earlier = prematureEndPosition, abs(earlier - position) < ItemEndRule.endWindow(duration: request.durationSecs) {
            AppLogger.error("The stream ended early twice ratingKey=\(request.ratingKey) position=\(Int(position)) duration=\(Int(request.durationSecs))", .playback)
            emit(.failed("The stream stopped at \(Formatters.timestamp(position)) before the end of the video."))
            return
        }
        prematureEndPosition = position
        AppLogger.notice("The stream ended early ratingKey=\(request.ratingKey) position=\(Int(position)) duration=\(Int(request.durationSecs)); rebuilding it", .playback)
        restartTranscode(atAbsolute: position, resumesPlayback: true, freshSession: true, reason: "early end")
    }

    /// AVPlayer failures are otherwise completely silent (a black screen): every failure is logged with
    /// its real error, a direct-play failure is retried once through the transcoder, and a transcode that
    /// fails soon after the app came back (the server reaped it) is restarted at the viewer's position.
    private func handleFailure(_ message: String) {
        guard !isStopped else { return }
        let wasDirectPlay = stream?.isDirectPlay ?? false
        AppLogger.error("Playback failed ratingKey=\(request.ratingKey) directPlay=\(wasDirectPlay): \(message)", .playback)
        let justReturned = returnedAt.map { Date().timeIntervalSince($0) <= PlaybackFailurePolicy.returnWindow } ?? false
        let gone = liveness?.mayBeGone(at: now()) ?? false
        switch failurePolicy.decide(wasDirectPlay: wasDirectPlay, isOffline: request.offline != nil, justReturned: justReturned || gone) {
        case .ignore:
            break
        case .restartTranscode:
            guard !isRestarting else { return }
            let position = bestKnownPosition
            AppLogger.notice("Restarting the transcode after a failure ratingKey=\(request.ratingKey) position=\(Int(position))", .playback)
            restartTranscode(atAbsolute: position, resumesPlayback: wasPlayingAtLastTick, freshSession: true, reason: "failure after a return")
        case .fail:
            emit(.failed(message))
        case .fallBackToTranscode:
            AppLogger.notice("Retrying via transcode ratingKey=\(request.ratingKey)", .playback)
            itemWatcher?.invalidate()
            itemWatcher = nil
            fallbackTask = Task { [weak self] in await self?.fallBackToTranscode() }
        }
    }

    private func fallBackToTranscode() async {
        let start = StreamPosition.transcodeStart(PlaybackFailurePolicy.fallbackStart(
            lastAbsolute: absolutePosition ?? lastPlayhead + streamOffset,
            resumePosition: request.resumePosition
        ))
        do {
            let resolved = try await StreamResolver.resolve(
                api: api,
                ratingKey: request.ratingKey,
                startSecs: start > 0 ? start : nil,
                selectedSubtitleId: selectedSubtitleId,
                selectedAudioStreamId: selectedAudioStreamId,
                forceTranscode: true
            )
            guard !isStopped, !Task.isCancelled, let player else {
                discardTranscode(of: resolved)
                return
            }
            stream = resolved
            streamOffset = start
            lastPlayhead = 0
            tracker.moved(to: start)
            liveness = TranscodeLiveness(confirmedAt: now())
            startPing(session: resolved.sessionId)
            let item = AVPlayerItem(url: resolved.url)
            configureItem?(item)
            player.replaceCurrentItem(with: item)
            watchCurrentItem()
            player.play()
            AppLogger.notice("Transcode fallback playing ratingKey=\(request.ratingKey)", .playback)
        } catch {
            guard !isStopped else { return }
            AppLogger.error("Transcode fallback failed ratingKey=\(request.ratingKey): \(error.localizedDescription)", .playback)
            failurePolicy.recordFailure()
            emit(.failed(error.localizedDescription))
        }
    }

    /// The server said a transcode session is gone. The one playing is rebuilt at once when the viewer is
    /// watching, and otherwise before it plays again.
    func transcodeGone(session: String?, reason: String) {
        guard let stream, !stream.isDirectPlay, session == stream.sessionId else { return }
        guard !noticeAbsence(trigger: "server answer") else { return }
        liveness?.markGone()
        AppLogger.notice("Transcode session gone ratingKey=\(request.ratingKey) reason=\(reason) playing=\(player?.rate ?? 0 > 0)", .playback)
        guard let player, player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
        heal(reason: reason)
    }

    /// Rebuilds the transcode under a new server session at the true position, within `HealBudget`.
    package func heal(reason: String) {
        guard !isStopped, !isRestarting, !isRecovering, !hasGivenUp, let stream, !stream.isDirectPlay else { return }
        switch heals.ask(at: now()) {
        case .wait:
            return
        case .giveUp:
            hasGivenUp = true
            AppLogger.error("Giving up on healing ratingKey=\(request.ratingKey) after repeated rebuilds: \(reason)", .playback)
            emit(.failed("The server keeps stopping this stream."))
        case .heal:
            let position = bestKnownPosition
            let playing = (player?.rate ?? 0) > 0 || player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
            AppLogger.notice("Healing the transcode ratingKey=\(request.ratingKey) position=\(Int(position)) reason=\(reason)", .playback)
            restartTranscode(atAbsolute: position, resumesPlayback: playing, freshSession: true, reason: "heal: \(reason)")
        }
    }

    /// Restarts the transcode at a new absolute offset. A seek keeps the server session (the server re-keys
    /// the encode); `freshSession` starts a new one and stops the old, for a session the server may have
    /// reaped. The new item replaces the old one once built.
    func restartTranscode(atAbsolute target: Double, resumesPlayback: Bool = true, freshSession: Bool = false, reason: String) {
        guard let stream, player != nil, !isStopped else { return }
        let start = StreamPosition.transcodeStart(target)
        AppLogger.notice("Transcode restart ratingKey=\(request.ratingKey) at=\(Int(start)) fresh=\(freshSession) plays=\(resumesPlayback) queued=\(isRestarting) reason=\(reason)", .playback)
        tracker.beginRebuild(at: start)
        guard !isRestarting else {
            pendingRestart = PendingRestart(
                target: start,
                resumesPlayback: resumesPlayback,
                freshSession: freshSession || (pendingRestart?.freshSession ?? false),
                reason: reason
            )
            return
        }
        isRestarting = true
        restartResumesPlayback = resumesPlayback
        let previous = stream.sessionId
        let sessionId = freshSession ? UUID().uuidString : previous
        Task { [weak self] in
            guard let self else { return }
            let url = await StreamResolver.transcodeRestartURL(
                api: api,
                ratingKey: request.ratingKey,
                offsetSecs: start,
                sessionId: sessionId,
                burnSubtitle: selectedSubtitleId != nil
            )
            guard let url, !isStopped, let current = self.stream else {
                isRestarting = false
                pendingRestart = nil
                tracker.endRebuild()
                finishRecovery()
                return
            }
            selectionCarry = await MediaSelectionCarry.capture(from: player?.currentItem)
            guard !isStopped else { return }
            if sessionId != previous {
                self.stream = current.restarted(url: url, sessionId: sessionId)
                liveness = TranscodeLiveness(confirmedAt: now())
                startPing(session: sessionId)
                discardTranscode(session: previous)
            }
            applyTranscodeRestart(url: url, atAbsolute: start)
        }
    }

    private func applyTranscodeRestart(url: URL, atAbsolute target: Double) {
        guard let player else {
            isRestarting = false
            tracker.endRebuild()
            return
        }
        let previousClock = player.currentItem?.currentTime().seconds ?? 0
        staleClock = previousClock.isFinite && previousClock > TranscodeSeekPolicy.jumpThreshold ? previousClock : nil
        lastPlayhead = 0
        streamOffset = target
        tracker.moved(to: target)
        if pendingRestart == nil { finishRecovery() }
        if !restartResumesPlayback || pendingRestart != nil { player.pause() }

        let item = AVPlayerItem(url: url)
        configureItem?(item)
        restartItemObserver?.invalidate()
        restartItemObserver = item.observe(\.status, options: [.new]) { @Sendable [weak self] observedItem, _ in
            guard observedItem.status != .unknown else { return }
            let ready = observedItem.status == .readyToPlay
            Task { @MainActor in self?.finishRestart(ready: ready) }
        }
        player.replaceCurrentItem(with: item)
        watchCurrentItem()
    }

    private func finishRestart(ready: Bool) {
        guard !isStopped else { return }
        tracker.endRebuild()
        if ready {
            liveness?.confirm(at: now())
            let settled = player?.currentItem?.currentTime().seconds ?? 0
            lastPlayhead = settled.isFinite ? settled : 0
            settlingUntil = now().advanced(by: .seconds(5))
            if let carry = selectionCarry, let item = player?.currentItem {
                selectionCarry = nil
                Task { await carry.apply(to: item) }
            }
            if restartResumesPlayback, pendingRestart == nil { player?.play() }
        }
        isRestarting = false
        pausedSince = player?.rate == 0 ? now() : nil
        restartItemObserver?.invalidate()
        restartItemObserver = nil
        if let pending = pendingRestart {
            pendingRestart = nil
            restartTranscode(atAbsolute: pending.target, resumesPlayback: pending.resumesPlayback, freshSession: pending.freshSession, reason: "queued \(pending.reason)")
        }
    }

    /// Keeps the server's transcode session alive; it reaps sessions that stop pinging. Every answer says
    /// whether the session still exists.
    func startPing(session: String) {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: PlaybackTiming.transcodePingInterval)
                guard !Task.isCancelled, let api = self?.api else { return }
                do {
                    try await api.requestVoid(.pingTranscode(session: session))
                    self?.pingAnswered(session: session)
                } catch APIError.httpError(let status, _) where TranscodeLiveness.isGoneStatus(status) {
                    self?.transcodeGone(session: session, reason: "ping \(status)")
                } catch {
                    continue
                }
            }
        }
    }

    private func pingAnswered(session: String) {
        guard session == stream?.sessionId else { return }
        liveness?.pinged(at: now())
    }
}

extension AVPlayerItem {
    /// The stretches of the item the player has loaded, in seconds of the item's own clock.
    var loadedRanges: [ClosedRange<Double>] {
        loadedTimeRanges.compactMap { value in
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = range.end.seconds
            guard start.isFinite, end.isFinite, end >= start else { return nil }
            return start...end
        }
    }
}

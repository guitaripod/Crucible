import AVFoundation
import CrucibleCore
import Foundation
import MidgarCore

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
        syncSubtitles(on: item)
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
    /// the item is ready to show the new place, are the item settling and not the viewer. A scrub made while a
    /// rebuild is still on its way moves the item still playing, which the session leaves alone, so it becomes the
    /// place the rebuild goes to instead of being lost when the rebuild lands.
    private func handleJump() {
        guard let player else { return }
        if scrubOrigin == nil, !isRestarting { expectPicture(at: player.currentItem?.currentTime().seconds) }
        if player.rate == 0, pausedSince != nil, !isRecovering { pausedSince = now() }
        guard stream?.isDirectPlay == false, scrubOrigin == nil else { return }
        guard !tracker.isHeld, !isRecovering, let item = player.currentItem, item.status == .readyToPlay else { return }
        let now = item.currentTime().seconds
        guard now.isFinite else { return }
        let previous = lastPlayhead
        lastPlayhead = now
        guard TranscodeSeekPolicy.isJump(from: previous, to: now) else { return }
        guard !isRestarting else {
            noteViewerAction()
            restartTranscode(atAbsolute: streamOffset + max(0, now), resumesPlayback: intendsToPlay, reason: "scrub during a rebuild to \(Int(now))")
            return
        }
        if isCarriedOver(now) || settlingUntil.map({ self.now() < $0 }) == true {
            settleRebuiltItem(item, movedTo: now)
            return
        }
        let target = streamOffset + max(0, now)
        let beforeStart = TranscodeSeekPolicy.isBeforeStream(target, streamStart: streamStart)
        guard beforeStart || TranscodeSeekPolicy.needsRestart(from: previous, to: now, loaded: item.loadedRanges) else {
            noteViewerAction()
            return
        }
        noteViewerAction()
        let plays = player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        restartTranscode(atAbsolute: target, resumesPlayback: plays, reason: "scrub from \(Int(previous)) to \(Int(now))")
    }

    /// The viewer put a finger on the scrubber, or let go of it at `landing` on the title's timeline. The system player
    /// moves the playhead under the finger all the way, and a transcode cannot follow that: every move past what it has
    /// loaded would rebuild the stream and swap the item out from under the scrubber. So a transcode is left as it is while
    /// the finger is down, and goes once, to where the finger let go, a moment later (`PlaybackTiming.scrubSettle`). A scrub
    /// counts as the viewer at the controls from the moment it begins.
    package func viewerScrubbing(_ scrubbing: Bool, landing: Double? = nil) {
        scrubSettleTask?.cancel()
        scrubSettleTask = nil
        guard !scrubbing else {
            if scrubOrigin == nil {
                scrubOrigin = lastPlayhead
                viewerNavigated()
            }
            return
        }
        guard scrubOrigin != nil else { return }
        scrubSettleTask = Task { [weak self] in
            try? await Task.sleep(for: PlaybackTiming.scrubSettle)
            guard !Task.isCancelled, let self, let origin = scrubOrigin else { return }
            scrubOrigin = nil
            if stream?.isDirectPlay == true { expectPicture(at: landing) }
            landScrub(from: origin, at: landing)
        }
    }

    /// Takes a transcode to where a scrub ended, when its stream cannot show that place itself: ahead of what it has
    /// loaded, or before where it started encoding. The place is the one the scrubber showed, not the player's clock,
    /// which may still be on its way there; the jump the player reports when it arrives is then no news.
    private func landScrub(from origin: Double, at landing: Double?) {
        guard let player, let item = player.currentItem, stream?.isDirectPlay == false, !isStopped, !tracker.isHeld, !isRecovering else { return }
        let reading = item.currentTime().seconds
        let now = max(0, landing.map { $0 - streamOffset } ?? (reading.isFinite ? reading : origin))
        guard TranscodeSeekPolicy.isJump(from: origin, to: now) else { return }
        lastPlayhead = now
        let target = streamOffset + now
        let rebuilds = isRestarting || TranscodeSeekPolicy.isBeforeStream(target, streamStart: streamStart)
            || TranscodeSeekPolicy.needsRestart(from: origin, to: now, loaded: item.loadedRanges)
        MidgarLog.notice("Scrub let go ratingKey=\(request.ratingKey) from=\(Int(origin + streamOffset)) to=\(Int(target)) playing=\(intendsToPlay) rebuilds=\(rebuilds)", category: .playback)
        guard rebuilds else { return expectPicture(at: now) }
        restartTranscode(atAbsolute: target, resumesPlayback: intendsToPlay, reason: "scrub from \(Int(origin)) to \(Int(now))")
    }

    /// The system player moves a rebuilt item to where its previous item was, as if that were still the
    /// viewer's place: right after it became ready, or later while it stays paused (the paused transport bar
    /// commits the time it still shows when the viewer presses Play, which after a night away can be zero). The
    /// rebuilt stream already starts at the viewer's place, so the item goes back to where it starts on its own
    /// clock (the item's timeline on a Plex server, whose playlist spans the whole item, so never its zero)
    /// instead of being taken for a scrub that would skip ahead or play the episode from its start.
    func settleRebuiltItem(_ item: AVPlayerItem, movedTo seconds: Double) {
        let home = max(0, streamStart - streamOffset)
        MidgarLog.notice("Settling a rebuilt item ratingKey=\(request.ratingKey): the player moved it to \(Int(seconds)) s, back to the start at \(Int(streamStart))", category: .playback)
        lastPlayhead = home
        tracker.moved(to: streamStart)
        item.seek(to: CMTime(seconds: home, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
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
            MidgarLog.error("The stream ended early twice ratingKey=\(request.ratingKey) position=\(Int(position)) duration=\(Int(request.durationSecs))", category: .playback)
            emit(.failed(String(localized: "The stream stopped at \(Formatters.timestamp(position)) before the end of the video.")))
            return
        }
        prematureEndPosition = position
        MidgarLog.notice("The stream ended early ratingKey=\(request.ratingKey) position=\(Int(position)) duration=\(Int(request.durationSecs)); rebuilding it", category: .playback)
        restartTranscode(atAbsolute: position, resumesPlayback: true, freshSession: true, reason: "early end")
    }

    /// AVPlayer failures are otherwise completely silent (a black screen): every failure is logged with
    /// its real error, a direct-play failure is retried once through the transcoder, and a transcode that
    /// fails soon after the app came back (the server reaped it) or after the app moved to another route
    /// (`routeMoved` has rebuilt it) is restarted at the viewer's position. Any other first transcode
    /// failure asks for the routes to be tried before it is reported: when the route in use turns out to be
    /// gone, the move rebuilds the stream on the new route and the failure is dropped. Failures that arrive
    /// while that look runs wait for it.
    private func handleFailure(_ message: String) {
        guard !isStopped, routeCheckTask == nil else { return }
        let wasDirectPlay = stream?.isDirectPlay ?? false
        MidgarLog.error("Playback failed ratingKey=\(request.ratingKey) directPlay=\(wasDirectPlay): \(message)", category: .playback)
        let justReturned = returnedAt.map { Date().timeIntervalSince($0) <= PlaybackFailurePolicy.returnWindow } ?? false
        let gone = liveness?.mayBeGone(at: now()) ?? false
        let moved = ServerRouteMonitor.shared.lastMove.map { Date().timeIntervalSince($0.at) <= PlaybackFailurePolicy.returnWindow } ?? false
        let afterBreak = justReturned || gone || moved
        guard !afterBreak, !wasDirectPlay, request.offline == nil, !hasCheckedRouteAfterFailure else {
            resolveFailure(message, wasDirectPlay: wasDirectPlay, afterBreak: afterBreak)
            return
        }
        hasCheckedRouteAfterFailure = true
        routeCheckTask = Task { [weak self] in
            let decision = await ServerRouteMonitor.shared.checkNow(reason: "playback failed")
            guard let self, !Task.isCancelled, !isStopped else { return }
            routeCheckTask = nil
            if case .move(_, .lost) = decision { return }
            resolveFailure(message, wasDirectPlay: wasDirectPlay, afterBreak: false)
        }
    }

    /// The route the stream came from is gone and the app moved to another: the stream is resolved again at the playhead on the
    /// new route, in the same tracks, so it plays on instead of freezing until AVPlayer gives up on the old address.
    func routeMoved(_ move: ServerRouteMonitor.Move) {
        guard move.reason == .lost, !isStopped, request.offline == nil, player != nil else { return }
        MidgarLog.notice("Rebuilding the stream on the new route ratingKey=\(request.ratingKey) position=\(Int(bestKnownPosition))", category: .playback)
        failurePolicy.noteReturn()
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await changeStreams(StreamChoice(subtitleId: selectedSubtitleId, audioStreamId: selectedAudioStreamId), rebuild: true)
            } catch {
                MidgarLog.error("Rebuilding the stream on the new route failed ratingKey=\(request.ratingKey): \(error.localizedDescription)", category: .playback)
            }
        }
    }

    private func resolveFailure(_ message: String, wasDirectPlay: Bool, afterBreak: Bool) {
        switch failurePolicy.decide(wasDirectPlay: wasDirectPlay, isOffline: request.offline != nil, justReturned: afterBreak) {
        case .ignore:
            break
        case .restartTranscode:
            guard !isRestarting else { return }
            let position = bestKnownPosition
            MidgarLog.notice("Restarting the transcode after a failure ratingKey=\(request.ratingKey) position=\(Int(position))", category: .playback)
            restartTranscode(atAbsolute: position, resumesPlayback: wasPlayingAtLastTick, freshSession: true, reason: "failure after a return or a route move")
        case .fail:
            emit(.failed(message))
        case .fallBackToTranscode:
            MidgarLog.notice("Retrying via transcode ratingKey=\(request.ratingKey)", category: .playback)
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
            tracker.beginStream(start: start, isTranscode: true)
            lastPlayhead = start - streamOffset
            tracker.moved(to: start)
            liveness = TranscodeLiveness(confirmedAt: now())
            startPing(session: resolved.sessionId)
            let item = AVPlayerItem(url: resolved.url)
            SubtitleStyle.apply(to: item)
            configureItem?(item)
            player.replaceCurrentItem(with: item)
            watchCurrentItem()
            player.play()
            MidgarLog.notice("Transcode fallback playing ratingKey=\(request.ratingKey)", category: .playback)
        } catch {
            guard !isStopped else { return }
            MidgarLog.error("Transcode fallback failed ratingKey=\(request.ratingKey): \(error.localizedDescription)", category: .playback)
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
        MidgarLog.notice("Transcode session gone ratingKey=\(request.ratingKey) reason=\(reason) playing=\(player?.rate ?? 0 > 0)", category: .playback)
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
            MidgarLog.error("Giving up on healing ratingKey=\(request.ratingKey) after repeated rebuilds: \(reason)", category: .playback)
            emit(.failed(String(localized: "The server keeps stopping this stream.")))
        case .heal:
            let position = bestKnownPosition
            let playing = (player?.rate ?? 0) > 0 || player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
            MidgarLog.notice("Healing the transcode ratingKey=\(request.ratingKey) position=\(Int(position)) reason=\(reason)", category: .playback)
            restartTranscode(atAbsolute: position, resumesPlayback: playing, freshSession: true, reason: "heal: \(reason)")
        }
    }

    /// Restarts the transcode at a new absolute offset. A seek keeps the server session (the server re-keys
    /// the encode); `freshSession` starts a new one and stops the old, for a session the server may have
    /// reaped. The new item replaces the old one once built.
    func restartTranscode(atAbsolute target: Double, resumesPlayback: Bool = true, freshSession: Bool = false, reason: String) {
        guard let stream, player != nil, !isStopped else { return }
        let start = StreamPosition.transcodeStart(target)
        MidgarLog.notice("Transcode restart ratingKey=\(request.ratingKey) at=\(Int(start)) fresh=\(freshSession) plays=\(resumesPlayback) queued=\(isRestarting) reason=\(reason)", category: .playback)
        if clockShownBeforeRebuild == nil { clockShownBeforeRebuild = bestKnownPosition - streamOffset }
        tracker.beginRebuild(at: start)
        restartTarget = target
        guard !isRestarting else {
            pendingRestart = PendingRestart(
                target: target,
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
        let subtitleDelivery = stream.subtitleDelivery
        Task { [weak self] in
            guard let self else { return }
            await selectionUpdateTask?.value
            let url = await StreamResolver.transcodeRestartURL(
                api: api,
                ratingKey: request.ratingKey,
                offsetSecs: start,
                sessionId: sessionId,
                subtitleDelivery: subtitleDelivery
            )
            guard let url, !isStopped, let current = self.stream, current.sessionId == previous else {
                isRestarting = false
                pendingRestart = nil
                clockShownBeforeRebuild = nil
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
            guard !startPendingRestart() else { return }
            applyTranscodeRestart(url: url, atAbsolute: start, freshSession: sessionId != previous)
        }
    }

    /// Goes straight on to the place asked for while a rebuild was being built, when there is one, instead of first showing the
    /// superseded place: a run of clicks or scrubs during a rebuild ends where the last one asked. Returns whether it did.
    private func startPendingRestart() -> Bool {
        guard let pending = pendingRestart else { return false }
        pendingRestart = nil
        isRestarting = false
        restartTranscode(atAbsolute: pending.target, resumesPlayback: pending.resumesPlayback, freshSession: pending.freshSession, reason: "queued \(pending.reason)")
        return true
    }

    private func applyTranscodeRestart(url: URL, atAbsolute target: Double, freshSession: Bool) {
        guard let player else {
            isRestarting = false
            tracker.endRebuild()
            return
        }
        carriedTimes = CarriedTimes(
            previousClock: player.currentItem?.currentTime().seconds,
            previousPosition: clockShownBeforeRebuild,
            afterAbsence: freshSession
        )
        clockShownBeforeRebuild = nil
        tracker.beginStream(start: target, isTranscode: true)
        lastPlayhead = target - streamOffset
        tracker.moved(to: target)
        if pendingRestart == nil { finishRecovery() }
        if !restartResumesPlayback || pendingRestart != nil { player.pause() }

        let item = AVPlayerItem(url: url)

        SubtitleStyle.apply(to: item)
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
        let settled = player?.currentItem?.currentTime().seconds ?? 0
        if ready, settled.isFinite, !isStaleReading(settled) {
            learnClock(from: settled)
        }
        tracker.endRebuild()
        if ready {
            liveness?.confirm(at: now())
            lastPlayhead = settled.isFinite ? settled : streamStart - streamOffset
            settlingUntil = now().advanced(by: .seconds(5))
            if let carry = selectionCarry, let item = player?.currentItem {
                selectionCarry = nil
                Task { await carry.apply(to: item) }
            }
            if pendingRestart == nil, let target = restartTarget, let landed = absolutePosition,
               let exact = StreamPosition.landingCorrection(target: target, landed: landed), let player {
                let plays = restartResumesPlayback
                MidgarLog.notice("Transcode rebuild ratingKey=\(request.ratingKey) opened at \(landed), seeking on to \(exact)", category: .playback)
                tracker.moved(to: exact)
                lastPlayhead = exact - streamOffset
                expectPicture(at: exact - streamOffset)
                player.seek(to: CMTime(seconds: exact - streamOffset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { @Sendable [weak self] _ in
                    Task { @MainActor in
                        guard plays, let self, !self.isStopped, self.pendingRestart == nil else { return }
                        self.player?.play()
                    }
                }
            } else if restartResumesPlayback, pendingRestart == nil {
                expectPicture()
                player?.play()
            }
            restartTarget = nil
        }
        isRestarting = false
        pausedSince = player?.rate == 0 ? now() : nil
        restartItemObserver?.invalidate()
        restartItemObserver = nil
        _ = startPendingRestart()
    }

    /// Whether a rebuilt item's first reading is a time the system carried over from the previous item rather than where the
    /// new stream starts, which says nothing about how the new clock reads. Zero is left to the clock to explain: a server whose
    /// playlist begins at the offset reads zero at its start.
    private func isStaleReading(_ reading: Double) -> Bool {
        let tolerance = CarriedTimes.tolerance
        guard reading > tolerance, abs(reading - streamStart) > tolerance, let carriedTimes else { return false }
        return carriedTimes.times.contains { abs($0 - reading) < tolerance }
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

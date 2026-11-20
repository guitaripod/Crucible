import AVFoundation
import CrucibleCore
import Foundation
import MidgarCore

extension PlaybackSession {
    /// Moves the playhead to a position on the item's timeline and plays: an exact seek on a direct-play file
    /// and inside a transcode's own stream (back, or ahead into what it has loaded), a new transcoder offset
    /// for anywhere else.
    package func seek(toAbsolute target: Double) {
        move(toAbsolute: target, plays: true, reason: "seek")
    }

    /// Moves the playhead `seconds` along the item's timeline (back when negative), keeping the player playing
    /// or paused as it was.
    package func move(by seconds: Double, reason: String) {
        guard player != nil else { return }
        let upper = request.durationSecs > 0 ? max(0, request.durationSecs - 1) : Double.infinity
        move(toAbsolute: min(max(0, bestKnownPosition + seconds), upper), plays: intendsToPlay, reason: reason)
    }

    /// A click on the left or right of the remote: the playhead moves the distance the viewer chose for that side, from where
    /// the viewer really is, playing or paused as it was. Clicks made in quick succession add up, and so do clicks made while a
    /// transcode is still being rebuilt for the one before.
    package func skip(_ direction: SkipRule.Direction) {
        guard stream != nil, player != nil else { return }
        let seconds = direction == .back ? Preferences.skipBackSeconds : Preferences.skipForwardSeconds
        let from = bestKnownPosition
        let target = SkipRule.target(from: from, direction: direction, seconds: seconds, duration: request.durationSecs)
        MidgarLog.notice("Click \(direction) \(seconds) s ratingKey=\(request.ratingKey) from=\(Int(from)) to=\(Int(target))", category: .playback)
        viewerNavigated()
        move(toAbsolute: target, plays: intendsToPlay, reason: "click \(direction)")
    }

    /// The viewer moved the playhead themselves (a click, a scrub or a scan): they are at the remote, an automatic skip they
    /// moved away from can no longer be taken back, and a rebuilt item's settling window no longer applies, so a scrub made
    /// right after a rebuild is honoured instead of being taken for the system putting the old item's time back.
    package func viewerNavigated() {
        noteViewerAction()
        settlingUntil = nil
        guard isUndoVisible else { return }
        endUndoWindow()
        emit(.autoSkipUndoExpired)
    }

    /// Whether playback should go on after the session moves the player: what the player is doing now, or, while a transcode
    /// is rebuilt, what the rebuild was asked to do, since the session pauses the player itself while it waits.
    var intendsToPlay: Bool {
        if isRestarting { return pendingRestart?.resumesPlayback ?? restartResumesPlayback }
        guard let player else { return false }
        return player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    /// Goes back to the very start of the item, playing or paused as the player was.
    package func startOver() {
        guard let player else { return }
        noteViewerAction()
        move(toAbsolute: 0, plays: player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate, reason: "start over")
    }

    /// Moves the player to `target` on the item's timeline. A direct-play file and a transcode that already holds the place seek
    /// exactly; anywhere else, and anything asked while a transcode is still being rebuilt, goes to a rebuild, which takes the
    /// latest of several asked in a row. `plays` starts playback once there, except after a pause the viewer made while the
    /// player was on its way.
    func move(toAbsolute target: Double, plays: Bool, reason: String) {
        guard let stream, let player else { return }
        let playerTime = stream.isDirectPlay ? target : target - streamOffset
        guard stream.isDirectPlay || (!isRestarting && canSeekInStream(toAbsolute: target, playerTime: playerTime)) else {
            restartTranscode(atAbsolute: target, resumesPlayback: plays, reason: reason)
            return
        }
        tracker.moved(to: target)
        if !stream.isDirectPlay { lastPlayhead = playerTime }
        let wasPlaying = player.rate > 0
        player.seek(to: CMTime(seconds: playerTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { @Sendable [weak self] _ in
            Task { @MainActor in self?.playAfterSeek(asked: plays, wasPlaying: wasPlaying) }
        }
    }

    /// Plays once a seek has landed when the move asked for it. A player that was playing when the seek began and stands paused
    /// now was paused by the viewer on the way, and stays paused.
    private func playAfterSeek(asked plays: Bool, wasPlaying: Bool) {
        guard plays, !isStopped, let player else { return }
        if wasPlaying, player.rate == 0 { return }
        player.play()
    }

    /// Whether the transcode's current stream can show `target` itself: it is not before where the stream started
    /// encoding, and it is behind the playhead or inside what the player has loaded.
    private func canSeekInStream(toAbsolute target: Double, playerTime: Double) -> Bool {
        guard playerTime >= 0, !TranscodeSeekPolicy.isBeforeStream(target, streamStart: streamStart),
              let item = player?.currentItem, item.status == .readyToPlay else { return false }
        let now = item.currentTime().seconds
        return !TranscodeSeekPolicy.needsRestart(from: now.isFinite ? now : 0, to: playerTime, loaded: item.loadedRanges)
    }

    /// Takes back an automatic skip: returns to where the playhead was when the marker was skipped.
    package func undoAutoSkip(returnTo position: Double) {
        endUndoWindow()
        seek(toAbsolute: position)
    }

    /// Tells the session whether the surface is showing its Up Next card, which holds back skip
    /// controls and automatic skips while it is up.
    package func setUpNextVisible(_ visible: Bool) {
        isUpNextVisible = visible
        if visible { endUndoWindow() }
    }

    /// Looks up the next episode on request, such as a next-track button. Answers with `.upNext`.
    package func requestUpNext() {
        loadUpNext(reason: .requested)
    }

    /// Starts playback once the item is at the place playback should start from. For a surface that prepared
    /// this player behind the episode before it: a plain start plays at once, and one whose resume seek is
    /// still on its way plays when it lands instead of showing a moment of the item's start.
    package func startWhenResumed() {
        guard let player else { return }
        switch ResumeStrategy.make(
            resumePosition: request.resumePosition,
            isDirectPlay: stream?.isDirectPlay ?? true,
            isOffline: request.offline != nil
        ) {
        case .none:
            player.play()
        case .seekExact(let position), .seekWhenReady(let position):
            let landed = player.currentItem?.status == .readyToPlay
                && abs(player.currentTime().seconds - position) < PlaybackTiming.resumeLandedTolerance
            if landed {
                player.play()
            } else {
                playsAfterResume = true
            }
        }
    }

    func startPlayback(player: AVPlayer, stream: ResolvedStream, resumePosition: Double, autoplay: Bool) {
        switch ResumeStrategy.make(
            resumePosition: resumePosition,
            isDirectPlay: stream.isDirectPlay,
            isOffline: request.offline != nil
        ) {
        case .none:
            if autoplay { player.play() }
        case .seekExact(let position):
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { @Sendable [weak self] _ in
                Task { @MainActor in self?.playIfAsked(autoplay: autoplay) }
            }
        case .seekWhenReady(let position):
            seekWhenReady(to: position, autoplay: autoplay)
        }
    }

    /// Plays after a resume seek when the viewer or the surface asked for playback.
    private func playIfAsked(autoplay: Bool) {
        if autoplay || playsAfterResume { player?.play() }
        playsAfterResume = false
    }

    /// Downloaded HLS only accepts seeks at segment boundaries once the item is ready, so resume waits
    /// for `.readyToPlay` and seeks with tolerance instead of the exact seek of a direct-play file. A
    /// player that is being prepared behind the episode before it stays paused until its surface plays it.
    private func seekWhenReady(to position: Double, autoplay: Bool) {
        guard let item = player?.currentItem else {
            if autoplay { player?.play() }
            return
        }
        offlineResumeObserver?.invalidate()
        offlineResumeObserver = item.observe(\.status, options: [.new]) { @Sendable [weak self] observedItem, _ in
            guard observedItem.status != .unknown else { return }
            let ready = observedItem.status == .readyToPlay
            Task { @MainActor in self?.resumeOffline(to: position, ready: ready, autoplay: autoplay) }
        }
    }

    private func resumeOffline(to position: Double, ready: Bool, autoplay: Bool) {
        offlineResumeObserver?.invalidate()
        offlineResumeObserver = nil
        guard ready else {
            if autoplay { player?.play() }
            return
        }
        player?.seek(
            to: CMTime(seconds: position, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: ResumeStrategy.offlineToleranceBefore, preferredTimescale: 600),
            toleranceAfter: .positiveInfinity
        ) { @Sendable [weak self] _ in
            Task { @MainActor in self?.playIfAsked(autoplay: autoplay) }
        }
    }

    func observePlayhead(of player: AVPlayer) {
        playheadObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 1),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            guard seconds.isFinite, seconds >= 0 else { return }
            Task { @MainActor in self?.playheadMoved(to: seconds) }
        }
    }

    /// Follows the player between paused and playing, which is how the session knows how long a pause lasted
    /// and when the viewer asks to play again.
    func observeRate(of player: AVPlayer) {
        rateObserver = player.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] observed, _ in
            let status = observed.timeControlStatus
            Task { @MainActor in self?.timeControlChanged(to: status) }
        }
    }

    private func timeControlChanged(to status: AVPlayer.TimeControlStatus) {
        guard !isStopped else { return }
        carriedTimes?.noteRate(playing: status == .playing, at: now())
        tellWatchers(status)
        guard !noticeAbsence(trigger: "player state") else { return }
        switch status {
        case .paused:
            if isRestarting { keepPausedThroughRebuild() }
            if pausedSince == nil, !isRestarting, !isChangingStreams { pausedSince = now() }
            noteViewerAction()
        case .playing, .waitingToPlayAtSpecifiedRate:
            guard let since = pausedSince else { return }
            pausedSince = nil
            noteViewerAction()
            resumeAfterPause(since.duration(to: now()))
        @unknown default:
            break
        }
    }

    /// A pause while a transcode is being rebuilt, on the item still playing: the session only pauses the player itself once
    /// the new item is in, so this is the viewer (or the sleep timer), and the rebuilt stream stays paused instead of starting
    /// when it is ready. An item that played to its end pauses on its own and says nothing about the viewer.
    private func keepPausedThroughRebuild() {
        guard !isRecovering, let item = player?.currentItem, item.status == .readyToPlay else { return }
        let duration = item.duration.seconds
        guard !duration.isFinite || item.currentTime().seconds < duration - 1 else { return }
        restartResumesPlayback = false
        pendingRestart?.resumesPlayback = false
    }

    /// Tells the integrations the viewer played or paused, but not the pauses the session makes itself to restart a
    /// transcode, recover a stream or change tracks: those are not the viewer's.
    private func tellWatchers(_ status: AVPlayer.TimeControlStatus) {
        guard !watchers.isEmpty, !isRestarting, !isRecovering, !isChangingStreams, let position = absolutePosition else { return }
        switch status {
        case .playing: watchers.forEach { $0.playback(.playing(position: position)) }
        case .paused: watchers.forEach { $0.playback(.paused(position: position)) }
        default: break
        }
    }

    /// Tells the surface the viewer did something, unless the change was the session's own (a recovery or a
    /// restart), the system's (the app going away) or the end of the item.
    func noteViewerAction() {
        guard isInForeground, !isRecovering, !isRestarting, !isSuspended, !tracker.isHeld else { return }
        if let item = player?.currentItem {
            let duration = item.duration.seconds
            if duration.isFinite, item.currentTime().seconds >= duration - 2 { return }
        }
        emit(.viewerActed)
    }

    /// The viewer plays again after a pause. A transcode the server may have reaped meanwhile is rebuilt under
    /// a new session before it plays, and a pause long enough to be a break backs up a little first
    /// (`BreakRule`), so the viewer is back in the scene.
    private func resumeAfterPause(_ pause: Duration) {
        guard !isRecovering, !isRestarting, !isSuspended, let stream else { return }
        let rewind = Preferences.rewindAfterBreak ? BreakRule.rewind(after: pause) : 0
        let gone = liveness?.mayBeGone(at: now()) ?? false
        guard rewind > 0 || gone else { return }
        let snapshot = bestKnownPosition
        let target = BreakRule.target(snapshot: snapshot, rewind: rewind, markers: stream.segments)
        MidgarLog.notice("Playing after a pause ratingKey=\(request.ratingKey) pause=\(Int(pause.seconds))s position=\(Int(snapshot)) target=\(Int(target)) sessionGone=\(gone)", category: .playback)
        if stream.isDirectPlay {
            seekAfterReturn(to: target, resumesPlayback: true)
        } else if gone {
            restartTranscode(atAbsolute: target, resumesPlayback: true, freshSession: true, reason: "play after a pause")
        } else {
            move(toAbsolute: target, plays: true, reason: "play after a pause")
        }
    }

    /// A tick of the player's clock. A transcode's clock means nothing until its item is ready (it reads zero), so those
    /// ticks are dropped instead of placing the viewer, the skip markers and the credits at the start of the item. While a
    /// transcode is rebuilt the old item still plays from before the move, so its ticks neither save a position nor bring
    /// back the skip button the viewer just took.
    private func playheadMoved(to seconds: Double) {
        guard !isStopped, let player, !noticeAbsence(trigger: "playhead") else { return }
        let ready = isItemReady
        guard ready || stream?.isDirectPlay != false else { return }
        if player.timeControlStatus == .playing { carriedTimes?.noteRate(playing: true, at: now()) }
        if ready, !isRestarting, isCarriedOver(seconds), let item = player.currentItem {
            settleRebuiltItem(item, movedTo: seconds)
            return
        }
        let offset = streamOffset
        tracker.observe(playerSeconds: seconds, isReady: ready)
        if streamOffset != offset { clockRemapped(reading: seconds) }
        lastPlayhead = seconds
        let absolute = seconds + streamOffset
        if !tracker.isHeld { wasPlayingAtLastTick = player.rate > 0 }
        guard !isRestarting else { return }
        if !tracker.isHeld, ready { keepPosition(absolute, force: false) }
        emit(.position(absolute: absolute, rate: Double(player.rate)))
        if upNext.creditsReached(at: absolute) { loadUpNext(reason: .credits) }
        evaluateMarkers(at: absolute)
    }

    /// Learns how a rebuilt transcode's clock reads from its reading once ready, and tells the surface when that moved it.
    func learnClock(from reading: Double) {
        guard tracker.learnClock(reading: reading) else { return }
        clockRemapped(reading: reading)
    }

    /// The transcode's clock reads differently from what the session assumed: the surface places again whatever it put
    /// on the player's clock, such as chapters and an Up Next proposal.
    private func clockRemapped(reading: Double) {
        MidgarLog.notice("Transcode clock ratingKey=\(request.ratingKey) reads \(tracker.clock == .itemTimeline ? "the item's timeline" : "from the stream's start"): start=\(Int(streamStart)) reading=\(Int(reading)) offset=\(Int(streamOffset))", category: .playback)
        emit(.clockRemapped)
    }

    private func evaluateMarkers(at absolute: Double) {
        let action = markerTracker.evaluate(
            absolute: absolute,
            mode: Preferences.skipIntroMode,
            outroMode: Preferences.skipOutroMode,
            upNextVisible: isUpNextVisible,
            undoVisible: isUndoVisible
        )
        switch action {
        case .none:
            break
        case .hideSkip:
            emit(.skipHidden)
        case .showSkip(let marker, let progress):
            emit(.skipAvailable(marker, progress: progress))
        case .autoSkip(let marker):
            autoSkip(marker, from: absolute)
        }
    }

    /// Jumps past a marker and opens the window in which the skip can be taken back.
    private func autoSkip(_ marker: SkipMarker, from absolute: Double) {
        seek(toAbsolute: marker.endSecs)
        beginUndoWindow()
        emit(.autoSkipped(marker, returnTo: absolute))
    }

    private func beginUndoWindow() {
        undoTask?.cancel()
        isUndoVisible = true
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: PlaybackTiming.autoSkipUndoWindow)
            guard !Task.isCancelled, let self else { return }
            self.isUndoVisible = false
            self.undoTask = nil
            self.emit(.autoSkipUndoExpired)
        }
    }

    private func endUndoWindow() {
        undoTask?.cancel()
        undoTask = nil
        isUndoVisible = false
    }

    func loadUpNext(reason: UpNextOffer.Reason) {
        guard !isStopped else { return }
        guard upNext.canOfferNext else {
            if reason == .playbackEnded {
                emit(.finished(.standalone))
                if stopsAtEndOfItem { fallAsleep() }
            }
            return
        }
        guard upNextGate.begin(reason) else { return }
        upNextTask?.cancel()
        let resolver = upNext
        upNextTask = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { upNextGate.end(reason) } }
            let lookup = await Self.lookUpOffer(resolver: resolver, api: api, reason: reason)
            guard !Task.isCancelled else { return }
            switch lookup {
            case .offer(let offer):
                upNextOutcome = .offer(offer)
                emit(.upNext(stopsAtEndOfItem ? offer.withoutAutoplay() : offer))
            case .nothingNext:
                upNextOutcome = .nothingNext
                if reason == .playbackEnded { emit(.finished(.noNextEpisode)) }
            case .failed:
                if reason == .playbackEnded { emit(.finished(.noNextEpisode)) }
            }
            if reason == .playbackEnded, stopsAtEndOfItem { fallAsleep() }
        }
    }

    /// Asks for the next episode, trying once more when the request fails: the credits are a short window
    /// and one dropped request there means no card at all, not a card a moment later.
    static func lookUpOffer(resolver: UpNextResolver, api: APIClient, reason: UpNextOffer.Reason) async -> UpNextLookup {
        for attempt in 0..<2 {
            if attempt > 0 {
                MidgarLog.notice("Up Next lookup failed; trying once more", category: .playback)
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return .failed }
            }
            do {
                return try await resolver.loadOffer(api: api, reason: reason).map(UpNextLookup.offer) ?? .nothingNext
            } catch {
                MidgarLog.error("Up Next lookup failed: \(error.localizedDescription)", category: .playback)
            }
        }
        return .failed
    }

    func configureRemoteCommands() {
        remoteCommands = PlaybackRemoteCommands(supportsNextTrack: request.isEpisode || request.queue?.hasNext == true) { [weak self] action in
            self?.perform(action)
        }
    }

    private func perform(_ action: PlaybackRemoteCommands.Action) {
        guard let player else { return }
        switch action {
        case .play:
            player.play()
        case .pause:
            player.pause()
        case .togglePlayPause:
            if player.timeControlStatus == .playing { player.pause() } else { player.play() }
        case .skip(let delta):
            noteViewerAction()
            move(by: delta, reason: "remote skip")
        case .seek(let position):
            if stream?.isDirectPlay == false {
                restartTranscode(atAbsolute: position, reason: "remote seek")
            } else {
                player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
            }
        case .nextTrack:
            loadUpNext(reason: .requested)
        case .rate(let rate):
            noteViewerAction()
            player.defaultRate = rate
            if player.rate > 0 { player.rate = rate }
        }
    }

    func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo
            let typeValue = info?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = info?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in
                guard let self,
                      let typeValue,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

                MidgarLog.notice("Audio interruption \(type == .began ? "began" : "ended") ratingKey=\(self.request.ratingKey) playerRate=\(self.player?.rate ?? -1)", category: .playback)
                if type == .began {
                    self.playingBeforeInterruption = self.wasPlayingAtLastTick || (self.player?.rate ?? 0) > 0
                } else if let optionsValue {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume), self.playingBeforeInterruption {
                        try? AVAudioSession.sharedInstance().setActive(true)
                        self.player?.play()
                    }
                    self.playingBeforeInterruption = false
                }
            }
        }
    }
}

/// What looking for the next episode found: one to offer, none at all, or no answer from the server.
package enum UpNextLookup: Sendable {
    case offer(UpNextOffer)
    case nothingNext
    case failed
}

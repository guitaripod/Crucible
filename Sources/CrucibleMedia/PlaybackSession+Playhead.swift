import AVFoundation
import CrucibleCore
import Foundation

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
        guard let player else { return }
        let plays = player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let upper = request.durationSecs > 0 ? max(0, request.durationSecs - 1) : Double.infinity
        move(toAbsolute: min(max(0, bestKnownPosition + seconds), upper), plays: plays, reason: reason)
    }

    /// Goes back to the very start of the item, playing or paused as the player was.
    package func startOver() {
        guard let player else { return }
        noteViewerAction()
        move(toAbsolute: 0, plays: player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate, reason: "start over")
    }

    /// The viewer clicked left or right on the remote, which the system player turned into its ten-second skip
    /// from `playerTime`. Returns the player time to seek to instead, for the distance the viewer chose; a skip
    /// back past the start of a transcode's stream returns `playerTime` and restarts the transcode there.
    package func click(_ direction: SkipRule.Direction, fromPlayerTime playerTime: Double) -> Double {
        guard let stream, let player else { return playerTime }
        let seconds = direction == .back ? Preferences.skipBackSeconds : Preferences.skipForwardSeconds
        let offset = stream.isDirectPlay ? 0 : streamOffset
        let target = SkipRule.target(from: offset + playerTime, direction: direction, seconds: seconds, duration: request.durationSecs)
        AppLogger.notice("Click \(direction) \(seconds) s ratingKey=\(request.ratingKey) from=\(Int(offset + playerTime)) to=\(Int(target))", .playback)
        noteViewerAction()
        staleClock = nil
        settlingUntil = nil
        tracker.moved(to: target)
        guard target - offset < 0 else {
            if !stream.isDirectPlay { lastPlayhead = target - offset }
            return target - offset
        }
        let plays = player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        restartTranscode(atAbsolute: target, resumesPlayback: plays, reason: "click back past the stream's start")
        return playerTime
    }

    func move(toAbsolute target: Double, plays: Bool, reason: String) {
        guard let stream, let player else { return }
        let playerTime = stream.isDirectPlay ? target : target - streamOffset
        guard stream.isDirectPlay || canSeekInStream(toPlayerTime: playerTime) else {
            restartTranscode(atAbsolute: target, resumesPlayback: plays, reason: reason)
            return
        }
        tracker.moved(to: target)
        if !stream.isDirectPlay { lastPlayhead = playerTime }
        player.seek(to: CMTime(seconds: playerTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { @Sendable [weak self] _ in
            Task { @MainActor in if plays { self?.player?.play() } }
        }
    }

    /// Whether the transcode's current stream can show `playerTime` itself: it is not before the stream's
    /// start, and it is behind the playhead or inside what the player has loaded.
    private func canSeekInStream(toPlayerTime playerTime: Double) -> Bool {
        guard playerTime >= 0, let item = player?.currentItem, item.status == .readyToPlay else { return false }
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
        guard !isStopped, !noticeAbsence(trigger: "player state") else { return }
        switch status {
        case .paused:
            if pausedSince == nil, !isRestarting { pausedSince = now() }
            noteViewerAction()
        case .playing, .waitingToPlayAtSpecifiedRate:
            if status == .playing { staleClock = nil }
            guard let since = pausedSince else { return }
            pausedSince = nil
            noteViewerAction()
            resumeAfterPause(since.duration(to: now()))
        @unknown default:
            break
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
        let target = BreakRule.target(snapshot: snapshot, rewind: rewind, markers: stream.markers.map(SkipMarker.init))
        AppLogger.notice("Playing after a pause ratingKey=\(request.ratingKey) pause=\(Int(pause.seconds))s position=\(Int(snapshot)) target=\(Int(target)) sessionGone=\(gone)", .playback)
        if stream.isDirectPlay {
            seekAfterReturn(to: target, resumesPlayback: true)
        } else {
            restartTranscode(atAbsolute: target, resumesPlayback: true, freshSession: gone, reason: "play after a pause")
        }
    }

    private func playheadMoved(to seconds: Double) {
        guard !isStopped, let player, !noticeAbsence(trigger: "playhead") else { return }
        lastPlayhead = seconds
        let absolute = seconds + streamOffset
        tracker.observe(playerSeconds: seconds, isReady: isItemReady)
        if !tracker.isHeld { wasPlayingAtLastTick = player.rate > 0 }
        if !tracker.isHeld, isItemReady { keepPosition(absolute, force: false) }
        emit(.position(absolute: absolute, rate: Double(player.rate)))
        if upNext.creditsReached(at: absolute) { loadUpNext(reason: .credits) }
        evaluateMarkers(at: absolute)
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
            if reason == .playbackEnded { emit(.finished(.standalone)) }
            return
        }
        guard upNextGate.begin(reason) else { return }
        upNextTask?.cancel()
        let resolver = upNext
        upNextTask = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { upNextGate.end(reason) } }
            let offer = await Self.lookUpOffer(resolver: resolver, api: api, reason: reason)
            guard !Task.isCancelled else { return }
            if let offer {
                emit(.upNext(offer))
            } else if reason == .playbackEnded {
                emit(.finished(.noNextEpisode))
            }
        }
    }

    /// Asks for the next episode, trying once more when the request fails: the credits are a short window
    /// and one dropped request there means no card at all, not a card a moment later.
    private static func lookUpOffer(resolver: UpNextResolver, api: APIClient, reason: UpNextOffer.Reason) async -> UpNextOffer? {
        for attempt in 0..<2 {
            if attempt > 0 {
                AppLogger.notice("Up Next lookup failed; trying once more", .playback)
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return nil }
            }
            do {
                return try await resolver.loadOffer(api: api, reason: reason)
            } catch {
                AppLogger.error("Up Next lookup failed: \(error.localizedDescription)", .playback)
            }
        }
        return nil
    }

    func configureRemoteCommands() {
        remoteCommands = PlaybackRemoteCommands(supportsNextTrack: request.isEpisode) { [weak self] action in
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

                AppLogger.notice("Audio interruption \(type == .began ? "began" : "ended") ratingKey=\(self.request.ratingKey) playerRate=\(self.player?.rate ?? -1)", .playback)
                if type == .ended, let optionsValue {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) {
                        try? AVAudioSession.sharedInstance().setActive(true)
                        self.player?.play()
                    }
                }
            }
        }
    }
}

import AVFoundation
import CrucibleCore
import Foundation

extension PlaybackSession {
    /// Moves the playhead to a position on the item's timeline: an exact seek on a direct-play file,
    /// a new transcoder offset on a transcode.
    package func seek(toAbsolute target: Double) {
        guard let stream, let player else { return }
        tracker.moved(to: target)
        if stream.isDirectPlay {
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { @Sendable [weak self] _ in
                Task { @MainActor in self?.player?.play() }
            }
        } else {
            restartTranscode(atAbsolute: target, reason: "seek")
        }
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
                guard autoplay else { return }
                Task { @MainActor in self?.player?.play() }
            }
        case .seekWhenReady(let position):
            seekWhenReady(to: position)
        }
    }

    /// Downloaded HLS only accepts seeks at segment boundaries once the item is ready, so resume waits
    /// for `.readyToPlay` and seeks with tolerance instead of the exact seek of a direct-play file.
    private func seekWhenReady(to position: Double) {
        guard let item = player?.currentItem else {
            player?.play()
            return
        }
        offlineResumeObserver?.invalidate()
        offlineResumeObserver = item.observe(\.status, options: [.new]) { @Sendable [weak self] observedItem, _ in
            guard observedItem.status != .unknown else { return }
            let ready = observedItem.status == .readyToPlay
            Task { @MainActor in self?.resumeOffline(to: position, ready: ready) }
        }
    }

    private func resumeOffline(to position: Double, ready: Bool) {
        offlineResumeObserver?.invalidate()
        offlineResumeObserver = nil
        guard ready else {
            player?.play()
            return
        }
        player?.seek(
            to: CMTime(seconds: position, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: ResumeStrategy.offlineToleranceBefore, preferredTimescale: 600),
            toleranceAfter: .positiveInfinity
        ) { @Sendable [weak self] _ in
            Task { @MainActor in self?.player?.play() }
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
        switch status {
        case .paused:
            if pausedSince == nil, !isRestarting { pausedSince = now() }
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
            seek(toAbsolute: target)
        } else {
            restartTranscode(atAbsolute: target, resumesPlayback: true, freshSession: gone, reason: "play after a pause")
        }
    }

    private func playheadMoved(to seconds: Double) {
        guard !isStopped, let player else { return }
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
            let offer: UpNextOffer?
            do {
                offer = try await resolver.loadOffer(api: api, reason: reason)
            } catch {
                offer = nil
            }
            guard !Task.isCancelled else { return }
            if let offer {
                emit(.upNext(offer))
            } else if reason == .playbackEnded {
                emit(.finished(.noNextEpisode))
            }
        }
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
            player.seek(to: CMTime(seconds: max(0, player.currentTime().seconds + delta), preferredTimescale: 600))
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

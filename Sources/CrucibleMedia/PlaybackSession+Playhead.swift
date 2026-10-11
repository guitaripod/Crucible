import AVFoundation
import CrucibleCore
import Foundation

extension PlaybackSession {
    /// Moves the playhead to a position on the item's timeline: an exact seek on a direct-play file,
    /// a new transcoder offset on a transcode.
    package func seek(toAbsolute target: Double) {
        guard let stream, let player else { return }
        if stream.isDirectPlay {
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { @Sendable [weak self] _ in
                Task { @MainActor in self?.player?.play() }
            }
        } else {
            restartTranscode(atAbsolute: target)
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

    func startPlayback(player: AVPlayer, stream: ResolvedStream, resumePosition: Double) {
        switch ResumeStrategy.make(
            resumePosition: resumePosition,
            isDirectPlay: stream.isDirectPlay,
            isOffline: request.offline != nil
        ) {
        case .none:
            player.play()
        case .seekExact(let position):
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { @Sendable [weak self] _ in
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

    private func playheadMoved(to seconds: Double) {
        guard !isStopped, let player else { return }
        lastPlayhead = seconds
        let absolute = seconds + streamOffset
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
        if upNextReason == .playbackEnded, reason != .playbackEnded { return }
        upNextTask?.cancel()
        upNextReason = reason
        let resolver = upNext
        upNextTask = Task { [weak self] in
            guard let self else { return }
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
                restartTranscode(atAbsolute: position)
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

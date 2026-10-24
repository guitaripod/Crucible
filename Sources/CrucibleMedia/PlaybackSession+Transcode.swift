import AVFoundation
import CrucibleCore
import Foundation

extension PlaybackSession {
    func watchCurrentItem() {
        itemWatcher?.invalidate()
        itemWatcher = nil
        guard let item = player?.currentItem, let stream else { return }
        itemWatcher = PlayerItemWatcher(item: item, observesJumps: !stream.isDirectPlay) { [weak self] event in
            self?.handle(event)
        }
    }

    private func handle(_ event: PlayerItemWatcher.Event) {
        switch event {
        case .ended:
            loadUpNext(reason: .playbackEnded)
        case .failed(let message):
            handleFailure(message)
        case .jumped:
            handleJump()
        }
    }

    private func handleJump() {
        guard !tracker.isHeld, let item = player?.currentItem else { return }
        let now = item.currentTime().seconds
        guard now.isFinite else { return }
        let previous = lastPlayhead
        lastPlayhead = now
        guard TranscodeSeekPolicy.isJump(from: previous, to: now) else { return }
        restartTranscode(atAbsolute: streamOffset + max(0, now))
    }

    /// AVPlayer failures are otherwise completely silent (a black screen): every failure is logged with
    /// its real error, a direct-play failure is retried once through the transcoder, and a transcode that
    /// fails soon after the app came back (the server reaped it) is restarted at the viewer's position.
    private func handleFailure(_ message: String) {
        guard !isStopped else { return }
        let wasDirectPlay = stream?.isDirectPlay ?? false
        AppLogger.error("Playback failed ratingKey=\(request.ratingKey) directPlay=\(wasDirectPlay): \(message)", .playback)
        let justReturned = returnedAt.map { Date().timeIntervalSince($0) <= PlaybackFailurePolicy.returnWindow } ?? false
        switch failurePolicy.decide(wasDirectPlay: wasDirectPlay, isOffline: request.offline != nil, justReturned: justReturned) {
        case .ignore:
            break
        case .restartTranscode:
            let position = absolutePosition ?? lastPlayhead + streamOffset
            AppLogger.notice("Restarting the transcode after the return ratingKey=\(request.ratingKey) position=\(Int(position))", .playback)
            restartTranscode(atAbsolute: position, resumesPlayback: false)
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
        let start = PlaybackFailurePolicy.fallbackStart(
            lastAbsolute: absolutePosition ?? lastPlayhead + streamOffset,
            resumePosition: request.resumePosition
        )
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

    /// Restarts the transcode at a new absolute offset under the same session: the server re-keys the
    /// encode and the new item replaces the old one once built.
    func restartTranscode(atAbsolute target: Double, resumesPlayback: Bool = true) {
        guard let stream, player != nil, !isStopped else { return }
        tracker.moved(to: target)
        guard !isRestarting else {
            pendingRestartTarget = target
            return
        }
        isRestarting = true
        restartResumesPlayback = resumesPlayback
        Task { [weak self] in
            guard let self else { return }
            let url = await StreamResolver.transcodeRestartURL(
                api: api,
                ratingKey: request.ratingKey,
                offsetSecs: target,
                sessionId: stream.sessionId,
                burnSubtitle: selectedSubtitleId != nil
            )
            guard let url, !isStopped else {
                isRestarting = false
                pendingRestartTarget = nil
                finishRecovery()
                return
            }
            applyTranscodeRestart(url: url, atAbsolute: target)
        }
    }

    private func applyTranscodeRestart(url: URL, atAbsolute target: Double) {
        guard let player else {
            isRestarting = false
            return
        }
        lastPlayhead = 0
        streamOffset = target
        tracker.moved(to: target)
        finishRecovery()

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
        if ready, restartResumesPlayback { player?.play() }
        isRestarting = false
        restartItemObserver?.invalidate()
        restartItemObserver = nil
        if let target = pendingRestartTarget {
            pendingRestartTarget = nil
            restartTranscode(atAbsolute: target)
        }
    }

    /// Keeps the server's transcode session alive; it reaps sessions that stop pinging.
    func startPing(session: String) {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: PlaybackTiming.transcodePingInterval)
                guard !Task.isCancelled, let self else { return }
                try? await self.api.requestVoid(.pingTranscode(session: session))
            }
        }
    }
}

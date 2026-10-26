import AVFoundation
import CrucibleCore
import Foundation

extension PlaybackSession {
    /// Takes the snapshot of where the viewer is, before the app has left the foreground: the player's own
    /// clock may no longer be right once it has. The snapshot wins over the clock until the session has
    /// recovered. It also notes whether the viewer was watching, since the system player pauses on its own
    /// when the app resigns and the rate alone no longer says. Does nothing while a snapshot is already held.
    package func holdPosition() {
        guard !isStopped, let player else { return }
        if !tracker.isHeld {
            resumesAfterReturn = player.rate > 0 || wasPlayingAtLastTick
            awaySince = awaySince ?? now()
        }
        let position = tracker.hold(playerSeconds: player.currentTime().seconds, isReady: isItemReady)
        keepPosition(position)
    }

    /// Lets go of a snapshot taken for an interruption that did not take the app away, such as a system
    /// overlay or the screen saver. The app kept running through it, so the stream is as good as its pings
    /// say, and the next play checks that (`resumeAfterPause`). An app that was suspended and comes back
    /// without a foreground notification recovers here.
    package func releasePositionIfForeground() {
        guard !isRecovering else { return }
        if isSuspended {
            recoverAfterSuspension()
            return
        }
        awaySince = nil
        tracker.release()
    }

    func finishRecovery() {
        tracker.release()
        isRecovering = false
        pausedSince = player?.rate == 0 ? now() : nil
    }

    /// Called when the app leaves the foreground: stops the picture (unless the surface plays on in the
    /// background), and saves where the viewer is on the device. A player that is stopped from here on is
    /// held at that position until the app returns; one that keeps playing is only saved. Runs at once, so it
    /// is done before the system suspends the app; `reportSuspension` then tells the server.
    @discardableResult
    package func suspendNow(pausing: Bool = true) -> SuspensionReport? {
        guard !isStopped, let player else { return nil }
        let holds = pausing || player.rate == 0
        let position: Double?
        if holds {
            holdPosition()
            if pausing { player.pause() }
            isSuspended = true
            position = tracker.heldPosition
        } else {
            position = absolutePosition
            keepPosition(position)
        }
        awaySince = awaySince ?? now()
        AppLogger.notice("Playback suspended ratingKey=\(request.ratingKey) position=\(Int(position ?? -1)) directPlay=\(stream?.isDirectPlay ?? false) held=\(holds)", .playback)
        return SuspensionReport(position: position, held: holds)
    }

    /// Tells the server where the viewer was when the app went away, so a suspended or terminated app leaves a
    /// truthful position behind.
    package func reportSuspension(_ report: SuspensionReport) async {
        await reporter?.send(state: report.held ? "paused" : "playing", positionSecs: report.position)
    }

    /// `suspendNow` followed by its report.
    package func suspend(pausing: Bool = true) async {
        guard let report = suspendNow(pausing: pausing) else { return }
        await reportSuspension(report)
    }

    /// Called when the app returns to the foreground after `suspendNow`.
    package func recoverAfterSuspension() {
        guard !isStopped, isSuspended else { return }
        let away = awaySince.map { $0.duration(to: now()) } ?? .zero
        returnFromAway(trigger: "foreground", away: away)
    }

    /// Puts the player back after the app was away, however that was noticed: a transcode is rebuilt under a
    /// new server session at the snapshot and a direct-play file is seeked to it, both backed up by
    /// `BreakRule.rewind` when the viewer wants that. It plays on if the viewer was watching and the absence was
    /// short, and stays paused after a long one. The server is told the position again, in case the report
    /// made on the way out never left.
    func returnFromAway(trigger: String, away: Duration, snapshot noticed: Double? = nil) {
        guard !isStopped, let player, let stream, !isRecovering else { return }
        isSuspended = false
        isRecovering = true
        awaySince = nil
        awayDetector.reset(at: now())
        returnedAt = Date()
        failurePolicy.noteReturn()
        let snapshot = tracker.heldPosition ?? noticed ?? bestKnownPosition
        let wasPlaying = resumesAfterReturn || player.rate > 0
        let resumes = player.rate > 0 || BreakRule.resumesPlaying(wasPlaying: wasPlaying, away: away)
        let rewind = Preferences.rewindAfterBreak ? BreakRule.rewind(after: away) : 0
        let target = BreakRule.target(snapshot: snapshot, rewind: rewind, markers: stream.markers.map(SkipMarker.init))
        let plan = ReturnPlan.make(target: target, isDirectPlay: stream.isDirectPlay)
        AppLogger.notice("Playback returned ratingKey=\(request.ratingKey) trigger=\(trigger) away=\(Int(away.seconds))s snapshot=\(Int(snapshot)) target=\(Int(target)) plan=\(plan) playing=\(resumes)", .playback)
        if !resumes { player.pause() }
        resumesAfterReturn = false
        switch plan {
        case .restartTranscode(let position):
            restartTranscode(atAbsolute: position, resumesPlayback: resumes, freshSession: true, reason: "return (\(trigger))")
        case .seek(let position):
            seekAfterReturn(to: position, resumesPlayback: resumes)
        }
        Task { [weak self] in
            await self?.reporter?.send(state: resumes ? "playing" : "paused", positionSecs: target)
        }
    }

    private func seekAfterReturn(to position: Double, resumesPlayback: Bool) {
        guard let player else { return }
        tracker.moved(to: position)
        let tolerance = request.offline == nil ? CMTime.zero : CMTime(seconds: ResumeStrategy.offlineToleranceBefore, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: position, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: request.offline == nil ? .zero : .positiveInfinity
        ) { @Sendable [weak self] _ in
            Task { @MainActor in
                if resumesPlayback { self?.player?.play() }
                self?.finishRecovery()
            }
        }
    }

    /// Beats once a second for as long as the session plays. A beat that comes long after the last one
    /// means nothing ran in between, which is an absence even when no notification said so; while the app
    /// is known to be suspended the foreground notification deals with it instead. Each beat notes where the
    /// viewer is, so an absence comes back to the position from before it, whatever the player's clock has
    /// read since the device woke.
    func startHeartbeat() {
        heartbeatTask?.cancel()
        awayDetector.reset(at: now())
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                beat()
            }
        }
    }

    private func beat() {
        guard !isStopped else { return }
        guard let away = awayDetector.beat(at: now()) else {
            positionAtLastBeat = bestKnownPosition
            return
        }
        guard !isSuspended else { return }
        returnFromAway(trigger: "heartbeat", away: away, snapshot: positionAtLastBeat)
    }

    /// Notes a lifecycle notification of the surface in the log, with what the player was doing.
    package func noteLifecycle(_ phase: String) {
        guard !isStopped else { return }
        let rate = player?.rate ?? -1
        let status = player?.currentItem?.status.rawValue ?? -1
        AppLogger.notice("Lifecycle \(phase) ratingKey=\(request.ratingKey) position=\(Int(bestKnownPosition)) rate=\(rate) itemStatus=\(status) suspended=\(isSuspended)", .playback)
    }

    /// Writes the position to the device (`PlaybackResumeStore`) unless it is already the one saved.
    func keepPosition(_ position: Double?, force: Bool = true) {
        guard let position, position.isFinite, position >= 0 else { return }
        if !force, let lastSavedPosition, abs(position - lastSavedPosition) < PlaybackTiming.saveInterval { return }
        lastSavedPosition = position
        resumeStore.save(server: serverID, ratingKey: request.ratingKey, positionSecs: position, durationSecs: request.durationSecs)
    }
}

/// Where the viewer was when the app went away and whether the player was held there.
package struct SuspensionReport: Sendable {
    package let position: Double?
    package let held: Bool
}

extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

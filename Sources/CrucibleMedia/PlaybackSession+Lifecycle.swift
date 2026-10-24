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
        if !tracker.isHeld { resumesAfterReturn = player.rate > 0 || wasPlayingAtLastTick }
        let position = tracker.hold(playerSeconds: player.currentTime().seconds, isReady: isItemReady)
        keepPosition(position)
    }

    /// Lets go of a snapshot taken for an interruption that did not take the app away, such as a system
    /// overlay.
    package func releasePositionIfForeground() {
        guard !isSuspended, !isRecovering else { return }
        tracker.release()
    }

    func finishRecovery() {
        tracker.release()
        isRecovering = false
    }

    /// Called when the app leaves the foreground: stops the picture (unless the surface plays on in the
    /// background) and tells the server where the viewer is, so a suspended or terminated app leaves a
    /// truthful position behind, on the server and on the device. A player that is stopped from here on
    /// is held at that position until `recoverAfterSuspension()`; one that keeps playing is only saved.
    package func suspend(pausing: Bool = true) async {
        guard !isStopped, let player else { return }
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
        AppLogger.notice("Playback suspended ratingKey=\(request.ratingKey) position=\(Int(position ?? -1)) directPlay=\(stream?.isDirectPlay ?? false) held=\(holds)", .playback)
        await reporter?.send(state: holds ? "paused" : "playing", positionSecs: position)
    }

    /// Called when the app returns. The player is put back where the snapshot says: a transcode the server
    /// may have reaped is restarted at the snapshot, a direct-play file is seeked to it. It plays on if the viewer was watching when the app went away (what the system
    /// player does by itself, so the two never disagree) and stays paused if they had paused. The server
    /// is told the position again, in case the report made on the way out never left.
    package func recoverAfterSuspension() {
        guard !isStopped, let player, let stream, isSuspended else { return }
        isSuspended = false
        isRecovering = true
        returnedAt = Date()
        failurePolicy.noteReturn()
        let snapshot = tracker.heldPosition ?? absolutePosition ?? lastPlayhead + streamOffset
        let wasPlaying = resumesAfterReturn || player.rate > 0
        let plan = ReturnPlan.make(snapshot: snapshot, isDirectPlay: stream.isDirectPlay, isRestarting: isRestarting)
        AppLogger.notice("Playback returned ratingKey=\(request.ratingKey) snapshot=\(Int(snapshot)) plan=\(plan) playing=\(wasPlaying)", .playback)
        apply(plan, resumesPlayback: wasPlaying)
        Task { [weak self] in
            await self?.reporter?.send(state: wasPlaying ? "playing" : "paused", positionSecs: snapshot)
        }
    }

    private func apply(_ plan: ReturnPlan, resumesPlayback: Bool) {
        switch plan {
        case .keep:
            finishRecovery()
        case .restartTranscode(let position):
            restartTranscode(atAbsolute: position, resumesPlayback: resumesPlayback)
        case .seek(let position):
            seekAfterReturn(to: position, resumesPlayback: resumesPlayback)
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
                self?.finishRecovery()
                if resumesPlayback { self?.player?.play() }
            }
        }
    }

    /// Writes the position to the device (`PlaybackResumeStore`) unless it is already the one saved.
    func keepPosition(_ position: Double?, force: Bool = true) {
        guard let position, position.isFinite, position >= 0 else { return }
        if !force, let lastSavedPosition, abs(position - lastSavedPosition) < PlaybackTiming.saveInterval { return }
        lastSavedPosition = position
        resumeStore.save(server: serverID, ratingKey: request.ratingKey, positionSecs: position, durationSecs: request.durationSecs)
    }
}

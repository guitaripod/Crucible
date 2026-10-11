import AVFoundation
import CrucibleCore
import Foundation

extension PlaybackSession {
    /// Called when the app leaves the foreground: stops the picture and tells the server the viewer
    /// paused, so a suspended or terminated app leaves a truthful position behind.
    package func suspend() async {
        guard !isStopped, let player else { return }
        player.pause()
        await reporter?.send(state: "paused")
    }

    /// Called when the app returns. A paused transcode may have been reaped by the server while the
    /// app was suspended, so it is restarted at the playhead, staying paused, before the viewer presses
    /// play and finds an error instead.
    package func recoverAfterSuspension() {
        guard !isStopped, let player, let stream else { return }
        guard PlaybackLifecyclePolicy.restartsTranscodeOnForeground(
            isDirectPlay: stream.isDirectPlay,
            isPaused: player.rate == 0,
            isRestarting: isRestarting
        ) else { return }
        let position = absolutePosition ?? lastPlayhead + streamOffset
        restartTranscode(atAbsolute: position, resumesPlayback: false)
    }
}

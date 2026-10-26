import Foundation

/// When an item counts as watched: at least 92 percent played.
package enum WatchedRule {
    package static let threshold = 0.92

    package static func progress(positionMs: Int, durationMs: Int) -> Double {
        guard durationMs > 0 else { return 0 }
        return min(1, Double(positionMs) / Double(durationMs))
    }

    package static func isWatched(positionMs: Int, durationMs: Int) -> Bool {
        durationMs > 0 && positionMs > 0 && progress(positionMs: positionMs, durationMs: durationMs) >= threshold
    }
}

/// How playback reaches the stored resume position. A transcode starts there through the stream URL
/// and must never be seeked again; a direct-play file seeks exactly; a downloaded HLS item seeks
/// loosely once it is ready.
package enum ResumeStrategy: Equatable, Sendable {
    case none
    case seekExact(Double)
    case seekWhenReady(Double)

    package static let offlineToleranceBefore = 3.0

    package static func make(resumePosition: Double, isDirectPlay: Bool, isOffline: Bool) -> ResumeStrategy {
        guard resumePosition > 0 else { return .none }
        if isOffline { return .seekWhenReady(resumePosition) }
        return isDirectPlay ? .seekExact(resumePosition) : .none
    }

    /// The timeline position the stream's own zero corresponds to: the URL offset of a transcode.
    package static func streamOffset(resumePosition: Double, isDirectPlay: Bool) -> Double {
        isDirectPlay ? 0 : StreamPosition.transcodeStart(resumePosition)
    }
}

/// Maps the player's own clock onto the item's timeline.
package enum StreamPosition {
    /// The item-timeline position for a player time and stream offset, or nil when either is unusable.
    package static func absolute(playerSeconds: Double, streamOffset: Double) -> Double? {
        let position = playerSeconds + streamOffset
        return position.isFinite && position >= 0 ? position : nil
    }

    /// Where a transcode asked to start at `target` really starts: the server takes whole seconds, so the
    /// stream's zero is the whole second at or before the target.
    package static func transcodeStart(_ target: Double) -> Double {
        guard target.isFinite, target > 0 else { return 0 }
        return target.rounded(.down)
    }
}

/// A jump of the playhead on a transcode that is large enough to need a new transcoder offset.
package enum TranscodeSeekPolicy {
    package static let jumpThreshold = 5.0

    package static func isJump(from previous: Double, to current: Double) -> Bool {
        abs(current - previous) > jumpThreshold
    }
}

/// Timings shared by every playback surface.
package enum PlaybackTiming {
    package static let timelineInterval = 10.0
    package static let saveInterval = 5.0
    package static let transcodePingInterval: Duration = .seconds(20)
    package static let autoSkipUndoWindow: Duration = .seconds(4)
}

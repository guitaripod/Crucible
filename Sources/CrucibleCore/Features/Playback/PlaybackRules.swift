import Foundation

/// When an item counts as watched: at least 92 percent played, or the playhead has reached the credits.
/// Plex itself finishes an item at the earlier of its completion percentage and its first credits marker
/// (the default of its "Video play completion behaviour"), so an episode the viewer watched into the
/// credits is finished even when those credits begin before the percentage.
package enum WatchedRule {
    package static let threshold = 0.92

    /// How close to the credits start an item counts as finished: a playhead two seconds short of them is
    /// the credits, not the last scene.
    package static let creditsTolerance = 2.0

    package static func progress(positionMs: Int, durationMs: Int) -> Double {
        guard durationMs > 0 else { return 0 }
        return min(1, Double(positionMs) / Double(durationMs))
    }

    package static func isWatched(positionMs: Int, durationMs: Int) -> Bool {
        durationMs > 0 && positionMs > 0 && progress(positionMs: positionMs, durationMs: durationMs) >= threshold
    }

    /// Whether the viewer finished the item: the playhead reached the credits, or the percentage says so.
    /// An item with neither a known duration nor credits markers is never finished by position alone.
    package static func isFinished(positionSecs: Double, durationSecs: Double, creditsStartSecs: Double?) -> Bool {
        guard positionSecs.isFinite, positionSecs >= 0 else { return false }
        if let creditsStartSecs, creditsStartSecs > 0, positionSecs >= creditsStartSecs - creditsTolerance {
            return true
        }
        guard durationSecs > 0 else { return false }
        return positionSecs / durationSecs >= threshold
    }
}

/// The order episodes play in, and the one after a given episode. One rule for the player's Up Next, the
/// episode screen's link to the next episode and a show's Continue button, so a show never offers three
/// different answers. The server's own order is not trusted: an episode's season and number decide.
package enum EpisodeOrder {
    package static func sorted(_ episodes: [PlexMetadata]) -> [PlexMetadata] {
        episodes.enumerated()
            .sorted { left, right in
                let a = (left.element.parentIndex ?? 0, left.element.index ?? 0, left.offset)
                let b = (right.element.parentIndex ?? 0, right.element.index ?? 0, right.offset)
                return a < b
            }
            .map(\.element)
    }

    /// The episode after `ratingKey`, when it is one of `episodes`: the next entry in episode order, or nil
    /// for the last one. Follows the season and episode numbers, never the list the server happened to send.
    package static func next(after ratingKey: String, in episodes: [PlexMetadata]) -> PlexMetadata? {
        let ordered = sorted(episodes)
        guard let current = ordered.firstIndex(where: { $0.id == ratingKey }), current + 1 < ordered.count else {
            return nil
        }
        return ordered[current + 1]
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

    /// Whether a jump inside a transcode needs the server to encode from somewhere else. The player goes back
    /// on its own, since the server already made those segments, and forward into what it has loaded; only a
    /// jump further ahead restarts the transcode there. A restart replaces the item, which also resets
    /// choices the viewer made on it, such as turning its subtitles off.
    package static func needsRestart(from previous: Double, to current: Double, loaded: [ClosedRange<Double>]) -> Bool {
        guard current > previous else { return false }
        return !loaded.contains { $0.contains(current) }
    }
}

/// Timings shared by every playback surface.
package enum PlaybackTiming {
    package static let timelineInterval = 10.0
    package static let saveInterval = 5.0
    package static let transcodePingInterval: Duration = .seconds(20)
    package static let autoSkipUndoWindow: Duration = .seconds(4)
    /// How close to the resume position the playhead has to be for a prepared player's seek to count as landed.
    package static let resumeLandedTolerance = 5.0
}

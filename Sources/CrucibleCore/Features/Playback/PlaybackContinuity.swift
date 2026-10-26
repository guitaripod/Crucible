import Foundation

/// Notices that the app was away from the gap between two heartbeats of a playing session, whether or not
/// any lifecycle notification said so. An Apple TV that falls asleep from its screen saver can freeze the
/// process without sending the app to the background, and it wakes with a player whose stream the server
/// has long since reaped. The heartbeat runs on the continuous clock, which keeps counting while the
/// device sleeps, so a gap is exactly the time nothing ran.
package struct AwayDetector: Sendable, Equatable {
    /// A gap longer than this is an absence, not a busy main thread.
    package static let threshold: Duration = .seconds(20)

    private var lastBeat: ContinuousClock.Instant?

    package init() {}

    /// Records a heartbeat and returns how long the app was away when the gap since the last one is an absence.
    package mutating func beat(at now: ContinuousClock.Instant) -> Duration? {
        defer { lastBeat = now }
        guard let lastBeat else { return nil }
        let gap = lastBeat.duration(to: now)
        return gap > Self.threshold ? gap : nil
    }

    /// Starts counting afresh, after an absence was dealt with some other way.
    package mutating func reset(at now: ContinuousClock.Instant) {
        lastBeat = now
    }
}

/// How the player comes back after a break: the app away, or a long pause.
package enum BreakRule {
    /// After this long away the player comes back paused even if it was playing: nobody should be surprised
    /// by sound when they wake the Apple TV for something else.
    package static let autoResumeLimit: Duration = .seconds(5 * 60)

    /// A pause shorter than this is not a break, and resuming from it plays exactly where it stopped.
    package static let shortestBreak: Duration = .seconds(5 * 60)

    /// How far back "Rewind After a Break" goes: nothing for a short break, then further the longer the
    /// break was, up to fifteen seconds.
    package static func rewind(after away: Duration) -> Double {
        switch away {
        case ..<shortestBreak: return 0
        case ..<Duration.seconds(30 * 60): return 5
        case ..<Duration.seconds(120 * 60): return 10
        default: return 15
        }
    }

    /// Whether the player plays on by itself after being away for `away`.
    package static func resumesPlaying(wasPlaying: Bool, away: Duration) -> Bool {
        wasPlaying && away < autoResumeLimit
    }

    /// The position to come back to: the snapshot, backed up by `rewind` seconds when the viewer wants
    /// that, never before the start and never back into an intro the snapshot is already past.
    package static func target(snapshot: Double, rewind: Double, markers: [SkipMarker]) -> Double {
        guard rewind > 0 else { return max(0, snapshot) }
        var target = max(0, snapshot - rewind)
        if let skipped = markers.first(where: { !$0.isCredits && $0.startSecs <= target && target < $0.endSecs && snapshot >= $0.endSecs }) {
            target = skipped.endSecs
        }
        return min(target, max(0, snapshot))
    }
}

/// Whether the server's transcode session can still be trusted. The server reaps a session that stopped
/// pinging, and an item that keeps playing a reaped session can show the start of the episode while its
/// clock runs on mid-episode, which is how a credits marker or the end of the item arrives in the middle of
/// the picture. A session nobody heard from inside the reap window, or that the server said is gone, is
/// rebuilt under a new session id before it plays again.
package struct TranscodeLiveness: Sendable, Equatable {
    package static let reapWindow: Duration = .seconds(45)

    private var lastConfirmed: ContinuousClock.Instant
    private(set) package var isGone = false

    package init(confirmedAt now: ContinuousClock.Instant) {
        lastConfirmed = now
    }

    /// The stream answered: a segment came back or a rebuilt item became ready.
    package mutating func confirm(at now: ContinuousClock.Instant) {
        lastConfirmed = now
        isGone = false
    }

    /// The server answered a ping. A server can answer pings for a session whose stream it already dropped,
    /// so this keeps a session alive but never brings back one a segment request found gone.
    package mutating func pinged(at now: ContinuousClock.Instant) {
        lastConfirmed = now
    }

    /// The server said the session does not exist.
    package mutating func markGone() {
        isGone = true
    }

    package func mayBeGone(at now: ContinuousClock.Instant) -> Bool {
        isGone || lastConfirmed.duration(to: now) > Self.reapWindow
    }

    /// Whether an HTTP status for a ping or a segment means the session is gone.
    package static func isGoneStatus(_ status: Int) -> Bool {
        status == 404 || status == 410
    }
}

/// Whether an item really reached its end, or its stream stopped short. A transcode whose server session
/// was cut can end early, and treating that as the end of the episode would start the next one in the
/// middle of this one.
package enum ItemEndRule {
    /// How close to the end of the timeline an end counts, in seconds, for an item of `duration` seconds.
    package static func endWindow(duration: Double) -> Double {
        max(30, duration * 0.03)
    }

    /// True when the playhead at `absolute` is at the credits or within the end window of the item. An item
    /// without a known duration always counts.
    package static func isGenuineEnd(absolute: Double, duration: Double, creditsStart: Double?) -> Bool {
        guard duration > 0 else { return true }
        if let creditsStart, absolute >= creditsStart - 2 { return true }
        return duration - absolute <= endWindow(duration: duration)
    }
}

/// Asks before the next episode once a run of episodes has played with nobody touching the remote, so a
/// season does not play on through the night.
package enum StillWatchingRule {
    /// The choices Settings offers, in episodes; zero is off.
    package static let choices = [0, 2, 3, 5]
    package static let defaultLimit = 3

    /// Whether the Up Next card asks "Still watching?" instead of counting down: `unattended` episodes have
    /// started on their own in a row and the limit is on.
    package static func asks(unattended: Int, limit: Int) -> Bool {
        limit > 0 && unattended >= limit
    }

    package static func label(for limit: Int) -> String {
        limit > 0 ? "After \(limit) Episodes" : "Off"
    }
}

extension Preferences {
    private static let rewindAfterBreakKey = "rewindAfterBreak"
    private static let stillWatchingKey = "stillWatchingAfterEpisodes"

    /// Backs playback up a few seconds after a break (`BreakRule.rewind`). On by default.
    package static var rewindAfterBreak: Bool {
        get { UserDefaults.standard.object(forKey: rewindAfterBreakKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: rewindAfterBreakKey) }
    }

    /// Episodes in a row without the remote before Up Next asks "Still watching?"; zero is off.
    package static var stillWatchingAfter: Int {
        get {
            guard let stored = UserDefaults.standard.object(forKey: stillWatchingKey) as? Int,
                  StillWatchingRule.choices.contains(stored) else { return StillWatchingRule.defaultLimit }
            return stored
        }
        set { UserDefaults.standard.set(StillWatchingRule.choices.contains(newValue) ? newValue : StillWatchingRule.defaultLimit, forKey: stillWatchingKey) }
    }
}

/// How often a session may rebuild a transcode on its own before it stops and says so: never twice
/// within a few seconds, and only a handful of times in a few minutes, so a server that keeps dropping
/// the stream ends in a Retry instead of a loop.
package struct HealBudget: Sendable, Equatable {
    package enum Verdict: Equatable, Sendable {
        case heal
        case wait
        case giveUp
    }

    package static let spacing: Duration = .seconds(10)
    package static let window: Duration = .seconds(180)
    package static let limit = 4

    private var recent: [ContinuousClock.Instant] = []

    package init() {}

    package mutating func ask(at now: ContinuousClock.Instant) -> Verdict {
        recent.removeAll { $0.duration(to: now) > Self.window }
        if let last = recent.last, last.duration(to: now) < Self.spacing { return .wait }
        guard recent.count < Self.limit else { return .giveUp }
        recent.append(now)
        return .heal
    }
}

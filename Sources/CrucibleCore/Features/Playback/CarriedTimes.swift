import Foundation

/// The times the system player may carry over onto a rebuilt transcode from the item before it.
///
/// A paused transport bar keeps the time it last showed and commits it when the viewer presses Play, even though the item under
/// it was replaced meanwhile. After the app was away that time can be the old item's clock, or zero when that clock lost its
/// place while the Apple TV slept, and Plex's playlist spans the whole item, so a commit of zero plays the episode from its start.
/// The times stay suspect until the rebuilt item has really played for a moment, not only for a few seconds after it became
/// ready: the viewer can come back to the remote minutes later.
package struct CarriedTimes: Sendable, Equatable {
    /// How near a reading must be to a carried time to be that time.
    package static let tolerance = 1.5
    /// How long the rebuilt item plays before a reading that matches a carried time is taken as the viewer's.
    package static let playingGrace: Duration = .seconds(3)

    package let times: [Double]
    private var playingSince: ContinuousClock.Instant?

    /// The times for a rebuild that replaces an item whose clock read `previousClock` and showed the viewer at `previousPosition`
    /// on that clock. A rebuild after an absence (a new server session for a stream that may have been reaped while nobody
    /// watched) also suspects zero and the shown position, since the old clock may have lost its place meanwhile; a rebuild the
    /// viewer asked for only suspects the old clock, so a scrub back to the start or to the earlier place is the viewer's.
    package init(previousClock: Double?, previousPosition: Double?, afterAbsence: Bool) {
        var times: [Double] = afterAbsence ? [0] : []
        for time in afterAbsence ? [previousClock, previousPosition] : [previousClock] {
            guard let time, time.isFinite, time >= 0, !times.contains(where: { abs($0 - time) < Self.tolerance }) else { continue }
            times.append(time)
        }
        self.times = times
    }

    /// Whether a reading of the rebuilt item at `reading` is a carried-over time rather than a place the viewer chose: it matches
    /// one of the times and lies far from `home`, where the rebuilt stream starts on its own clock.
    package func isCarried(_ reading: Double, home: Double, at now: ContinuousClock.Instant) -> Bool {
        guard isActive(at: now), reading.isFinite, abs(reading - home) > TranscodeSeekPolicy.jumpThreshold else { return false }
        return times.contains { abs($0 - reading) < Self.tolerance }
    }

    /// Whether the times are still suspect.
    package func isActive(at now: ContinuousClock.Instant) -> Bool {
        guard let playingSince else { return true }
        return playingSince.duration(to: now) < Self.playingGrace
    }

    /// The rebuilt item started or stopped playing.
    package mutating func noteRate(playing: Bool, at now: ContinuousClock.Instant) {
        if playing {
            playingSince = playingSince ?? now
        } else if isActive(at: now) {
            playingSince = nil
        }
    }
}

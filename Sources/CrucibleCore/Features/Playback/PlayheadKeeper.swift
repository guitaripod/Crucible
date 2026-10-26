import Foundation
import os

/// The one answer to "where is the viewer in this item", kept apart from the player's own clock.
///
/// The clock of an `AVPlayer` is only trustworthy while its item is ready: after the app was suspended,
/// the Apple TV slept or a stream was replaced it can read zero seconds into the stream, and anything
/// derived from that (a transcode restart, a timeline report, a retry) sends the viewer back to the
/// start. The keeper remembers the last position seen on a ready item and can hold a snapshot taken
/// before the app left the foreground, which wins over the clock until the player has been put back
/// where the snapshot says.
package struct PlayheadKeeper: Sendable, Equatable {
    /// How far behind the last good position a reading may be before it counts as a lost place.
    package static let regressionTolerance = 5.0

    package private(set) var lastGood: Double?
    package private(set) var held: Double?

    package init() {}

    package var isHeld: Bool { held != nil }

    /// Records a reading from the player's clock. Readings from an item that is not ready, and every
    /// reading while a snapshot is held, are ignored.
    package mutating func observe(absolute: Double?, isReady: Bool) {
        guard held == nil, isReady, let absolute, absolute.isFinite, absolute >= 0 else { return }
        lastGood = absolute
    }

    /// The position the viewer asked for with a seek, or the offset a restarted stream begins at.
    package mutating func moved(to absolute: Double) {
        guard absolute.isFinite, absolute >= 0 else { return }
        lastGood = absolute
        if held != nil { held = absolute }
    }

    /// Takes the snapshot the app keeps while it is away and returns it. The current reading counts
    /// unless it fell far behind the last good position, which is how a lost place looks. A snapshot
    /// already held is kept.
    @discardableResult
    package mutating func hold(observed absolute: Double?, isReady: Bool) -> Double? {
        if let held { return held }
        let snapshot = Self.snapshot(observed: absolute, isReady: isReady, lastGood: lastGood)
        held = snapshot
        if let snapshot { lastGood = snapshot }
        return snapshot
    }

    package mutating func release() {
        held = nil
    }

    /// The position to act on: the held snapshot, else the reading of a ready item, else the last good one.
    package func position(observed absolute: Double?, isReady: Bool) -> Double? {
        if let held { return held }
        if isReady, let absolute, absolute.isFinite, absolute >= 0 { return absolute }
        return lastGood
    }

    private static func snapshot(observed: Double?, isReady: Bool, lastGood: Double?) -> Double? {
        guard isReady, let observed, observed.isFinite, observed >= 0 else { return lastGood }
        guard let lastGood else { return observed }
        return observed < lastGood - regressionTolerance ? lastGood : observed
    }
}

/// A `PlayheadKeeper` shared by the session and the timeline reporter, whose observers run off the main
/// thread, together with the offset that maps the player's clock onto the item's timeline.
package final class PlayheadTracker: Sendable {
    private struct State {
        var keeper = PlayheadKeeper()
        var streamOffset = 0.0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    package init() {}

    package var isHeld: Bool { state.withLock { $0.keeper.isHeld } }

    package var heldPosition: Double? { state.withLock { $0.keeper.held } }

    /// The last position seen on a ready item, or the last one the session moved to.
    package var lastGoodPosition: Double? { state.withLock { $0.keeper.lastGood } }

    package var streamOffset: Double { state.withLock { $0.streamOffset } }

    package func setStreamOffset(_ offset: Double) {
        state.withLock { $0.streamOffset = offset }
    }

    package func observe(playerSeconds: Double, isReady: Bool) {
        state.withLock { state in
            state.keeper.observe(absolute: Self.absolute(playerSeconds, state.streamOffset), isReady: isReady)
        }
    }

    package func moved(to absolute: Double) {
        state.withLock { $0.keeper.moved(to: absolute) }
    }

    @discardableResult
    package func hold(playerSeconds: Double?, isReady: Bool) -> Double? {
        state.withLock { state in
            state.keeper.hold(observed: playerSeconds.flatMap { Self.absolute($0, state.streamOffset) }, isReady: isReady)
        }
    }

    package func release() {
        state.withLock { $0.keeper.release() }
    }

    package func position(playerSeconds: Double?, isReady: Bool) -> Double? {
        state.withLock { state in
            state.keeper.position(observed: playerSeconds.flatMap { Self.absolute($0, state.streamOffset) }, isReady: isReady)
        }
    }

    private static func absolute(_ playerSeconds: Double, _ streamOffset: Double) -> Double? {
        StreamPosition.absolute(playerSeconds: playerSeconds, streamOffset: streamOffset)
    }
}

/// What the player is put through when the app returns after being away.
package enum ReturnPlan: Equatable, Sendable {
    case restartTranscode(at: Double)
    case seek(to: Double)

    /// A transcode is always rebuilt at the target under a new server session: the server reaps a session
    /// that stopped pinging while the app was away, and a reaped session the player keeps reading can show
    /// the episode from its start while the clock runs on where it was. A direct-play file is always seeked to
    /// the target too, even when its clock agrees: a clock that is about to change under the player (a seek
    /// still in flight) cannot be told from a good one.
    package static func make(target: Double, isDirectPlay: Bool) -> ReturnPlan {
        isDirectPlay ? .seek(to: target) : .restartTranscode(at: target)
    }
}

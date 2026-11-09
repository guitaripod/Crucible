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
    package private(set) var isRebuilding = false

    package init() {}

    package var isHeld: Bool { held != nil }

    /// Records a reading from the player's clock. Readings from an item that is not ready, every reading
    /// while a snapshot is held and every reading while the stream is being rebuilt are ignored.
    package mutating func observe(absolute: Double?, isReady: Bool) {
        guard held == nil, !isRebuilding, isReady, let absolute, absolute.isFinite, absolute >= 0 else { return }
        lastGood = absolute
    }

    /// The stream is being rebuilt to start at `absolute`: until the new item is ready the player's clock
    /// still belongs to the old one, so nothing reads it.
    package mutating func beginRebuild(at absolute: Double) {
        moved(to: absolute)
        isRebuilding = true
    }

    package mutating func endRebuild() {
        isRebuilding = false
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

    /// The position to act on: the held snapshot, else the reading of a ready item, else the last good one,
    /// which is also the answer while the stream is being rebuilt.
    package func position(observed absolute: Double?, isReady: Bool) -> Double? {
        if let held { return held }
        if !isRebuilding, isReady, let absolute, absolute.isFinite, absolute >= 0 { return absolute }
        return lastGood
    }

    private static func snapshot(observed: Double?, isReady: Bool, lastGood: Double?) -> Double? {
        guard isReady, let observed, observed.isFinite, observed >= 0 else { return lastGood }
        guard let lastGood else { return observed }
        return observed < lastGood - regressionTolerance ? lastGood : observed
    }
}

/// How the player's clock reads on a transcode that starts part-way into the item. A Plex server's playlist spans the
/// whole item and starts the player at the offset, so the clock already reads the item's own position (`itemTimeline`);
/// a server whose playlist begins at the offset reads zero there (`fromStreamStart`). Which one a server does is learned
/// from the clock of a ready item and kept for the rest of the app's run.
package enum TranscodeClock: Sendable, Equatable {
    case itemTimeline
    case fromStreamStart

    /// A start at least this far into the item tells the two clocks apart; nearer the beginning they read almost the same.
    package static let decisiveStart = 2.0

    private static let memory = OSAllocatedUnfairLock(initialState: [String: TranscodeClock]())

    /// What is added to the player's clock to place it on the item's timeline, for a stream that starts at `start`.
    package func offset(start: Double) -> Double {
        self == .itemTimeline ? 0 : start
    }

    /// The clock a stream asked to start at `start` shows when a ready item reads `reading`: whichever of the two origins
    /// the reading is nearer. Nil when the start is too near the beginning to tell or the reading is unusable.
    package static func read(start: Double, reading: Double) -> TranscodeClock? {
        guard start >= decisiveStart, reading.isFinite, reading >= 0 else { return nil }
        return abs(reading - start) < reading ? .itemTimeline : .fromStreamStart
    }

    package static func remembered(server: String) -> TranscodeClock? {
        memory.withLock { $0[server] }
    }

    package static func remember(_ clock: TranscodeClock, server: String) {
        memory.withLock { $0[server] = clock }
    }
}

/// A `PlayheadKeeper` shared by the session and the timeline reporter, whose observers run off the main
/// thread, together with how the player's clock maps onto the item's timeline: where the stream on the
/// player starts and what is added to its clock, which for a transcode is learned from its first reading
/// on a ready item (`TranscodeClock`).
package final class PlayheadTracker: Sendable {
    private struct State {
        var keeper = PlayheadKeeper()
        var streamOffset = 0.0
        var streamStart = 0.0
        var clock: TranscodeClock
        var pendingStart: Double?
    }

    private let state: OSAllocatedUnfairLock<State>
    private let server: String?

    /// `server` keys what the tracker learns about the server's transcode clock, so the next stream from it starts out right.
    package init(server: String? = nil) {
        self.server = server
        let clock = server.flatMap { TranscodeClock.remembered(server: $0) } ?? .itemTimeline
        state = OSAllocatedUnfairLock(initialState: State(clock: clock))
    }

    package var isHeld: Bool { state.withLock { $0.keeper.isHeld } }

    package var heldPosition: Double? { state.withLock { $0.keeper.held } }

    /// The last position seen on a ready item, or the last one the session moved to.
    package var lastGoodPosition: Double? { state.withLock { $0.keeper.lastGood } }

    /// What is added to the player's clock to place it on the item's timeline.
    package var streamOffset: Double { state.withLock { $0.streamOffset } }

    /// Where the stream on the player begins on the item's timeline: zero for a file, the offset a transcode was asked to start at.
    package var streamStart: Double { state.withLock { $0.streamStart } }

    package var clock: TranscodeClock { state.withLock { $0.clock } }

    /// A new stream is on the player. A file's clock is the item's own. A transcode asked to start at `start` is read the
    /// way this server's transcodes were last seen to read, until its first reading on a ready item says otherwise.
    package func beginStream(start: Double, isTranscode: Bool) {
        state.withLock { state in
            guard isTranscode else {
                state.streamStart = 0
                state.streamOffset = 0
                state.pendingStart = nil
                return
            }
            state.streamStart = start
            state.streamOffset = state.clock.offset(start: start)
            state.pendingStart = start >= TranscodeClock.decisiveStart ? start : nil
        }
    }

    /// Learns how the clock of the stream that just became ready reads, from `reading`, even while the stream is still
    /// being rebuilt. Returns true when that changed what is added to the clock.
    @discardableResult
    package func learnClock(reading: Double) -> Bool {
        let learned = state.withLock { Self.learn(&$0, reading: reading) }
        return settle(learned)
    }

    package func observe(playerSeconds: Double, isReady: Bool) {
        let learned = state.withLock { state in
            let learned = Self.learnIfReady(&state, reading: playerSeconds, isReady: isReady)
            state.keeper.observe(absolute: Self.absolute(playerSeconds, state.streamOffset), isReady: isReady)
            return learned
        }
        settle(learned)
    }

    package func moved(to absolute: Double) {
        state.withLock { $0.keeper.moved(to: absolute) }
    }

    package func beginRebuild(at absolute: Double) {
        state.withLock { $0.keeper.beginRebuild(at: absolute) }
    }

    package func endRebuild() {
        state.withLock { $0.keeper.endRebuild() }
    }

    @discardableResult
    package func hold(playerSeconds: Double?, isReady: Bool) -> Double? {
        let (position, learned) = state.withLock { state in
            let learned = playerSeconds.flatMap { Self.learnIfReady(&state, reading: $0, isReady: isReady) }
            let position = state.keeper.hold(observed: playerSeconds.flatMap { Self.absolute($0, state.streamOffset) }, isReady: isReady)
            return (position, learned)
        }
        settle(learned)
        return position
    }

    package func release() {
        state.withLock { $0.keeper.release() }
    }

    package func position(playerSeconds: Double?, isReady: Bool) -> Double? {
        let (position, learned) = state.withLock { state in
            let learned = playerSeconds.flatMap { Self.learnIfReady(&state, reading: $0, isReady: isReady) }
            let position = state.keeper.position(observed: playerSeconds.flatMap { Self.absolute($0, state.streamOffset) }, isReady: isReady)
            return (position, learned)
        }
        settle(learned)
        return position
    }

    /// Remembers what was learned for the server's next stream and says whether the mapping moved.
    @discardableResult
    private func settle(_ learned: Learned?) -> Bool {
        guard let learned else { return false }
        if let server { TranscodeClock.remember(learned.clock, server: server) }
        return learned.moved
    }

    private struct Learned {
        let clock: TranscodeClock
        let moved: Bool
    }

    /// Learns the clock from a reading taken by the playhead's own observers: only on a ready item, never while the stream
    /// is being rebuilt (the clock may still be the old item's) or while the app is away.
    private static func learnIfReady(_ state: inout State, reading: Double, isReady: Bool) -> Learned? {
        guard isReady, !state.keeper.isRebuilding, !state.keeper.isHeld else { return nil }
        return learn(&state, reading: reading)
    }

    private static func learn(_ state: inout State, reading: Double) -> Learned? {
        guard let start = state.pendingStart, let clock = TranscodeClock.read(start: start, reading: reading) else { return nil }
        state.pendingStart = nil
        state.clock = clock
        let offset = clock.offset(start: start)
        let moved = offset != state.streamOffset
        state.streamOffset = offset
        return Learned(clock: clock, moved: moved)
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

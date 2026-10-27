import AVFoundation
import CrucibleCore
import Foundation
import os

/// Reports the playhead to the server's timeline: the player's state every ten seconds (and whenever the
/// periodic observer fires on a seek or a new item), `playing`/`paused` on every state change and `stopped`
/// when it is stopped. One reporter serves a whole session; a change
/// of stream only changes the offset of its `PlayheadTracker`, which also decides what position is
/// true: a report never reads the player's clock directly, so a clock that lost its place cannot
/// write the start of the stream over the server's record. Every report the server accepts is
/// noted in the `PlaybackResumeStore`.
///
/// Reports leave one at a time, in the order they were made: the observers fire from two places (the
/// periodic tick and the player's state) and a request takes as long as the network takes, so a report made
/// before the stop could otherwise land after it and put a finished item back where it was ten seconds
/// earlier. Once the reporter is stopped nothing else is sent: the queued tick that was on its way out is
/// dropped, and only `stopped` follows it.
@MainActor
package final class PlaybackReporter {
    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "playback")

    private let api: APIClient
    private let ratingKey: String
    private let durationMs: Int
    private let tracker: PlayheadTracker
    private let resumeStore: PlaybackResumeStore
    private let server: String
    private weak var player: AVPlayer?
    private var timeObserverToken: Any?
    private var statusObservation: NSKeyValueObservation?
    /// The tail of the report chain: every report awaits the one before it.
    private var pending: Task<Void, Never>?
    private var isStopped = false

    package init(
        api: APIClient,
        ratingKey: String,
        durationMs: Int,
        player: AVPlayer,
        tracker: PlayheadTracker,
        resumeStore: PlaybackResumeStore,
        server: String
    ) {
        self.api = api
        self.ratingKey = ratingKey
        self.durationMs = durationMs
        self.player = player
        self.tracker = tracker
        self.resumeStore = resumeStore
        self.server = server
        setupObservers()
    }

    private func setupObservers() {
        guard let player else { return }

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: PlaybackTiming.timelineInterval, preferredTimescale: 1),
            queue: .main
        ) { [weak self, weak player] time in
            let isReady = player?.currentItem?.status == .readyToPlay
            let state = player?.timeControlStatus == .paused ? "paused" : "playing"
            Task { @MainActor [weak self] in
                guard let self, let position = self.tracker.position(playerSeconds: time.seconds, isReady: isReady) else { return }
                self.enqueue(state: state, position: position)
            }
        }

        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observedPlayer, _ in
            let isReady = observedPlayer.currentItem?.status == .readyToPlay
            let state: String
            switch observedPlayer.timeControlStatus {
            case .playing: state = "playing"
            case .paused: state = "paused"
            default: return
            }
            let seconds = observedPlayer.currentTime().seconds
            Task { @MainActor [weak self] in
                guard let self, let position = self.tracker.position(playerSeconds: seconds, isReady: isReady) else { return }
                self.enqueue(state: state, position: position)
            }
        }
    }

    /// Puts a report at the end of the chain, so it leaves after every report made before it.
    private func enqueue(state: String, position: Double) {
        guard !isStopped else { return }
        let previous = pending
        let api = api
        let ratingKey = ratingKey
        let durationMs = durationMs
        let resumeStore = resumeStore
        let server = server
        pending = Task { [weak self] in
            await previous?.value
            guard let self, !self.isStopped else { return }
            await Self.report(
                api: api, ratingKey: ratingKey, state: state, position: position,
                durationMs: durationMs, resumeStore: resumeStore, server: server
            )
        }
    }

    private static func report(
        api: APIClient,
        ratingKey: String,
        state: String,
        position: Double,
        durationMs: Int,
        resumeStore: PlaybackResumeStore,
        server: String
    ) async {
        do {
            try await api.requestVoid(.timeline(ratingKey: ratingKey, state: state, timeMs: Int(position * 1000), durationMs: durationMs))
            resumeStore.recordReport(server: server, ratingKey: ratingKey, positionSecs: position)
        } catch {
            log.error("Timeline report (\(state, privacy: .public)) failed for \(ratingKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reports `state` ("paused", for instance) right away, at `positionSecs` or else at the tracked position.
    package func send(state: String, positionSecs: Double? = nil) async {
        guard !isStopped, let position = positionSecs ?? currentPosition() else { return }
        await Self.report(
            api: api, ratingKey: ratingKey, state: state, position: position,
            durationMs: durationMs, resumeStore: resumeStore, server: server
        )
    }

    private func currentPosition() -> Double? {
        tracker.position(playerSeconds: player?.currentTime().seconds, isReady: player?.currentItem?.status == .readyToPlay)
    }

    /// Ends reporting: drops every queued report except the stop, which goes out after them so nothing
    /// already sent can be overtaken by a stale one.
    package func stop(positionSecs: Double? = nil) async {
        guard !isStopped else { return }
        isStopped = true
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
        statusObservation = nil
        await pending?.value
        pending = nil
        guard let position = positionSecs ?? currentPosition() else { return }
        await Self.report(
            api: api, ratingKey: ratingKey, state: "stopped", position: position,
            durationMs: durationMs, resumeStore: resumeStore, server: server
        )
    }
}

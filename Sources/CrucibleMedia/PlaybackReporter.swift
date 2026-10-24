import AVFoundation
import CrucibleCore
import Foundation
import os

/// Reports the playhead to the server's timeline: `playing` every ten seconds, `playing`/`paused` on
/// every state change and `stopped` when it is stopped. One reporter serves a whole session; a change
/// of stream only changes the offset of its `PlayheadTracker`, which also decides what position is
/// true: a report never reads the player's clock directly, so a clock that lost its place cannot
/// write the start of the stream over the server's record. Every report the server accepts is
/// noted in the `PlaybackResumeStore`.
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

        let api = self.api
        let ratingKey = self.ratingKey
        let durationMs = self.durationMs
        let tracker = self.tracker
        let resumeStore = self.resumeStore
        let server = self.server

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: PlaybackTiming.timelineInterval, preferredTimescale: 1),
            queue: .main
        ) { [weak player] time in
            let isReady = player?.currentItem?.status == .readyToPlay
            guard let position = tracker.position(playerSeconds: time.seconds, isReady: isReady) else { return }
            Task {
                await Self.report(
                    api: api, ratingKey: ratingKey, state: "playing", position: position,
                    durationMs: durationMs, resumeStore: resumeStore, server: server
                )
            }
        }

        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { @Sendable observedPlayer, _ in
            let isReady = observedPlayer.currentItem?.status == .readyToPlay
            guard let position = tracker.position(playerSeconds: observedPlayer.currentTime().seconds, isReady: isReady) else { return }
            let state: String
            switch observedPlayer.timeControlStatus {
            case .playing: state = "playing"
            case .paused: state = "paused"
            default: return
            }
            Task {
                await Self.report(
                    api: api, ratingKey: ratingKey, state: state, position: position,
                    durationMs: durationMs, resumeStore: resumeStore, server: server
                )
            }
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
        guard let position = positionSecs ?? currentPosition() else { return }
        await Self.report(
            api: api, ratingKey: ratingKey, state: state, position: position,
            durationMs: durationMs, resumeStore: resumeStore, server: server
        )
    }

    private func currentPosition() -> Double? {
        tracker.position(playerSeconds: player?.currentTime().seconds, isReady: player?.currentItem?.status == .readyToPlay)
    }

    package func stop(positionSecs: Double? = nil) async {
        await send(state: "stopped", positionSecs: positionSecs)
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
        statusObservation = nil
    }
}

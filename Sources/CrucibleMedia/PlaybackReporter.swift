import AVFoundation
import CrucibleCore
import Foundation
import os

/// Reports the playhead to the server's timeline: `playing` every ten seconds, `playing`/`paused` on
/// every state change and `stopped` when it is stopped. One reporter serves a whole session; a change
/// of stream only changes its offset.
@MainActor
package final class PlaybackReporter {
    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "playback")

    private let api: APIClient
    private let ratingKey: String
    private let durationMs: Int
    private weak var player: AVPlayer?
    private var timeObserverToken: Any?
    private var statusObservation: NSKeyValueObservation?
    private let streamOffset = OSAllocatedUnfairLock<Double>(initialState: 0)

    package init(api: APIClient, ratingKey: String, durationMs: Int, player: AVPlayer) {
        self.api = api
        self.ratingKey = ratingKey
        self.durationMs = durationMs
        self.player = player
        setupObservers()
    }

    package func setStreamOffset(_ offset: Double) {
        streamOffset.withLock { $0 = offset }
    }

    private func setupObservers() {
        guard let player else { return }

        let api = self.api
        let ratingKey = self.ratingKey
        let durationMs = self.durationMs
        let offsetLock = self.streamOffset

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: PlaybackTiming.timelineInterval, preferredTimescale: 1),
            queue: .main
        ) { time in
            guard let position = StreamPosition.absolute(playerSeconds: time.seconds, streamOffset: offsetLock.withLock { $0 }) else { return }
            let timeMs = Int(position * 1000)
            Task {
                await Self.report(api: api, ratingKey: ratingKey, state: "playing", timeMs: timeMs, durationMs: durationMs)
            }
        }

        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { @Sendable observedPlayer, _ in
            guard let position = StreamPosition.absolute(
                playerSeconds: observedPlayer.currentTime().seconds,
                streamOffset: offsetLock.withLock { $0 }
            ) else { return }
            let state: String
            switch observedPlayer.timeControlStatus {
            case .playing: state = "playing"
            case .paused: state = "paused"
            default: return
            }
            let timeMs = Int(position * 1000)
            Task {
                await Self.report(api: api, ratingKey: ratingKey, state: state, timeMs: timeMs, durationMs: durationMs)
            }
        }
    }

    private static func report(api: APIClient, ratingKey: String, state: String, timeMs: Int, durationMs: Int) async {
        do {
            try await api.requestVoid(.timeline(ratingKey: ratingKey, state: state, timeMs: timeMs, durationMs: durationMs))
        } catch {
            log.error("Timeline report (\(state, privacy: .public)) failed for \(ratingKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reports `state` ("paused", for instance) at the current position right away.
    package func send(state: String) async {
        guard let player,
              let position = StreamPosition.absolute(
                playerSeconds: player.currentTime().seconds,
                streamOffset: streamOffset.withLock { $0 }
              ) else { return }
        await Self.report(api: api, ratingKey: ratingKey, state: state, timeMs: Int(position * 1000), durationMs: durationMs)
    }

    private func sendFinalPosition() async {
        guard let player,
              let position = StreamPosition.absolute(
                playerSeconds: player.currentTime().seconds,
                streamOffset: streamOffset.withLock { $0 }
              ) else { return }
        await Self.report(api: api, ratingKey: ratingKey, state: "stopped", timeMs: Int(position * 1000), durationMs: durationMs)
    }

    package func stop() async {
        await sendFinalPosition()
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
        statusObservation = nil
    }
}

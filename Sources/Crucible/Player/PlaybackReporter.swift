import AVFoundation
import Foundation
import os

@MainActor
final class PlaybackReporter {
    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "playback")

    private let api: APIClient
    private let ratingKey: String
    private let sessionId: String
    private let durationMs: Int
    private weak var player: AVPlayer?
    private var timeObserverToken: Any?
    private var statusObservation: NSKeyValueObservation?
    private let streamOffset = OSAllocatedUnfairLock<Double>(initialState: 0)

    init(api: APIClient, ratingKey: String, sessionId: String, durationMs: Int, player: AVPlayer) {
        self.api = api
        self.ratingKey = ratingKey
        self.sessionId = sessionId
        self.durationMs = durationMs
        self.player = player
        setupObservers()
    }

    func setStreamOffset(_ offset: Double) {
        streamOffset.withLock { $0 = offset }
    }

    private func setupObservers() {
        guard let player else { return }

        let api = self.api
        let ratingKey = self.ratingKey
        let durationMs = self.durationMs
        let offsetLock = self.streamOffset

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 10, preferredTimescale: 1),
            queue: .main
        ) { time in
            let position = time.seconds + offsetLock.withLock { $0 }
            guard position.isFinite, position >= 0 else { return }
            let timeMs = Int(position * 1000)
            Task {
                await Self.report(api: api, ratingKey: ratingKey, state: "playing", timeMs: timeMs, durationMs: durationMs)
            }
        }

        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { @Sendable observedPlayer, _ in
            let position = observedPlayer.currentTime().seconds + offsetLock.withLock { $0 }
            guard position.isFinite, position >= 0 else { return }
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

    func sendFinalPosition() async {
        guard let player else { return }
        let position = player.currentTime().seconds + streamOffset.withLock { $0 }
        guard position.isFinite, position >= 0 else { return }
        let timeMs = Int(position * 1000)
        await Self.report(api: api, ratingKey: ratingKey, state: "stopped", timeMs: timeMs, durationMs: durationMs)
    }

    func stop() async {
        await sendFinalPosition()
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
        statusObservation = nil
    }
}

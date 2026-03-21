import AVFoundation
import Foundation

@MainActor
final class PlaybackReporter {
    private let api: APIClient
    private let ratingKey: String
    private let sessionId: String
    private let durationMs: Int
    private weak var player: AVPlayer?
    private var timeObserverToken: Any?
    private var statusObservation: NSKeyValueObservation?

    init(api: APIClient, ratingKey: String, sessionId: String, durationMs: Int, player: AVPlayer) {
        self.api = api
        self.ratingKey = ratingKey
        self.sessionId = sessionId
        self.durationMs = durationMs
        self.player = player
        setupObservers()
    }

    private func setupObservers() {
        guard let player else { return }

        let api = self.api
        let ratingKey = self.ratingKey
        let durationMs = self.durationMs

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 10, preferredTimescale: 1),
            queue: .main
        ) { time in
            let position = time.seconds
            guard position.isFinite, position >= 0 else { return }
            let timeMs = Int(position * 1000)
            Task {
                try? await api.requestVoid(.timeline(
                    ratingKey: ratingKey,
                    state: "playing",
                    timeMs: timeMs,
                    durationMs: durationMs
                ))
            }
        }

        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { observedPlayer, _ in
            let position = observedPlayer.currentTime().seconds
            guard position.isFinite, position >= 0 else { return }
            let state: String
            switch observedPlayer.timeControlStatus {
            case .playing: state = "playing"
            case .paused: state = "paused"
            default: return
            }
            let timeMs = Int(position * 1000)
            Task {
                try? await api.requestVoid(.timeline(
                    ratingKey: ratingKey,
                    state: state,
                    timeMs: timeMs,
                    durationMs: durationMs
                ))
            }
        }
    }

    func sendFinalPosition() async {
        guard let player else { return }
        let position = player.currentTime().seconds
        guard position.isFinite, position >= 0 else { return }
        let timeMs = Int(position * 1000)
        try? await api.requestVoid(.timeline(
            ratingKey: ratingKey,
            state: "stopped",
            timeMs: timeMs,
            durationMs: durationMs
        ))
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

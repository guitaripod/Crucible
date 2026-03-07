import AVFoundation
import Foundation

@MainActor
final class PlaybackReporter {
    private let api: APIClient
    private let mediaId: String
    private weak var player: AVPlayer?
    private var timeObserverToken: Any?
    private var statusObservation: NSKeyValueObservation?

    init(api: APIClient, mediaId: String, player: AVPlayer) {
        self.api = api
        self.mediaId = mediaId
        self.player = player
        setupObservers()
    }

    private func setupObservers() {
        guard let player else { return }

        let api = self.api
        let mediaId = self.mediaId

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 10, preferredTimescale: 1),
            queue: .main
        ) { time in
            let position = time.seconds
            guard position.isFinite, position >= 0 else { return }
            Task {
                try? await api.requestVoid(.updatePlaybackState(
                    id: mediaId,
                    body: UpdatePlaybackRequest(positionSecs: position, event: nil)
                ))
            }
        }

        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { observedPlayer, _ in
            let position = observedPlayer.currentTime().seconds
            guard position.isFinite, position >= 0 else { return }
            let event: String?
            switch observedPlayer.timeControlStatus {
            case .playing: event = "play"
            case .paused: event = "pause"
            default: return
            }
            Task {
                try? await api.requestVoid(.updatePlaybackState(
                    id: mediaId,
                    body: UpdatePlaybackRequest(positionSecs: position, event: event)
                ))
            }
        }
    }

    func sendFinalPosition() async {
        guard let player else { return }
        let position = player.currentTime().seconds
        guard position.isFinite, position >= 0 else { return }
        try? await api.requestVoid(.updatePlaybackState(
            id: mediaId,
            body: UpdatePlaybackRequest(positionSecs: position, event: "pause")
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

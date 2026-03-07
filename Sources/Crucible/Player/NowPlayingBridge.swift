import MediaPlayer
@preconcurrency import UIKit

@MainActor
final class NowPlayingBridge {
    private var artworkTask: Task<Void, Never>?

    func update(
        title: String,
        showName: String?,
        seasonNumber: Int?,
        episodeNumber: Int?,
        duration: Double,
        elapsed: Double,
        rate: Double,
        posterPath: String?,
        baseURL: URL
    ) {
        var info = [String: Any]()

        if let showName, let code = Formatters.episodeCode(seasonNumber, episodeNumber) {
            info[MPMediaItemPropertyTitle] = "\(showName) — \(code)"
            info[MPMediaItemPropertyAlbumTitle] = title
        } else {
            info[MPMediaItemPropertyTitle] = title
        }

        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if let posterPath {
            artworkTask?.cancel()
            artworkTask = Task {
                guard let image = await ImageLoader.shared.loadImage(path: posterPath, size: "w342", baseURL: baseURL) else { return }
                guard !Task.isCancelled else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = artwork
            }
        }
    }

    func updateElapsed(_ elapsed: Double, rate: Double) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = rate
    }

    func clear() {
        artworkTask?.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}

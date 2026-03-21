import AVKit
@preconcurrency import UIKit

@MainActor
final class PlayerCoordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
    struct Metadata: Sendable {
        let title: String
        let showName: String?
        let seasonNumber: Int?
        let episodeNumber: Int?
        let posterPath: String?
        let duration: Double?
    }

    private let api: APIClient
    private let ratingKey: String
    private let mediaType: String
    private let showRatingKey: String?
    private let seasonRatingKey: String?
    private let resumePosition: Double
    private let metadata: Metadata?

    private var player: AVPlayer?
    private var playerVC: AVPlayerViewController?
    private var reporter: PlaybackReporter?
    private var nowPlaying: NowPlayingBridge?
    private var resolveTask: Task<Void, Never>?
    private var isPresenting = false
    private var resolvedStream: ResolvedStream?
    private var interruptionObserver: (any NSObjectProtocol)?
    private var endObserver: (any NSObjectProtocol)?
    private weak var presentingVC: UIViewController?
    private var nextCoordinator: PlayerCoordinator?

    init(
        api: APIClient,
        ratingKey: String,
        mediaType: String,
        showRatingKey: String?,
        seasonRatingKey: String?,
        resumePosition: Double,
        metadata: Metadata? = nil
    ) {
        self.api = api
        self.ratingKey = ratingKey
        self.mediaType = mediaType
        self.showRatingKey = showRatingKey
        self.seasonRatingKey = seasonRatingKey
        self.resumePosition = resumePosition
        self.metadata = metadata
    }

    func present(from viewController: UIViewController) {
        guard !isPresenting else { return }
        isPresenting = true
        presentingVC = viewController

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        spinner.tag = 9999
        viewController.view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: viewController.view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: viewController.view.centerYAnchor),
        ])

        resolveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await StreamResolver.resolve(
                    api: api,
                    ratingKey: ratingKey,
                    startSecs: resumePosition > 0 ? resumePosition : nil
                )
                guard !Task.isCancelled else {
                    removeSpinner(from: viewController)
                    isPresenting = false
                    return
                }
                resolvedStream = stream
                startPlayback(stream: stream, from: viewController)
            } catch {
                guard !Task.isCancelled else {
                    removeSpinner(from: viewController)
                    isPresenting = false
                    return
                }
                removeSpinner(from: viewController)
                isPresenting = false
                let alert = UIAlertController(title: "Playback Error", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                viewController.present(alert, animated: true)
            }
        }
    }

    private func startPlayback(stream: ResolvedStream, from viewController: UIViewController) {
        removeSpinner(from: viewController)

        let player = AVPlayer(url: stream.url)
        player.allowsExternalPlayback = true
        self.player = player

        let playerVC = AVPlayerViewController()
        playerVC.player = player
        playerVC.allowsPictureInPicturePlayback = true
        playerVC.delegate = self
        self.playerVC = playerVC

        let durationMs = metadata.map { Int(($0.duration ?? 0) * 1000) } ?? 0
        reporter = PlaybackReporter(
            api: api,
            ratingKey: ratingKey,
            sessionId: stream.sessionId,
            durationMs: durationMs,
            player: player
        )
        let np = NowPlayingBridge()
        nowPlaying = np

        if let meta = metadata {
            np.update(
                title: meta.title,
                showName: meta.showName,
                seasonNumber: meta.seasonNumber,
                episodeNumber: meta.episodeNumber,
                duration: meta.duration ?? 0,
                elapsed: resumePosition,
                rate: 1.0,
                posterPath: meta.posterPath
            )
        }

        setupInterruptionHandling()
        setupEndObserver()

        if resumePosition > 0 && stream.isDirectPlay {
            let time = CMTime(seconds: resumePosition, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                Task { @MainActor [weak self] in
                    self?.player?.play()
                }
            }
        } else {
            player.play()
        }

        viewController.present(playerVC, animated: true)
    }

    private func setupInterruptionHandling() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo
            let typeValue = info?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = info?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in
                guard let self,
                      let typeValue,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

                if type == .ended, let optionsValue {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) {
                        try? AVAudioSession.sharedInstance().setActive(true)
                        self.player?.play()
                    }
                }
            }
        }
    }

    private func setupEndObserver() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handlePlaybackEnded()
            }
        }
    }

    private func handlePlaybackEnded() {
        guard mediaType == "episode", let seasonRatingKey else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await api.requestContainer(.children(ratingKey: seasonRatingKey))
                let episodes = container.Metadata ?? []
                guard let currentIndex = episodes.firstIndex(where: { $0.ratingKey == ratingKey }),
                      currentIndex + 1 < episodes.count else {
                    let pvc = playerVC
                    await cleanup()
                    pvc?.dismiss(animated: true)
                    return
                }
                let next = episodes[currentIndex + 1]
                let code = Formatters.episodeCode(next.parentIndex, next.index) ?? ""
                let alert = UIAlertController(
                    title: "Up Next",
                    message: "\(code) — \(next.title)",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "Play", style: .default) { [weak self] _ in
                    guard let self else { return }
                    Task {
                        let pvc = self.playerVC
                        await self.cleanup()
                        pvc?.dismiss(animated: true) {
                            guard let presenting = self.presentingVC else { return }
                            let coordinator = PlayerCoordinator(
                                api: self.api,
                                ratingKey: next.ratingKey,
                                mediaType: "episode",
                                showRatingKey: self.showRatingKey,
                                seasonRatingKey: seasonRatingKey,
                                resumePosition: 0,
                                metadata: Metadata(
                                    title: next.title,
                                    showName: next.grandparentTitle,
                                    seasonNumber: next.parentIndex,
                                    episodeNumber: next.index,
                                    posterPath: next.grandparentThumb ?? next.thumb,
                                    duration: next.durationSecs
                                )
                            )
                            self.nextCoordinator = coordinator
                            coordinator.present(from: presenting)
                        }
                    }
                })
                alert.addAction(UIAlertAction(title: "Done", style: .cancel) { [weak self] _ in
                    guard let self else { return }
                    Task {
                        let pvc = self.playerVC
                        await self.cleanup()
                        pvc?.dismiss(animated: true)
                    }
                })
                playerVC?.present(alert, animated: true)
            } catch {
                let pvc = playerVC
                await cleanup()
                pvc?.dismiss(animated: true)
            }
        }
    }

    func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(
        _ playerViewController: AVPlayerViewController
    ) -> Bool {
        false
    }

    nonisolated func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
    ) {
        Task { @MainActor in
            await cleanup()
        }
    }

    private func cleanup() async {
        if let reporter {
            await reporter.stop()
        }
        reporter = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil

        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil

        if let resolvedStream, !resolvedStream.isDirectPlay {
            try? await api.requestVoid(.stopTranscode(session: resolvedStream.sessionId))
        }

        player?.replaceCurrentItem(with: nil)
        playerVC?.player = nil

        nowPlaying?.clear()
        nowPlaying = nil

        player = nil
        playerVC = nil
        isPresenting = false
    }

    private func removeSpinner(from viewController: UIViewController) {
        viewController.view.viewWithTag(9999)?.removeFromSuperview()
    }
}

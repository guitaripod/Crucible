import AVKit
import os
@preconcurrency import UIKit

@MainActor
final class PlayerCoordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "playback")

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
    private let selectedSubtitleId: Int?
    private let selectedAudioStreamId: Int?

    private var player: AVPlayer?
    private var playerVC: AVPlayerViewController?
    private var reporter: PlaybackReporter?
    private var nowPlaying: NowPlayingBridge?
    private var resolveTask: Task<Void, Never>?
    private var isPresenting = false
    private var resolvedStream: ResolvedStream?
    private var interruptionObserver: (any NSObjectProtocol)?
    private var endObserver: (any NSObjectProtocol)?
    private var nowPlayingObserver: Any?
    private var upNextOverlay: UpNextOverlayView?
    private var isFinishing = false
    private var currentStreamOffset: Double = 0
    private var restartItemObserver: NSKeyValueObservation?
    private var pingTask: Task<Void, Never>?
    private var seekObserver: (any NSObjectProtocol)?
    private var isRestarting = false
    private weak var presentingVC: UIViewController?
    private var nextCoordinator: PlayerCoordinator?
    private weak var spinnerView: UIActivityIndicatorView?
    var onAdvanceToNext: ((PlayerCoordinator) -> Void)?

    init(
        api: APIClient,
        ratingKey: String,
        mediaType: String,
        showRatingKey: String?,
        seasonRatingKey: String?,
        resumePosition: Double,
        metadata: Metadata? = nil,
        selectedSubtitleId: Int? = nil,
        selectedAudioStreamId: Int? = nil
    ) {
        self.api = api
        self.ratingKey = ratingKey
        self.mediaType = mediaType
        self.showRatingKey = showRatingKey
        self.seasonRatingKey = seasonRatingKey
        self.resumePosition = resumePosition
        self.metadata = metadata
        self.selectedSubtitleId = selectedSubtitleId
        self.selectedAudioStreamId = selectedAudioStreamId
    }

    func present(from viewController: UIViewController) {
        guard !isPresenting else { return }
        isPresenting = true
        presentingVC = viewController
        AppLogger.notice("Play requested ratingKey=\(ratingKey) type=\(mediaType) resumeSecs=\(Int(resumePosition))", .playback)

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        viewController.view.addSubview(spinner)
        spinnerView = spinner
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
                    startSecs: resumePosition > 0 ? resumePosition : nil,
                    selectedSubtitleId: selectedSubtitleId,
                    selectedAudioStreamId: selectedAudioStreamId
                )
                guard !Task.isCancelled else {
                    spinnerView?.removeFromSuperview()
                    isPresenting = false
                    return
                }
                resolvedStream = stream
                AppLogger.notice("Stream resolved directPlay=\(stream.isDirectPlay) subs=\(stream.subtitles.count) audio=\(stream.audioTracks.count)", .playback)
                startPlayback(stream: stream, from: viewController)
            } catch {
                guard !Task.isCancelled else {
                    spinnerView?.removeFromSuperview()
                    isPresenting = false
                    return
                }
                spinnerView?.removeFromSuperview()
                isPresenting = false
                AppLogger.error("Stream resolve failed for ratingKey=\(ratingKey): \(error.localizedDescription)", .playback)
                let alert = UIAlertController(title: "Playback Error", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                viewController.present(alert, animated: true)
            }
        }
    }

    private func startPlayback(stream: ResolvedStream, from viewController: UIViewController) {
        spinnerView?.removeFromSuperview()

        let player = AVPlayer(url: stream.url)
        player.allowsExternalPlayback = true
        self.player = player

        let playerVC = AVPlayerViewController()
        playerVC.player = player
        playerVC.allowsPictureInPicturePlayback = true
        playerVC.modalPresentationStyle = .fullScreen
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

        currentStreamOffset = stream.isDirectPlay ? 0 : resumePosition
        reporter?.setStreamOffset(currentStreamOffset)
        if !stream.isDirectPlay {
            startPingTimer(session: stream.sessionId)
        }

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
        setupSeekObserver()
        setupNowPlayingObserver()

        if resumePosition > 0 && stream.isDirectPlay {
            let time = CMTime(seconds: resumePosition, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { @Sendable [weak self] _ in
                Task { @MainActor in
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
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
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

    private func setupNowPlayingObserver() {
        guard let player else { return }
        nowPlayingObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 5, preferredTimescale: 1),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            guard seconds.isFinite, seconds >= 0 else { return }
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.nowPlaying?.updateElapsed(seconds + self.currentStreamOffset, rate: Double(player.rate))
            }
        }
    }

    private func setupSeekObserver() {
        guard let stream = resolvedStream, !stream.isDirectPlay else { return }
        if let seekObserver {
            NotificationCenter.default.removeObserver(seekObserver)
        }
        seekObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification,
            object: player?.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSeek()
            }
        }
    }

    private func handleSeek() {
        guard !isRestarting, let item = player?.currentItem else { return }
        let target = currentStreamOffset + max(0, item.currentTime().seconds)
        restartTranscode(atAbsolute: target)
    }

    private func restartTranscode(atAbsolute target: Double) {
        guard let player, let stream = resolvedStream, !isRestarting else { return }
        guard let url = StreamResolver.transcodeRestartURL(
            api: api,
            ratingKey: ratingKey,
            offsetSecs: target,
            sessionId: stream.sessionId,
            burnSubtitle: selectedSubtitleId != nil
        ) else { return }

        isRestarting = true
        AppLogger.notice("Scrub: restarting transcode at \(Int(target))s", .playback)
        currentStreamOffset = target
        reporter?.setStreamOffset(target)

        let item = AVPlayerItem(url: url)
        restartItemObserver?.invalidate()
        restartItemObserver = item.observe(\.status, options: [.new]) { @Sendable observedItem, _ in
            guard observedItem.status != .unknown else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if observedItem.status == .readyToPlay {
                    self.player?.play()
                }
                self.isRestarting = false
                self.restartItemObserver?.invalidate()
                self.restartItemObserver = nil
            }
        }
        player.replaceCurrentItem(with: item)
        setupEndObserver()
        setupSeekObserver()
    }

    private func startPingTimer(session: String) {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self else { return }
                try? await self.api.requestVoid(.pingTranscode(session: session))
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
                guard let currentIndex = episodes.firstIndex(where: { $0.id == ratingKey }),
                      currentIndex + 1 < episodes.count else {
                    await dismissPlayer()
                    return
                }
                presentUpNext(next: episodes[currentIndex + 1], seasonRatingKey: seasonRatingKey)
            } catch {
                await dismissPlayer()
            }
        }
    }

    private func presentUpNext(next: PlexMetadata, seasonRatingKey: String) {
        guard !isFinishing, upNextOverlay == nil else { return }
        guard let playerVC, let host = playerVC.contentOverlayView else {
            Task { await dismissPlayer() }
            return
        }
        let overlay = UpNextOverlayView(
            episodeCode: Formatters.episodeCode(next.parentIndex, next.index),
            episodeTitle: next.title,
            onPlayNext: { [weak self] in self?.playNext(next, seasonRatingKey: seasonRatingKey) },
            onDismiss: { [weak self] in Task { await self?.dismissPlayer() } }
        )
        overlay.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.trailingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            overlay.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            overlay.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            overlay.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            overlay.leadingAnchor.constraint(greaterThanOrEqualTo: host.safeAreaLayoutGuide.leadingAnchor, constant: 24),
        ])
        upNextOverlay = overlay
        overlay.startCountdown()
    }

    private func playNext(_ next: PlexMetadata, seasonRatingKey: String) {
        guard !isFinishing else { return }
        isFinishing = true
        removeUpNextOverlay()
        let pvc = playerVC
        Task { [weak self] in
            guard let self else { return }
            await self.cleanup()
            pvc?.dismiss(animated: true) {
                guard let presenting = self.presentingVC else { return }
                let coordinator = PlayerCoordinator(
                    api: self.api,
                    ratingKey: next.id,
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
                coordinator.onAdvanceToNext = self.onAdvanceToNext
                if let onAdvanceToNext = self.onAdvanceToNext {
                    onAdvanceToNext(coordinator)
                } else {
                    self.nextCoordinator = coordinator
                }
                coordinator.present(from: presenting)
            }
        }
    }

    private func dismissPlayer() async {
        guard !isFinishing else { return }
        isFinishing = true
        let pvc = playerVC
        await cleanup()
        pvc?.dismiss(animated: true)
    }

    private func removeUpNextOverlay() {
        upNextOverlay?.removeFromSuperview()
        upNextOverlay = nil
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
        MainActor.assumeIsolated {
            _ = coordinator.animate(alongsideTransition: nil) { context in
                guard !context.isCancelled else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isFinishing = true
                    self.removeUpNextOverlay()
                    await self.cleanup()
                }
            }
        }
    }

    private func cleanup() async {
        removeUpNextOverlay()

        pingTask?.cancel()
        pingTask = nil
        restartItemObserver?.invalidate()
        restartItemObserver = nil
        if let seekObserver {
            NotificationCenter.default.removeObserver(seekObserver)
        }
        seekObserver = nil

        if let reporter {
            await reporter.stop()
        }
        reporter = nil

        await api.invalidate(ratingKey: ratingKey)
        if let seasonRatingKey { await api.invalidate(ratingKey: seasonRatingKey) }
        if let showRatingKey { await api.invalidate(ratingKey: showRatingKey) }

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil

        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil

        if let nowPlayingObserver {
            player?.removeTimeObserver(nowPlayingObserver)
        }
        nowPlayingObserver = nil

        if let resolvedStream, !resolvedStream.isDirectPlay {
            do {
                try await api.requestVoid(.stopTranscode(session: resolvedStream.sessionId))
            } catch {
                Self.log.error("Stop transcode failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        player?.replaceCurrentItem(with: nil)
        playerVC?.player = nil

        nowPlaying?.clear()
        nowPlaying = nil

        player = nil
        playerVC = nil
        isPresenting = false
    }

}

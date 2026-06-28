import AVKit
import MediaPlayer
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
    private let offlineAsset: OfflineAsset?

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
    private var offlineResumeObserver: NSKeyValueObservation?
    private var pingTask: Task<Void, Never>?
    private var seekObserver: (any NSObjectProtocol)?
    private var isRestarting = false
    private var lastPlayhead: Double = 0
    private var lastOfflineWrite: Double = 0
    private var markers: [PlexMarker] = []
    private var skipButton: UIButton?
    private var upNextTriggered = false
    private var remoteCommandsConfigured = false
    private var isInPiP = false
    private var pipRestoreInProgress = false
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
        selectedAudioStreamId: Int? = nil,
        offlineAsset: OfflineAsset? = nil
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
        self.offlineAsset = offlineAsset
    }

    func present(from viewController: UIViewController) {
        guard !isPresenting else { return }
        isPresenting = true
        presentingVC = viewController
        AppLogger.notice("Play requested ratingKey=\(ratingKey) type=\(mediaType) resumeSecs=\(Int(resumePosition))", .playback)

        if let offlineAsset {
            AppLogger.notice("Playing offline asset for ratingKey=\(ratingKey)", .playback)
            let stream = ResolvedStream(
                url: offlineAsset.fileURL,
                isDirectPlay: true,
                sessionId: "offline",
                subtitles: [],
                audioTracks: [],
                markers: offlineAsset.markers
            )
            resolvedStream = stream
            startPlayback(stream: stream, from: viewController)
            return
        }

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
        playerVC.canStartPictureInPictureAutomaticallyFromInline = true
        playerVC.modalPresentationStyle = .fullScreen
        playerVC.speeds = AVPlaybackSpeed.systemDefaultSpeeds
        playerVC.delegate = self
        self.playerVC = playerVC

        if offlineAsset == nil {
            let durationMs = metadata.map { Int(($0.duration ?? 0) * 1000) } ?? 0
            reporter = PlaybackReporter(
                api: api,
                ratingKey: ratingKey,
                sessionId: stream.sessionId,
                durationMs: durationMs,
                player: player
            )
        }
        let np = NowPlayingBridge()
        nowPlaying = np

        currentStreamOffset = stream.isDirectPlay ? 0 : resumePosition
        reporter?.setStreamOffset(currentStreamOffset)
        markers = stream.markers
        upNextTriggered = false
        configureRemoteCommands()
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

        if resumePosition > 0, offlineAsset != nil {
            seekOfflineResumeWhenReady()
        } else if resumePosition > 0, stream.isDirectPlay {
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

    /// HLS (offline downloads served over the loopback server) only accepts seeks at segment
    /// boundaries once the item is ready, so resume waits for `.readyToPlay` and seeks with tolerance
    /// instead of the eager zero-tolerance seek used for true direct-play files.
    private func seekOfflineResumeWhenReady() {
        guard let player, let item = player.currentItem else { player?.play(); return }
        let target = resumePosition
        offlineResumeObserver?.invalidate()
        offlineResumeObserver = item.observe(\.status, options: [.new]) { @Sendable observedItem, _ in
            guard observedItem.status != .unknown else { return }
            let ready = observedItem.status == .readyToPlay
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.offlineResumeObserver?.invalidate()
                self.offlineResumeObserver = nil
                guard ready else { self.player?.play(); return }
                self.player?.seek(
                    to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 3, preferredTimescale: 600),
                    toleranceAfter: .positiveInfinity
                ) { @Sendable _ in
                    Task { @MainActor [weak self] in self?.player?.play() }
                }
            }
        }
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
            forInterval: CMTime(seconds: 1, preferredTimescale: 1),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            guard seconds.isFinite, seconds >= 0 else { return }
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.lastPlayhead = seconds
                let absolute = seconds + self.currentStreamOffset
                self.nowPlaying?.updateElapsed(absolute, rate: Double(player.rate))
                self.updateSkipUI(absolute: absolute)
                if self.offlineAsset != nil, absolute - self.lastOfflineWrite >= 10 {
                    self.lastOfflineWrite = absolute
                    DownloadManager.shared.recordOfflineProgress(ratingKey: self.ratingKey, positionSecs: absolute)
                }
            }
        }
    }

    private func updateSkipUI(absolute: Double) {
        if !upNextTriggered, mediaType == "episode", let credits = markers.first(where: { $0.isCredits }), absolute >= credits.startSecs {
            upNextTriggered = true
            showUpNext(dismissIfLast: false)
        }

        let active = markers.first { absolute >= $0.startSecs && absolute < $0.endSecs - 1 }
        guard let active, upNextOverlay == nil else {
            removeSkipButton()
            return
        }
        showSkipButton(title: active.isCredits ? "Skip Credits" : "Skip Intro", target: active.endSecs)
    }

    private func showSkipButton(title: String, target: Double) {
        guard let host = playerVC?.contentOverlayView else { return }
        let button: UIButton
        if let existing = skipButton {
            button = existing
        } else {
            var config = Glass.prominentButton {
                var fallback = UIButton.Configuration.filled()
                fallback.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
                fallback.baseForegroundColor = .white
                return fallback
            }
            config.cornerStyle = .capsule
            config.image = UIImage(systemName: "forward.end.fill")
            config.imagePadding = 6
            let created = UIButton(configuration: config)
            created.tintColor = .white
            created.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(created)
            NSLayoutConstraint.activate([
                created.trailingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.trailingAnchor, constant: -28),
                created.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -90),
            ])
            skipButton = created
            button = created
        }
        button.configuration?.title = title
        button.removeTarget(nil, action: nil, for: .primaryActionTriggered)
        button.addAction(UIAction { [weak self] _ in self?.seekToAbsolute(target) }, for: .primaryActionTriggered)
        button.isHidden = false
    }

    private func removeSkipButton() {
        skipButton?.removeFromSuperview()
        skipButton = nil
    }

    private func seekToAbsolute(_ target: Double) {
        removeSkipButton()
        guard let stream = resolvedStream else { return }
        if stream.isDirectPlay {
            player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { @Sendable [weak self] _ in
                Task { @MainActor in self?.player?.play() }
            }
        } else {
            restartTranscode(atAbsolute: target)
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
        let now = item.currentTime().seconds
        guard now.isFinite else { return }
        let jump = abs(now - lastPlayhead)
        lastPlayhead = now
        guard jump > 5 else { return }
        restartTranscode(atAbsolute: currentStreamOffset + max(0, now))
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
        lastPlayhead = 0
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

    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let player = self?.player else { return }
                if player.timeControlStatus == .playing { player.pause() } else { player.play() }
            }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] event in
            guard let skip = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            let interval = skip.interval
            Task { @MainActor in
                guard let player = self?.player else { return }
                player.seek(to: CMTime(seconds: player.currentTime().seconds + interval, preferredTimescale: 600))
            }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] event in
            guard let skip = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            let interval = skip.interval
            Task { @MainActor in
                guard let player = self?.player else { return }
                player.seek(to: CMTime(seconds: max(0, player.currentTime().seconds - interval), preferredTimescale: 600))
            }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in
                guard let self else { return }
                if self.resolvedStream?.isDirectPlay == false {
                    self.restartTranscode(atAbsolute: position)
                } else {
                    self.player?.seek(to: CMTime(seconds: position, preferredTimescale: 600))
                }
            }
            return .success
        }
        center.nextTrackCommand.isEnabled = mediaType == "episode"
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.showUpNext(dismissIfLast: false) }
            return .success
        }
    }

    private func tearDownRemoteCommands() {
        guard remoteCommandsConfigured else { return }
        remoteCommandsConfigured = false
        let center = MPRemoteCommandCenter.shared()
        let commands: [MPRemoteCommand] = [
            center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
            center.skipForwardCommand, center.skipBackwardCommand,
            center.changePlaybackPositionCommand, center.nextTrackCommand,
        ]
        commands.forEach { $0.removeTarget(nil) }
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
        showUpNext(dismissIfLast: true)
    }

    private func showUpNext(dismissIfLast: Bool) {
        guard mediaType == "episode", let seasonRatingKey else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await api.requestContainer(.children(ratingKey: seasonRatingKey))
                let episodes = container.Metadata ?? []
                guard let currentIndex = episodes.firstIndex(where: { $0.id == ratingKey }),
                      currentIndex + 1 < episodes.count else {
                    if dismissIfLast { await dismissPlayer() }
                    return
                }
                presentUpNext(next: episodes[currentIndex + 1], seasonRatingKey: seasonRatingKey)
            } catch {
                if dismissIfLast { await dismissPlayer() }
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

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isInPiP = true
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        pipRestoreInProgress = true
        completionHandler(true)
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isInPiP = false
        if pipRestoreInProgress {
            pipRestoreInProgress = false
            return
        }
        guard !isFinishing else { return }
        Task { @MainActor in await self.dismissPlayer() }
    }

    nonisolated func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
    ) {
        MainActor.assumeIsolated {
            _ = coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard let self, !context.isCancelled, !self.isInPiP else { return }
                Task { @MainActor [weak self] in
                    guard let self, !self.isInPiP else { return }
                    self.isFinishing = true
                    self.removeUpNextOverlay()
                    await self.cleanup()
                }
            }
        }
    }

    private func cleanup() async {
        let offlineFinalPosition: Double?
        if offlineAsset != nil {
            let position = player?.currentTime().seconds ?? lastPlayhead
            offlineFinalPosition = (position.isFinite && position >= 0) ? position : nil
        } else {
            offlineFinalPosition = nil
        }
        removeUpNextOverlay()
        removeSkipButton()
        tearDownRemoteCommands()

        pingTask?.cancel()
        pingTask = nil
        restartItemObserver?.invalidate()
        restartItemObserver = nil
        offlineResumeObserver?.invalidate()
        offlineResumeObserver = nil
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

        if let offlineFinalPosition {
            DownloadManager.shared.recordOfflineProgress(ratingKey: ratingKey, positionSecs: offlineFinalPosition, deleteIfWatched: true)
        }

        nowPlaying?.clear()
        nowPlaying = nil

        player = nil
        playerVC = nil
        isPresenting = false
    }

}

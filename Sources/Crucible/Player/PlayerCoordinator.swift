import AVKit
import CrucibleCore
import CrucibleDesign
import CrucibleMedia
@preconcurrency import UIKit

@MainActor
final class PlayerCoordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
    private static weak var resolvingCoordinator: PlayerCoordinator?
    /// The player that started last. On iPad each window can hold a player; starting one pauses the other, so only one plays at a time.
    private static weak var playingCoordinator: PlayerCoordinator?

    typealias Metadata = PlaybackMetadata

    private let api: APIClient
    private let request: PlaybackRequest
    private let session: PlaybackSession

    private var playerVC: AVPlayerViewController?
    private var nowPlaying: NowPlayingBridge?
    private var resolveTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var isPresenting = false
    private var upNextOverlay: UpNextOverlayView?
    private var pendingUpNext: UpNextOffer?
    private var foregroundObserver: (any NSObjectProtocol)?
    private var suspensionObservers: [any NSObjectProtocol] = []
    private var isFinishing = false
    private var lastOfflineWrite: Double = 0
    private var skipPill: SkipPillView?
    private var shownSkip: (title: String, target: Double)?
    private var shownUpNext: UpNextOffer?
    private var skipToast: SkipToastView?
    private var isInPiP = false
    private var pipRestoreInProgress = false
    private weak var presentingVC: UIViewController?
    private weak var windowScene: UIWindowScene?
    private var nextCoordinator: PlayerCoordinator?
    private weak var spinnerView: UIActivityIndicatorView?
    var onAdvanceToNext: ((PlayerCoordinator) -> Void)?

    convenience init(
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
        self.init(
            api: api,
            request: PlaybackRequest(
                ratingKey: ratingKey,
                mediaType: mediaType,
                showRatingKey: showRatingKey,
                seasonRatingKey: seasonRatingKey,
                resumePosition: resumePosition,
                metadata: metadata,
                selectedSubtitleId: selectedSubtitleId,
                selectedAudioStreamId: selectedAudioStreamId,
                offline: offlineAsset.map(Self.offlineSource)
            )
        )
    }

    init(api: APIClient, request: PlaybackRequest) {
        self.api = api
        self.request = request
        self.session = PlaybackSession(api: api, request: request)
    }

    private static func offlineSource(from asset: OfflineAsset) -> OfflinePlaybackSource {
        OfflinePlaybackSource(fileURL: asset.fileURL, markers: asset.markers, durationSecs: asset.durationSecs)
    }

    func present(from viewController: UIViewController) {
        guard !isPresenting else { return }
        isPresenting = true
        presentingVC = viewController
        if let resolving = Self.resolvingCoordinator, resolving !== self {
            resolving.cancel()
        }
        AppLogger.notice("Play requested ratingKey=\(request.ratingKey) type=\(request.mediaType) resumeSecs=\(Int(request.resumePosition))", .playback)

        if request.offline != nil {
            AppLogger.notice("Playing offline asset for ratingKey=\(request.ratingKey)", .playback)
            startPlayback(from: viewController)
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

        Self.resolvingCoordinator = self
        resolveTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if Self.resolvingCoordinator === self { Self.resolvingCoordinator = nil }
            }
            do {
                let stream = try await session.prepare()
                AppLogger.notice("Stream resolved directPlay=\(stream.isDirectPlay) subs=\(stream.subtitles.count) audio=\(stream.audioTracks.count)", .playback)
                startPlayback(from: viewController)
            } catch {
                spinnerView?.removeFromSuperview()
                isPresenting = false
                guard !Task.isCancelled else { return }
                AppLogger.error("Stream resolve failed for ratingKey=\(request.ratingKey): \(error.localizedDescription)", .playback)
                let alert = UIAlertController(title: "Playback Error", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                viewController.present(alert, animated: true)
            }
        }
    }

    /// Aborts a resolve that has not yet produced a player, so a coordinator replaced
    /// mid-resolve does not leak a detached AVPlayer or a live transcode session.
    func cancel() {
        guard session.player == nil else { return }
        resolveTask?.cancel()
        resolveTask = nil
        spinnerView?.removeFromSuperview()
        isPresenting = false
        if Self.resolvingCoordinator === self { Self.resolvingCoordinator = nil }
    }

    private func startPlayback(from viewController: UIViewController) {
        spinnerView?.removeFromSuperview()

        guard viewController.presentedViewController == nil, viewController.view.window != nil else {
            AppLogger.error("Presentation unavailable for ratingKey=\(request.ratingKey); abandoning playback", .playback)
            isPresenting = false
            session.discard()
            return
        }

        guard let player = session.begin() else {
            AppLogger.error("Playback session unusable for ratingKey=\(request.ratingKey); abandoning playback", .playback)
            isPresenting = false
            return
        }
        if let other = Self.playingCoordinator, other !== self {
            other.session.player?.pause()
        }
        Self.playingCoordinator = self

        let playerVC = AVPlayerViewController()
        playerVC.player = player
        playerVC.allowsPictureInPicturePlayback = true
        playerVC.canStartPictureInPictureAutomaticallyFromInline = true
        playerVC.modalPresentationStyle = .fullScreen
        playerVC.speeds = AVPlaybackSpeed.systemDefaultSpeeds
        playerVC.delegate = self
        self.playerVC = playerVC

        let np = NowPlayingBridge()
        nowPlaying = np
        if let meta = request.metadata {
            np.update(
                title: meta.title,
                showName: meta.showName,
                seasonNumber: meta.seasonNumber,
                episodeNumber: meta.episodeNumber,
                duration: meta.duration ?? 0,
                elapsed: request.resumePosition,
                rate: 1.0,
                posterPath: meta.posterPath
            )
        }

        windowScene = viewController.view.window?.windowScene
        setupForegroundObserver()
        observeSuspension()
        observeEvents()

        if let title = request.metadata?.title {
            windowScene?.title = title
        }
        viewController.present(playerVC, animated: true) {
            DemoTour.shared.record(.play)
        }
    }

    private func observeEvents() {
        let events = session.events
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                handle(event)
            }
        }
    }

    private func handle(_ event: PlaybackEvent) {
        switch event {
        case .position(let absolute, let rate):
            nowPlaying?.updateElapsed(absolute, rate: rate)
            recordOfflineProgress(at: absolute)
        case .skipAvailable(let marker, let progress):
            showSkipButton(for: marker, progress: progress)
        case .skipHidden:
            removeSkipButton()
        case .autoSkipped(_, let position):
            removeSkipButton()
            Haptics.light()
            showSkipToast(returningTo: position)
        case .autoSkipUndoExpired:
            removeSkipToast(animated: true)
        case .upNext(let offer):
            presentUpNext(offer)
        case .failed(let message):
            showPlaybackError(message)
        case .finished(let finish):
            guard finish == .noNextEpisode, !isInPiP else { return }
            Task { await dismissPlayer() }
        }
    }

    private func recordOfflineProgress(at absolute: Double) {
        guard request.offline != nil, abs(absolute - lastOfflineWrite) >= 10 else { return }
        lastOfflineWrite = absolute
        DownloadManager.shared.recordOfflineProgress(ratingKey: request.ratingKey, positionSecs: absolute)
    }

    private func showPlaybackError(_ message: String) {
        let alert = UIAlertController(title: "Playback Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        (playerVC ?? presentingVC)?.present(alert, animated: true)
    }

    private func setupForegroundObserver() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification,
            object: windowScene,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isInPiP else { return }
                self.flushPendingUpNext()
            }
        }
    }

    /// A paused player is held at its position while its window is away and put back there on return, which
    /// rebuilds a transcode the server reaped meanwhile; one that plays on in the background (audio,
    /// Picture-in-Picture) is only saved and reported. These follow the player's own window, so on iPad
    /// that window going to the background counts as leaving even while another Crucible window stays
    /// up, and closing the window ends playback.
    private func observeSuspension() {
        let center = NotificationCenter.default
        suspensionObservers = [
            center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: windowScene, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.suspendSession() }
            },
            center.addObserver(forName: UIScene.willEnterForegroundNotification, object: windowScene, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.session.recoverAfterSuspension() }
            },
            center.addObserver(forName: UIScene.didDisconnectNotification, object: windowScene, queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in await self.windowClosed() }
            },
        ]
    }

    /// A closed window takes its player with it: the session is stopped and reported like a dismissal, so the server
    /// ends the transcode and keeps the position.
    private func windowClosed() async {
        AppLogger.notice("Player window closed ratingKey=\(request.ratingKey)", .playback)
        isInPiP = false
        await dismissPlayer()
    }

    private func suspendSession() async {
        let application = UIApplication.shared
        let task = application.beginBackgroundTask(withName: "playback-suspend")
        await session.suspend(pausing: false)
        if task != .invalid { application.endBackgroundTask(task) }
    }

    private func showSkipToast(returningTo position: Double) {
        guard let host = playerVC?.contentOverlayView else { return }
        removeSkipToast(animated: false)
        let toast = SkipToastView(message: "Skipped intro") { [weak self] in
            Haptics.light()
            self?.undoSkip(returningTo: position)
        }
        toast.present(in: host)
        skipToast = toast
    }

    private func undoSkip(returningTo position: Double) {
        removeSkipToast(animated: true)
        removeSkipButton()
        session.undoAutoSkip(returnTo: position)
    }

    private func removeSkipToast(animated: Bool) {
        skipToast?.dismiss(animated: animated)
        skipToast = nil
    }

    private func showSkipButton(for marker: SkipMarker, progress: Double) {
        guard let host = playerVC?.contentOverlayView else { return }
        let pill: SkipPillView
        if let existing = skipPill {
            pill = existing
        } else {
            pill = SkipPillView()
            pill.present(in: host)
            skipPill = pill
        }
        let target = marker.endSecs
        pill.onTap = { [weak self] in
            Haptics.light()
            self?.skip(to: target)
        }
        pill.update(title: marker.title, accessibilityTitle: marker.title, progress: progress)
        shownSkip = (marker.title, target)
    }

    private func skip(to target: Double) {
        removeSkipButton()
        session.seek(toAbsolute: target)
    }

    private func removeSkipButton() {
        skipPill?.dismiss(animated: true)
        skipPill = nil
        shownSkip = nil
    }

    private func presentUpNext(_ offer: UpNextOffer) {
        guard !isFinishing, upNextOverlay == nil else { return }
        if isInPiP || UIApplication.shared.applicationState != .active {
            pendingUpNext = offer
            return
        }
        guard let playerVC, let host = playerVC.contentOverlayView else {
            Task { await dismissPlayer() }
            return
        }
        removeSkipToast(animated: false)
        let next = offer.episode
        let overlay = UpNextOverlayView(
            content: UpNextOverlayView.Content(
                seasonNumber: next.parentIndex,
                episodeNumber: next.index,
                episodeTitle: next.title,
                thumbPath: next.thumb,
                autoplays: offer.autoplays
            ),
            countdownSeconds: UpNextOffer.countdownSeconds,
            onPlayNext: { [weak self] in self?.playNext(offer) },
            onDismiss: { [weak self] in Task { await self?.dismissPlayer() } }
        )
        overlay.present(in: host)
        upNextOverlay = overlay
        shownUpNext = offer
        session.setUpNextVisible(true)
        overlay.startCountdown()
    }

    private func flushPendingUpNext() {
        guard let pending = pendingUpNext, !isFinishing else { return }
        pendingUpNext = nil
        if pending.playbackEnded, pending.autoplays {
            playNext(pending)
        } else {
            presentUpNext(pending)
        }
    }

    private func playNext(_ offer: UpNextOffer) {
        guard !isFinishing else { return }
        isFinishing = true
        removeUpNextOverlay()
        let pvc = playerVC
        Task { [weak self] in
            guard let self else { return }
            await self.cleanup()
            pvc?.dismiss(animated: true) {
                guard let presenting = self.presentingVC else { return }
                let offline = DownloadManager.shared.offlineAsset(for: offer.episode.id).map(Self.offlineSource)
                let coordinator = PlayerCoordinator(
                    api: self.api,
                    request: offer.nextRequest(showRatingKey: self.request.showRatingKey, offline: offline)
                )
                if let onAdvanceToNext = self.onAdvanceToNext {
                    coordinator.onAdvanceToNext = onAdvanceToNext
                    onAdvanceToNext(coordinator)
                } else {
                    coordinator.onAdvanceToNext = { [weak self] advanced in self?.nextCoordinator = advanced }
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
        upNextOverlay?.dismiss()
        upNextOverlay = nil
        shownUpNext = nil
        session.setUpNextVisible(false)
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
            flushPendingUpNext()
            return
        }
        pendingUpNext = nil
        guard !isFinishing else { return }
        Task { @MainActor in await self.dismissPlayer() }
    }

    nonisolated func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
    ) {
        MainActor.assumeIsolated {
            _ = coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard let self, !context.isCancelled, !self.isInPiP, !self.isFinishing else { return }
                Task { @MainActor [weak self] in
                    guard let self, !self.isInPiP, !self.isFinishing else { return }
                    self.isFinishing = true
                    self.removeUpNextOverlay()
                    await self.cleanup()
                }
            }
        }
    }

    private func cleanup() async {
        removeUpNextOverlay()
        skipPill?.dismiss(animated: false)
        skipPill = nil
        shownSkip = nil
        removeSkipToast(animated: false)
        pendingUpNext = nil
        eventsTask?.cancel()
        eventsTask = nil
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        foregroundObserver = nil
        suspensionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        suspensionObservers.removeAll()

        let finalPosition = await session.stop()
        playerVC?.player = nil

        if request.offline != nil, let finalPosition {
            DownloadManager.shared.recordOfflineProgress(ratingKey: request.ratingKey, positionSecs: finalPosition, deleteIfWatched: true)
        }

        nowPlaying?.clear()
        nowPlaying = nil

        playerVC = nil
        isPresenting = false
        (presentingVC?.tabBarController as? TabBarController)?.updateWindowTitle()
    }

    // MARK: - Keyboard

    /// What the on-screen skip button offers right now ("Skip Intro"), so the keyboard can take it too.
    var skipTitle: String? { shownSkip?.title }

    var offersNextEpisode: Bool { shownUpNext != nil }

    func performShownSkip() {
        guard let shownSkip else { return }
        Haptics.light()
        skip(to: shownSkip.target)
    }

    func close() {
        Task { await dismissPlayer() }
    }

    func playOfferedNextEpisode() {
        guard let shownUpNext else { return }
        playNext(shownUpNext)
    }

}

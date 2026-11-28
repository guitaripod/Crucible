import AVKit
import CrucibleCore
import CrucibleDesign
import CrucibleMedia
import MidgarCore
@preconcurrency import UIKit

@MainActor
final class PlayerCoordinator: NSObject {
    private static weak var resolvingCoordinator: PlayerCoordinator?
    /// How long a start may take before a spinner says so: a title that was made ready, or resolves quickly, shows none.
    private static let spinnerDelay: TimeInterval = 0.3
    /// The player that started last. On iPad each window can hold a player; starting one pauses the other, so only one plays at a time.
    private static weak var playingCoordinator: PlayerCoordinator?
    #if DEBUG
    static var current: PlayerCoordinator? { playingCoordinator }
    #endif

    typealias Metadata = PlaybackMetadata

    let api: APIClient
    /// The item on screen, replaced without taking the player off screen when the next episode starts.
    private(set) var request: PlaybackRequest
    private(set) var session: PlaybackSession

    private(set) var playerVC: AVPlayerViewController?
    private var nowPlaying: NowPlayingBridge?
    private var resolveTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var advanceTask: Task<Void, Never>?
    private var isPresenting = false
    private var isAdvancing = false
    private var upNextOverlay: UpNextOverlayView?
    private var postPlay: PostPlayViewController?
    private var postPlayTask: Task<Void, Never>?
    var pendingUpNext: UpNextOffer?
    private var foregroundObserver: (any NSObjectProtocol)?
    private var suspensionObservers: [any NSObjectProtocol] = []
    private(set) var isFinishing = false
    /// Shrunk into the bar above the tab bar, playing on while the viewer browses.
    var isDocked = false
    /// The window's dock that holds this player while it plays.
    weak var dock: MiniPlayerDock?
    private var lastOfflineWrite: Double = 0
    private var skipPill: SkipPillView?
    private var moreButton: PlayerMoreButton?
    var scrubPreview: ScrubPreview?
    var shownSkip: (title: String, target: Double)?
    var shownUpNext: UpNextOffer?
    private var skipToast: SkipToastView?
    private var advanceIndicator: AdvanceIndicator?
    var isInPiP = false
    var pipRestoreInProgress = false
    private weak var presentingVC: UIViewController?
    private weak var windowScene: UIWindowScene?
    private weak var spinnerView: UIActivityIndicatorView?
    private(set) var unattendedEpisodes = 0
    private(set) var viewerActedThisEpisode = true

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
        offlineAsset: OfflineAsset? = nil,
        queue: PlaybackQueue? = nil,
        serverStart: ServerStart? = nil
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
                offline: offlineAsset.map { Self.offlineSource(from: $0) },
                queue: queue,
                serverStart: offlineAsset == nil ? serverStart : nil
            )
        )
    }

    init(api: APIClient, request: PlaybackRequest) {
        self.api = api
        self.request = request
        self.session = Self.makeSession(api: api, request: request, takesWarm: true)
    }

    /// A session whose every item carries the title and episode line the system player shows above the video. The first one
    /// of a playback is the one Instant Start made ready for the title, when it did.
    private static func makeSession(api: APIClient, request: PlaybackRequest, takesWarm: Bool = false) -> PlaybackSession {
        let session = (takesWarm ? PlaybackWarmUp.shared.take(api: api, request: request) : nil) ?? PlaybackSession(api: api, request: request)
        let titles = titleMetadata(for: request.metadata)
        session.configureItem = { item in item.externalMetadata = titles }
        return session
    }

    private static func titleMetadata(for metadata: PlaybackMetadata?) -> [AVMetadataItem] {
        guard let metadata else { return [] }
        let line = metadata.showName.map { show in
            [show, Formatters.episodeCode(metadata.seasonNumber, metadata.episodeNumber)].compactMap { $0 }.joined(separator: " · ")
        }
        return [(AVMetadataIdentifier.commonIdentifierTitle, metadata.title), (.iTunesMetadataTrackSubTitle, line)].compactMap { identifier, value in
            guard let value, !value.isEmpty else { return nil }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item
        }
    }

    private static func offlineSource(from asset: OfflineAsset, resumeSecs: Double = 0) -> OfflinePlaybackSource {
        OfflinePlaybackSource(
            fileURL: asset.fileURL,
            markers: asset.markers,
            durationSecs: asset.durationSecs,
            resumeSecs: resumeSecs
        )
    }

    func present(from viewController: UIViewController) {
        guard !isPresenting else { return }
        if let docked = Self.docked(playing: request, near: viewController) {
            docked.session.expectPictureAgain()
            docked.expand()
            return
        }
        isPresenting = true
        presentingVC = viewController
        if let resolving = Self.resolvingCoordinator, resolving !== self {
            resolving.cancel()
        }
        MidgarLog.notice("Play requested ratingKey=\(request.ratingKey) type=\(request.mediaType) resumeSecs=\(Int(request.resumePosition))", category: .playback)
        session.askedAt = .now

        if request.offline != nil {
            MidgarLog.notice("Playing offline asset for ratingKey=\(request.ratingKey)", category: .playback)
            startPlayback(from: viewController)
            return
        }

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        spinner.alpha = 0
        viewController.view.addSubview(spinner)
        spinnerView = spinner
        UIView.animate(withDuration: 0.2, delay: Self.spinnerDelay) { spinner.alpha = 1 }
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
                MidgarLog.notice("Stream resolved directPlay=\(stream.isDirectPlay) subs=\(stream.subtitles.count) audio=\(stream.audioTracks.count)", category: .playback)
                startPlayback(from: viewController)
            } catch {
                spinnerView?.removeFromSuperview()
                isPresenting = false
                guard !Task.isCancelled else { return }
                MidgarLog.error("Stream resolve failed for ratingKey=\(request.ratingKey): \(error.localizedDescription)", category: .playback)
                let alert = UIAlertController(title: String(localized: "Playback Error"), message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
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
            MidgarLog.error("Presentation unavailable for ratingKey=\(request.ratingKey); abandoning playback", category: .playback)
            isPresenting = false
            session.discard()
            return
        }

        guard let player = session.begin() else {
            MidgarLog.error("Playback session unusable for ratingKey=\(request.ratingKey); abandoning playback", category: .playback)
            isPresenting = false
            return
        }
        if let other = Self.playingCoordinator, other !== self {
            other.session.player?.pause()
        }
        Self.playingCoordinator = self
        dock = MiniPlayerDock.of(viewController)
        dock?.adopt(self)

        let playerVC = makePlayerController(for: player)
        self.playerVC = playerVC
        installMoreButton(on: playerVC)
        installScrubPreview(on: playerVC)

        updateNowPlaying()
        windowScene = viewController.view.window?.windowScene
        setupForegroundObserver()
        observeSuspension()
        observeEvents()

        if let title = request.metadata?.title {
            windowScene?.title = title
        }
        viewController.present(playerVC, animated: true) {
            DemoTour.shared.record(.play)
            MidgarSignals.noteScreen("player", feature: true)
        }
    }

    /// The system player, with Picture in Picture and the speed menu. Now Playing is left to `NowPlayingBridge`: the system
    /// player would publish the item's own clock, which on a stream converted from a resume position starts at zero.
    private func makePlayerController(for player: AVPlayer) -> AVPlayerViewController {
        let playerVC = AVPlayerViewController()
        playerVC.player = player
        playerVC.updatesNowPlayingInfoCenter = false
        playerVC.allowsPictureInPicturePlayback = true
        playerVC.canStartPictureInPictureAutomaticallyFromInline = true
        playerVC.modalPresentationStyle = .fullScreen
        playerVC.speeds = AVPlaybackSpeed.systemDefaultSpeeds
        playerVC.delegate = self
        return playerVC
    }

    private func observeEvents() {
        eventsTask?.cancel()
        let events = session.events
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                handle(event)
            }
        }
    }

    private func updateNowPlaying() {
        nowPlaying?.clear()
        let bridge = NowPlayingBridge()
        nowPlaying = bridge
        guard let meta = request.metadata else { return }
        bridge.update(
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

    private func handle(_ event: PlaybackEvent) {
        guard !isAdvancing else { return }
        switch event {
        case .position(let absolute, let rate):
            nowPlaying?.updateElapsed(absolute, rate: rate)
            recordOfflineProgress(at: absolute)
            dock?.showPosition(of: self, at: absolute)
            scrubPreview?.stills?.playheadMoved(to: absolute)
        case .viewerActed:
            viewerActed()
            removePostPlay()
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
            if offer.reason == .requested { viewerActed() }
            presentUpNext(offer)
        case .failed(let message):
            showPlaybackError(message)
        case .pictureTrouble(let trouble):
            showPictureTrouble(trouble)
        case .finished(let finish):
            guard !isInPiP else { return }
            guard !isDocked else {
                close()
                return
            }
            offerWhatsNext(after: finish)
        case .sleepTimerFired:
            Haptics.soft()
            upNextOverlay?.setCountdownHeld(true)
            pendingUpNext = pendingUpNext?.withoutAutoplay()
            moreButton?.refreshMenu()
        case .tracksChanged:
            moreButton?.refreshMenu()
            followScrubStills()
        case .clockRemapped:
            break
        }
    }

    // MARK: - Player menu

    private func installMoreButton(on playerVC: AVPlayerViewController) {
        playerVC.loadViewIfNeeded()
        guard let host = playerVC.contentOverlayView else { return }
        let button = PlayerMoreButton { [weak self] in self?.playerMenu() ?? UIMenu() }
        button.install(in: host, listeningOn: playerVC.view)
        moreButton = button
    }

    private func setSleepTimer(_ choice: SleepTimerChoice?) {
        session.setSleepTimer(choice)
        upNextOverlay?.setCountdownHeld(session.stopsAtEndOfItem)
        moreButton?.refreshMenu()
    }

    private func playerMenu() -> UIMenu {
        var children: [UIMenuElement] = trackMenus() + [
            PlayerSleepMenu.menu(timer: session.sleepTimer, isEpisode: request.isEpisode) { [weak self] choice in
                self?.setSleepTimer(choice)
            },
        ]
        if let chapters = session.stream?.chapters, !chapters.isEmpty {
            let current = session.absolutePosition.flatMap { ChapterList.current(chapters, at: $0) }
            children.append(UIMenu(title: ChapterList.title, image: UIImage(systemName: "list.bullet.rectangle"), children: chapters.map { chapter in
                UIAction(title: ChapterList.menuTitle(chapter), state: chapter == current ? .on : .off) { [weak self] _ in
                    self?.viewerActed()
                    self?.session.seek(toAbsolute: chapter.startSecs)
                }
            }))
        }
        if session.stream != nil {
            children.append(UIAction(title: StreamInfo.title, image: UIImage(systemName: "info.circle")) { [weak self] _ in
                self?.showStreamInfo()
            })
        }
        return UIMenu(children: children)
    }

    /// Subtitles and Audio for the streams the server lists. Showing or hiding the subtitle already in the stream is instant;
    /// another language or audio track resolves the stream again at the playhead.
    private func trackMenus() -> [UIMenuElement] {
        guard let stream = session.stream else { return [] }
        var menus: [UIMenuElement] = []
        if !stream.subtitles.isEmpty {
            let options = PlaybackTrackMenu.subtitleOptions(stream.subtitles, selectedId: session.selectedSubtitleId)
            menus.append(PlayerTrackMenu.menu(title: String(localized: "Subtitles"), symbol: "captions.bubble", options: options) { [weak self] id in
                self?.selectStreams(subtitleId: id, audioId: self?.session.selectedAudioStreamId)
            })
        }
        if stream.audioTracks.count > 1 {
            let options = PlaybackTrackMenu.audioOptions(stream.audioTracks, selectedId: session.selectedAudioStreamId)
            menus.append(PlayerTrackMenu.menu(title: String(localized: "Audio"), symbol: "speaker.wave.2", options: options) { [weak self] id in
                self?.selectStreams(subtitleId: self?.session.selectedSubtitleId, audioId: id)
            })
        }
        return menus
    }

    private func selectStreams(subtitleId: Int?, audioId: Int?) {
        viewerActed()
        MidgarLog.notice("Switching streams ratingKey=\(request.ratingKey) audio=\(String(describing: audioId)) subtitle=\(String(describing: subtitleId))", category: .playback)
        let session = session
        Task { [weak self] in
            do {
                try await session.selectStreams(subtitleId: subtitleId, audioStreamId: audioId)
            } catch {
                guard !Task.isCancelled else { return }
                self?.showPlaybackError(error.localizedDescription)
            }
            self?.moreButton?.refreshMenu()
        }
    }

    private func showStreamInfo() {
        guard let stream = session.stream, let playerVC else { return }
        let lines = StreamInfo.lines(
            stream: stream,
            route: HomeServerRoute.classify(stream.url),
            quality: QualityPolicy.current(for: stream.url),
            audioId: session.selectedAudioStreamId,
            subtitleId: session.selectedSubtitleId
        )
        let message = lines.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        let alert = UIAlertController(title: StreamInfo.title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        playerVC.present(alert, animated: true)
    }

    private func recordOfflineProgress(at absolute: Double) {
        guard request.offline != nil, abs(absolute - lastOfflineWrite) >= 10 else { return }
        lastOfflineWrite = absolute
        DownloadManager.shared.recordOfflineProgress(
            ratingKey: request.ratingKey,
            positionSecs: absolute,
            finished: session.hasFinished(at: absolute)
        )
    }

    private func showPlaybackError(_ message: String) {
        let alert = UIAlertController(title: String(localized: "Playback Error"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        let host = isDocked ? dock?.presentationHost : (playerVC ?? presentingVC)
        host?.present(alert, animated: true)
    }

    /// The server's conversion has no picture in it, only a flat colour (`PictureTrouble`). Playback is left as it is: what
    /// fixes it is an action on the server, so the viewer is told that, once, instead of being shown a green screen in silence.
    /// The title also offered a way out: marking it incompatible leaves it out of the app on every device of the server.
    private func showPictureTrouble(_ trouble: PictureTrouble) {
        guard !isInPiP else { return }
        let alert = UIAlertController(title: trouble.title, message: trouble.explanation, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: IncompatibleCopy.hideThisTitle, style: .default) { [weak self] _ in
            self?.hideThisTitle()
        })
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        let host = isDocked ? dock?.presentationHost : (playerVC ?? presentingVC)
        host?.present(alert, animated: true)
    }

    /// Marks the title this playback was asked for, which takes it out of Home, search and the libraries everywhere.
    private func hideThisTitle() {
        Haptics.success()
        Task { [api, request] in
            await IncompatibleTitles.mark(
                ratingKey: request.ratingKey,
                title: request.metadata?.title ?? "",
                type: request.mediaType,
                thumb: request.metadata?.posterPath,
                sectionId: request.metadata?.librarySectionID,
                reason: .deadPicture,
                api: api
            )
        }
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
                MainActor.assumeIsolated {
                    self?.session.noteLifecycle("background")
                    self?.session.isInForeground = false
                    self?.suspendSession()
                }
            },
            center.addObserver(forName: UIScene.willEnterForegroundNotification, object: windowScene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.session.noteLifecycle("foreground")
                    self?.session.isInForeground = true
                    self?.session.recoverAfterSuspension()
                }
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
        MidgarLog.notice("Player window closed ratingKey=\(request.ratingKey)", category: .playback)
        isInPiP = false
        await dismissPlayer()
    }

    /// Saves at once, inside the notification, then reports inside a background task, so the system lets the
    /// report leave before it suspends the app.
    private func suspendSession() {
        let application = UIApplication.shared
        let task = application.beginBackgroundTask(withName: "playback-suspend")
        let report = session.suspendNow(pausing: false)
        let session = session
        Task {
            if let report { await session.reportSuspension(report) }
            if task != .invalid { application.endBackgroundTask(task) }
        }
    }

    private func showSkipToast(returningTo position: Double) {
        guard let host = playerVC?.contentOverlayView else { return }
        removeSkipToast(animated: false)
        let toast = SkipToastView(message: String(localized: "Skipped intro")) { [weak self] in
            Haptics.light()
            self?.viewerActed()
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
            self?.viewerActed()
            self?.skip(to: target)
        }
        pill.update(title: marker.title, accessibilityTitle: marker.title, progress: progress)
        shownSkip = (marker.title, target)
    }

    func skip(to target: Double) {
        removeSkipButton()
        session.seek(toAbsolute: target)
    }

    private func removeSkipButton() {
        skipPill?.dismiss(animated: true)
        skipPill = nil
        shownSkip = nil
    }

    private func presentUpNext(_ offer: UpNextOffer) {
        guard !isFinishing, !isAdvancing else { return }
        if let overlay = upNextOverlay {
            guard offer.playbackEnded else { return }
            overlay.markPlaybackEnded()
            shownUpNext = offer
            return
        }
        if isInPiP || UIApplication.shared.applicationState != .active {
            pendingUpNext = offer
            return
        }
        if startsInstantly(offer) {
            autoPlayNext(offer)
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
                autoplays: offer.autoplays,
                asksStillWatching: asksStillWatching,
                hasCredits: offer.reason == .credits
            ),
            countdownSeconds: upNextCountdown,
            onPlayNext: { [weak self] byViewer in
                if byViewer { self?.playNext(offer, byViewer: true) } else { self?.autoPlayNext(offer) }
            },
            onLeave: { [weak self] endsPlayback in
                guard let self else { return }
                self.viewerActed()
                if endsPlayback {
                    Task { await self.dismissPlayer() }
                } else {
                    self.removeUpNextOverlay()
                }
            }
        )
        overlay.present(in: host)
        upNextOverlay = overlay
        shownUpNext = offer
        session.setUpNextVisible(true)
        overlay.begin()
    }

    /// How long the Up Next card counts down for this show: its own choice, or Settings'.
    private var upNextCountdown: Int {
        ShowUpNextCountdown.effective(forShow: request.showRatingKey, server: ServerBootstrap.savedMachineIdentifier)
    }

    /// Whether the countdown is set to Instant and the card would count, so the next episode starts without it.
    private func startsInstantly(_ offer: UpNextOffer) -> Bool {
        upNextCountdown == 0 && offer.autoplays && !asksStillWatching && !session.stopsAtEndOfItem
    }

    func flushPendingUpNext() {
        guard let pending = pendingUpNext, !isFinishing, !isAdvancing else { return }
        pendingUpNext = nil
        if pending.playbackEnded, pending.autoplays {
            autoPlayNext(pending)
        } else {
            presentUpNext(pending)
        }
    }

    /// Whatever the viewer does while an episode plays ends a run of episodes nobody watched.
    func viewerActed() {
        viewerActedThisEpisode = true
    }

    /// Whether the Up Next card asks "Still watching?" instead of counting down: a run of episodes has
    /// started on its own with nobody touching the player.
    private var asksStillWatching: Bool {
        !viewerActedThisEpisode && StillWatchingRule.asks(unattended: unattendedEpisodes, limit: Preferences.stillWatchingAfter)
    }

    /// Plays the next episode without the viewer asking for it (the countdown ran out, or the item ended).
    /// Once the card must ask first it asks instead and nothing plays.
    private func autoPlayNext(_ offer: UpNextOffer) {
        guard session.isAtCreditsOrEnd else {
            MidgarLog.notice("Up Next countdown ended away from the credits ratingKey=\(request.ratingKey); staying on this episode", category: .playback)
            removeUpNextOverlay()
            return
        }
        guard asksStillWatching else {
            playNext(offer, byViewer: false)
            return
        }
        removeUpNextOverlay()
        presentUpNext(offer)
    }

    /// Starts the next episode in this player. One the viewer chose (or asked for with a next-track command)
    /// starts a new run of unattended episodes; one that started on its own adds to the run, unless the
    /// viewer touched this episode. The player stays on screen and swaps its item, so there is no dismissal
    /// in between, the screen underneath is not reloaded, and the subtitle and audio chosen on the episode
    /// before carry over.
    func playNext(_ offer: UpNextOffer, byViewer: Bool) {
        guard !isFinishing, !isAdvancing else { return }
        let startedByViewer = byViewer || offer.reason == .requested
        unattendedEpisodes = startedByViewer ? 0 : (viewerActedThisEpisode ? 0 : unattendedEpisodes) + 1
        viewerActedThisEpisode = startedByViewer
        removeUpNextOverlay()
        let offline = DownloadManager.shared.offlineAsset(for: offer.episode.id).map {
            Self.offlineSource(from: $0, resumeSecs: DownloadManager.shared.item(for: offer.episode.id)?.resumeSecs ?? 0)
        }
        let next = offer.nextRequest(
            showRatingKey: request.showRatingKey,
            offline: offline,
            trackLanguages: session.trackLanguages
        )
        advance(to: next, announcing: Self.indicatorTitle(for: offer))
    }

    /// Once nothing plays next, titles like the one that ended wait over its last frame. Without any, the last episode of a
    /// show closes the player as it always has, and a movie stays on its last frame.
    private func offerWhatsNext(after finish: PlaybackFinish) {
        guard postPlay == nil, postPlayTask == nil, !isFinishing, !isAdvancing else { return }
        let ended = request
        postPlayTask = Task { [weak self] in
            guard let self else { return }
            let suggestions = await PostPlay.suggestions(for: ended, api: api)
            guard !Task.isCancelled else { return }
            postPlayTask = nil
            guard !isFinishing, !isAdvancing, ended.ratingKey == request.ratingKey, !isInPiP else { return }
            if !suggestions.isEmpty, presentPostPlay(suggestions, after: ended) { return }
            if finish == .noNextEpisode { await dismissPlayer() }
        }
    }

    private func presentPostPlay(_ suggestions: [PlexMetadata], after ended: PlaybackRequest) -> Bool {
        guard let playerVC, playerVC.presentedViewController == nil, playerVC.viewIfLoaded?.window != nil else { return false }
        removeUpNextOverlay()
        removeSkipButton()
        removeSkipToast(animated: false)
        let origin = WatchCardOrigin(finished: ended)
        let screen = PostPlayViewController(
            heading: PostPlay.heading(for: ended),
            items: suggestions,
            onPick: { [weak self] item in self?.playSuggestion(item) },
            onShare: origin.map { origin in { [weak self] in self?.shareCard(origin) } },
            onClose: { [weak self] in self?.close() }
        )
        playerVC.present(screen, animated: !UIAccessibility.isReduceMotionEnabled)
        postPlay = screen
        MidgarLog.notice("Post-play offered \(suggestions.count) titles after ratingKey=\(ended.ratingKey)", category: .playback)
        return true
    }

    /// A movie plays in this player, as the next episode would; a show opens its screen once the player has closed.
    private func playSuggestion(_ item: PlexMetadata) {
        viewerActed()
        guard item.mediaType == "movie" else {
            let navigation = Self.navigation(under: presentingVC ?? dock?.tabBarController)
            let screen = DetailRouter.viewController(for: .related(item), api: api)
            Task {
                await dismissPlayer()
                navigation?.pushViewController(screen, animated: true)
            }
            return
        }
        removePostPlay()
        unattendedEpisodes = 0
        viewerActedThisEpisode = true
        let offline = DownloadManager.shared.offlineAsset(for: item.id).map {
            Self.offlineSource(from: $0, resumeSecs: DownloadManager.shared.item(for: item.id)?.resumeSecs ?? 0)
        }
        advance(to: PlaybackRequest(item: item, offline: offline), announcing: item.title)
    }

    /// Closes the player and, once it has gone, opens the card for what just ended over the screen it was opened from.
    private func shareCard(_ origin: WatchCardOrigin) {
        viewerActed()
        let host = presentingVC
        Task { [api] in
            await dismissPlayer()
            guard let host else { return }
            for _ in 0..<40 where host.presentedViewController != nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard host.presentedViewController == nil, host.view.window != nil else { return }
            WatchCardScreens.present(origin, api: api, from: host)
        }
    }

    /// The stack the player was opened from, where a title picked at the end of playback is pushed.
    private static func navigation(under presenter: UIViewController?) -> UINavigationController? {
        if let navigation = presenter as? UINavigationController { return navigation }
        if let navigation = presenter?.navigationController { return navigation }
        let tabBar = presenter as? TabBarController ?? presenter?.tabBarController as? TabBarController
        return tabBar?.currentNavigation
    }

    /// Takes the titles off the player, unless the player itself is going away and takes them along.
    private func removePostPlay(dismissing: Bool = true) {
        postPlayTask?.cancel()
        postPlayTask = nil
        if dismissing, let postPlay, postPlay.presentingViewController != nil {
            postPlay.dismiss(animated: false)
        }
        postPlay = nil
    }

    private func advance(to next: PlaybackRequest, announcing title: String) {
        guard !isFinishing, !isAdvancing else { return }
        isAdvancing = true
        removeSkipToast(animated: false)
        removeSkipButton()
        let previous = session
        previous.player?.pause()
        let indicator = showAdvanceIndicator(title: title)
        MidgarLog.notice("Advancing ratingKey=\(previous.request.ratingKey) -> \(next.ratingKey) byViewer=\(viewerActedThisEpisode)", category: .playback)

        advanceTask?.cancel()
        advanceTask = Task { [weak self] in
            guard let self else { return }
            let nextSession = Self.makeSession(api: api, request: next)
            do {
                _ = try await nextSession.prepare()
            } catch {
                guard !Task.isCancelled else {
                    nextSession.discard()
                    abandonAdvance()
                    return
                }
                MidgarLog.error("Next episode stream failed ratingKey=\(next.ratingKey): \(error.localizedDescription)", category: .playback)
                nextSession.discard()
                isAdvancing = false
                indicator?.hide()
                await dismissPlayer()
                return
            }
            guard !Task.isCancelled, !isFinishing, let player = nextSession.begin(autoplay: false) else {
                await nextSession.stop()
                abandonAdvance()
                return
            }
            await Self.waitUntilReady(player.currentItem)
            guard !Task.isCancelled, !isFinishing else {
                await nextSession.stop()
                abandonAdvance()
                return
            }
            attach(nextSession, player: player, request: next)
            indicator?.hide()
            advanceIndicator = nil
            nextSession.startWhenResumed()
            await previous.stop()
        }
    }

    /// Puts the new session on screen: its player replaces the old one in the same `AVPlayerViewController`,
    /// and everything that describes the item follows it.
    private func attach(_ next: PlaybackSession, player: AVPlayer, request: PlaybackRequest) {
        next.continueSleepTimer(from: session)
        self.request = request
        self.session = next
        if isDocked {
            dock?.follow(self, to: player)
        } else {
            playerVC?.player = player
        }
        updateNowPlaying()
        followScrubStills()
        isAdvancing = false
        observeEvents()
        if let title = request.metadata?.title {
            windowScene?.title = title
        }
        windowTabBar?.updateWindowTitle()
        Self.playingCoordinator = self
    }

    /// Waits for the new item to have a picture before it replaces the old one on screen, so the swap does
    /// not land on a black player. A slow or failed item is swapped anyway after the timeout and the
    /// session's own buffering and failure handling takes over.
    private static func waitUntilReady(_ item: AVPlayerItem?, timeout: Duration = .seconds(3)) async {
        guard let item else { return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while item.status == .unknown, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func showAdvanceIndicator(title: String) -> AdvanceIndicator? {
        guard let host = playerVC?.contentOverlayView else { return nil }
        advanceIndicator?.hide()
        let indicator = AdvanceIndicator()
        advanceIndicator = indicator
        indicator.show(in: host, title: title)
        return indicator
    }

    /// The episode about to play as the advance card names it: its code and title.
    private static func indicatorTitle(for offer: UpNextOffer) -> String {
        let code = Formatters.episodeCode(offer.episode.parentIndex, offer.episode.index)
        return [code, offer.episode.title].compactMap { $0 }.joined(separator: " · ")
    }

    /// Gives up on an advance that never reached the screen, so the player the viewer is still looking at
    /// keeps answering. A dismissal already under way owns the teardown and needs nothing from here.
    private func abandonAdvance() {
        guard !isFinishing else { return }
        isAdvancing = false
        advanceIndicator?.hide()
        advanceIndicator = nil
    }

    func dismissPlayer() async {
        guard !isFinishing else { return }
        isFinishing = true
        advanceTask?.cancel()
        advanceTask = nil
        let pvc = playerVC
        let wasDocked = isDocked
        await cleanup()
        guard !wasDocked else { return }
        (pvc?.presentingViewController ?? pvc)?.dismiss(animated: true)
    }

    private func removeUpNextOverlay() {
        upNextOverlay?.dismiss()
        upNextOverlay = nil
        shownUpNext = nil
        session.setUpNextVisible(false)
    }

    /// Ends playback once the full screen has gone without docking.
    func finishAfterDismissal() async {
        guard !isFinishing else { return }
        isFinishing = true
        removeUpNextOverlay()
        await cleanup()
    }

    private func cleanup() async {
        isDocked = false
        dock?.release(self)
        removeUpNextOverlay()
        removePostPlay(dismissing: false)
        skipPill?.dismiss(animated: false)
        skipPill = nil
        moreButton?.remove()
        moreButton = nil
        scrubPreview?.remove()
        scrubPreview = nil
        shownSkip = nil
        removeSkipToast(animated: false)
        advanceIndicator?.hide()
        advanceIndicator = nil
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
            DownloadManager.shared.recordOfflineProgress(
                ratingKey: request.ratingKey,
                positionSecs: finalPosition,
                finished: session.hasFinished(at: finalPosition),
                deleteIfWatched: true
            )
        }

        nowPlaying?.clear()
        nowPlaying = nil

        playerVC = nil
        isPresenting = false
        windowTabBar?.updateWindowTitle()
        if let finalPosition, session.hasFinished(at: finalPosition), !request.isExtra {
            PlaybackOffer.offerAfterFinishing(over: presentingVC)
        }
    }

    /// The main screen of the window this player plays in, whose title follows what it shows.
    private var windowTabBar: TabBarController? {
        dock?.tabBarController ?? presentingVC?.tabBarController as? TabBarController
    }
}

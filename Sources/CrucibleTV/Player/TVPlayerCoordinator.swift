import AVKit
import CrucibleCore
import CrucibleDesign
import CrucibleMedia
import UIKit

/// Plays one item, or a run of episodes, in the system `AVPlayerViewController` on top of a
/// `PlaybackSession`. The engine owns the stream, the resume rule, the timeline and the skip and
/// Up Next decisions; this class owns presentation: the pre-roll, the info panel, Skip Intro and
/// Skip Credits as contextual actions, Up Next as a content proposal, the track menus and the
/// error alerts. One playback is on screen at a time and the coordinator keeps itself alive until
/// it has torn that playback down.
@MainActor
final class TVPlayerCoordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
    private static var active: TVPlayerCoordinator?

    private static let stopGrace: Duration = .seconds(3)

    static func start(api: APIClient, request: PlaybackRequest, from presenter: UIViewController) {
        if let previous = active {
            Task { await previous.finish(animated: false) }
        }
        let coordinator = TVPlayerCoordinator(api: api, request: request)
        active = coordinator
        coordinator.present(from: presenter)
    }

    /// Ends the playback on screen, if any, and waits until its session has stopped and it is off
    /// screen, so a caller that is about to show something else never leaves a session running.
    static func endActive() async {
        guard let active else { return }
        await active.finish(animated: false)
    }

    let api: APIClient
    var request: PlaybackRequest
    var session: PlaybackSession?
    let playerVC = AVPlayerViewController()
    var preroll: TVPlayerPrerollViewController?
    weak var rootPresenter: UIViewController?
    var eventsTask: Task<Void, Never>?
    var prepareTask: Task<Void, Never>?
    var metadataTask: Task<Void, Never>?
    var upNextTask: Task<Void, Never>?
    var stopTask: Task<Void, Never>?
    var lifecycleObservers: [any NSObjectProtocol] = []
    var infoItems: [AVMetadataItem] = []
    var upNextOffer: UpNextOffer?
    var upNextPreview: UIImage?
    var upNextCard: TVUpNextViewController?
    var shownMarker: SkipMarker?
    var isFinishing = false
    var isAdvancing = false
    var isShowingAlert = false
    var isRevealing = false
    var isUpNextCardVisible = false
    var pendingFailure: (message: String, retry: @MainActor () -> Void)?

    private init(api: APIClient, request: PlaybackRequest) {
        self.api = api
        self.request = request
        super.init()
    }

    private func present(from presenter: UIViewController) {
        configurePlayerController()
        observeLifecycle()
        var top = presenter
        while let presented = top.presentedViewController { top = presented }
        rootPresenter = top
        startSession()
    }

    private func configurePlayerController() {
        playerVC.delegate = self
        playerVC.modalPresentationStyle = .fullScreen
        playerVC.appliesPreferredDisplayCriteriaAutomatically = true
        playerVC.speeds = AVPlaybackSpeed.systemDefaultSpeeds
        playerVC.view.accessibilityIdentifier = "player.view"
    }

    /// Starts a fresh session for `request` behind the pre-roll.
    func startSession() {
        AppLogger.notice("Play requested ratingKey=\(request.ratingKey) type=\(request.mediaType) resumeSecs=\(Int(request.resumePosition))", .playback)
        isAdvancing = false
        let session = PlaybackSession(api: api, request: request, installsRemoteCommands: false)
        session.configureItem = { [weak self] item in self?.configure(item: item) }
        self.session = session
        if preroll?.presentingViewController == nil { showPreroll() }
        loadInfo()
        prepareTask = Task { [weak self] in
            do {
                #if DEBUG
                try await self?.prepareForUITests()
                #endif
                _ = try await session.prepare()
            } catch {
                guard !Task.isCancelled else { return }
                self?.presentFailure(error.localizedDescription, retry: { self?.startSession() })
                return
            }
            self?.attach(session)
        }
    }

    #if DEBUG
    private static var failedResolves: Set<String> = []

    /// UI tests keep the pre-roll up by naming a number of seconds in `CRUCIBLE_PLAYER_HOLD`, and make
    /// the first resolve of the item named by `CRUCIBLE_PLAYER_FAIL_RESOLVE_ONCE` fail, so Retry runs
    /// the same path as after a real server error without racing the app's other metadata requests.
    private func prepareForUITests() async throws {
        let environment = ProcessInfo.processInfo.environment
        if let text = environment["CRUCIBLE_PLAYER_HOLD"], let seconds = Double(text) {
            try? await Task.sleep(for: .seconds(seconds))
        }
        let key = request.ratingKey
        guard environment["CRUCIBLE_PLAYER_FAIL_RESOLVE_ONCE"] == key, Self.failedResolves.insert(key).inserted else { return }
        throw URLError(.cannotConnectToHost)
    }
    #endif

    /// Puts the pre-roll on screen: over the presenting screen for the first start, over the
    /// player when the next episode or a retry starts inside an open player.
    private func showPreroll() {
        let headline = TVPlayerMetadata.headline(for: request.metadata)
        let preroll = TVPlayerPrerollViewController(title: headline.title, subtitle: headline.subtitle)
        preroll.onClose = { [weak self] in
            Task { await self?.finish(animated: true) }
        }
        self.preroll = preroll
        if playerVC.presentingViewController != nil {
            topmost(from: playerVC).present(preroll, animated: false)
        } else if let rootPresenter {
            rootPresenter.present(preroll, animated: true)
        }
    }

    private func playerRevealed() {
        isRevealing = false
        guard let pending = pendingFailure else { return }
        pendingFailure = nil
        presentFailure(pending.message, retry: pending.retry)
    }

    func topmost(from controller: UIViewController) -> UIViewController {
        var top = controller
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    /// Replaces the pre-roll with the player: the first time the player takes the pre-roll's place
    /// in the presentation, afterwards the pre-roll just fades away over the open player.
    private func revealPlayer() {
        guard let preroll else { return }
        self.preroll = nil
        if playerVC.presentingViewController == nil, let host = preroll.presentingViewController {
            preroll.suppressCloseReport()
            isRevealing = true
            host.dismiss(animated: false) { [weak self, playerVC] in
                guard let self, !isFinishing else { return }
                host.present(playerVC, animated: false) { [weak self] in
                    self?.playerRevealed()
                }
            }
        } else {
            preroll.close(animated: true)
        }
    }

    private func attach(_ session: PlaybackSession) {
        guard !isFinishing, session === self.session else {
            session.discard()
            return
        }
        guard let player = session.begin() else {
            presentFailure("Playback could not start.", retry: { [weak self] in self?.startSession() })
            return
        }
        player.preventsDisplaySleepDuringVideoPlayback = true
        playerVC.player = player
        revealPlayer()
        observeEvents(of: session)
        refreshTrackMenus()
        prepareUpNext(for: session)
    }

    private func observeEvents(of session: PlaybackSession) {
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
        case .position:
            break
        case .skipAvailable(let marker, _):
            showSkip(marker)
        case .skipHidden, .autoSkipUndoExpired:
            clearContextualActions()
        case .autoSkipped(_, let returnTo):
            showUndo(returningTo: returnTo)
        case .upNext(let offer):
            handle(offer)
        case .failed(let message):
            presentFailure(message, retry: { [weak self] in self?.retryFromPlayhead() })
        case .finished:
            Task { await finish(animated: true) }
        }
    }

    private func showSkip(_ marker: SkipMarker) {
        guard shownMarker != marker else { return }
        shownMarker = marker
        playerVC.contextualActions = [
            UIAction(title: marker.title, image: UIImage(systemName: "forward.fill")) { [weak self] _ in
                self?.skip(marker)
            },
        ]
    }

    private func skip(_ marker: SkipMarker) {
        clearContextualActions()
        session?.seek(toAbsolute: marker.endSecs)
    }

    private func showUndo(returningTo position: Double) {
        shownMarker = nil
        playerVC.contextualActions = [
            UIAction(title: "Undo Skip", image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
                self?.clearContextualActions()
                self?.session?.undoAutoSkip(returnTo: position)
            },
        ]
    }

    func clearContextualActions() {
        shownMarker = nil
        guard !playerVC.contextualActions.isEmpty else { return }
        playerVC.contextualActions = []
    }

    /// Alerts with Retry and Close; Menu closes. One alert at a time.
    func presentFailure(_ message: String, retry: @escaping @MainActor () -> Void) {
        guard !isShowingAlert, !isFinishing else { return }
        guard !isRevealing else {
            pendingFailure = (message, retry)
            return
        }
        isShowingAlert = true
        let alert = UIAlertController(title: "Playback Error", message: "This video couldn't be played.\n\(message)", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            self?.isShowingAlert = false
            retry()
        })
        alert.addAction(UIAlertAction(title: "Close", style: .cancel) { [weak self] _ in
            self?.isShowingAlert = false
            Task { await self?.finish(animated: true) }
        })
        topmost(from: rootPresenter ?? playerVC).present(alert, animated: true)
    }

    private func retryFromPlayhead() {
        let position = session?.absolutePosition ?? request.resumePosition
        if let session {
            request = request.resuming(
                at: position,
                selectedSubtitleId: .some(session.selectedSubtitleId),
                selectedAudioStreamId: .some(session.selectedAudioStreamId)
            )
        } else {
            request = request.resuming(at: position)
        }
        restartSession()
    }

    /// Ends the current session without leaving the player and starts `request` in its place.
    func restartSession() {
        let old = session
        resetPresentationState()
        let stop = Task { _ = await old?.stop() }
        stopTask = stop
        prepareTask = Task { [weak self] in
            await stop.value
            guard let self, !isFinishing, !Task.isCancelled else { return }
            startSession()
        }
    }

    func advance(to offer: UpNextOffer) {
        guard !isAdvancing, !isFinishing else { return }
        isAdvancing = true
        isUpNextCardVisible = false
        request = offer.nextRequest(showRatingKey: request.showRatingKey)
        restartSession()
    }

    private func resetPresentationState() {
        eventsTask?.cancel()
        prepareTask?.cancel()
        metadataTask?.cancel()
        upNextTask?.cancel()
        clearContextualActions()
        playerVC.transportBarCustomMenuItems = []
        playerVC.player = nil
        infoItems = []
        upNextOffer = nil
        upNextPreview = nil
        upNextCard = nil
        isUpNextCardVisible = false
    }

    /// Pauses at once, stops the engine (final timeline report, transcode, cache invalidation) and, if
    /// this is still the playback on screen, dismisses it so the screen underneath reloads fresh
    /// watched state. A slow or unreachable server cannot hold the viewer on a black screen: the
    /// wait for the stop is bounded and the stop finishes in the background. Then the Top Shelf is
    /// refreshed so Continue Watching reflects what was just played.
    func finish(animated: Bool) async {
        guard !isFinishing else { return }
        isFinishing = true
        AppLogger.notice("Playback finishing ratingKey=\(request.ratingKey) animated=\(animated)", .playback)
        session?.player?.pause()
        stopObservingLifecycle()
        let session = self.session
        let earlier = stopTask
        resetPresentationState()
        let stop = Task {
            await earlier?.value
            _ = await session?.stop()
        }
        stopTask = stop
        await waitForStop(stop)
        if Self.active === self {
            dismissEverything(animated: animated)
            Self.active = nil
        }
        TVTopShelfRefresher.refresh()
    }

    private func waitForStop(_ stop: Task<Void, Never>) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = ResumeGate(continuation)
            Task { await stop.value; gate.resume() }
            Task { try? await Task.sleep(for: Self.stopGrace); gate.resume() }
        }
    }

    /// Takes the pre-roll and the player off screen, back to the screen that started playback.
    private func dismissEverything(animated: Bool) {
        preroll?.suppressCloseReport()
        preroll = nil
        guard let root = rootPresenter, root.presentedViewController != nil else { return }
        root.dismiss(animated: animated)
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.session?.suspend() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.session?.recoverAfterSuspension() }
            },
        ]
    }

    private func stopObservingLifecycle() {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers.removeAll()
    }

    func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
        AppLogger.notice("Player asked to dismiss (finishing=\(isFinishing))", .playback)
        if isFinishing { return true }
        Task { await finish(animated: true) }
        return false
    }
}

/// Resumes a continuation exactly once, whichever of two racing tasks gets there first.
@MainActor
private final class ResumeGate {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

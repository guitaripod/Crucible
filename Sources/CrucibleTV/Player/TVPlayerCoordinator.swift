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

    static func start(api: APIClient, request: PlaybackRequest, from presenter: UIViewController) {
        if let previous = active {
            Task { await previous.finish(dismiss: false) }
        }
        let coordinator = TVPlayerCoordinator(api: api, request: request)
        active = coordinator
        coordinator.present(from: presenter)
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
    var infoItems: [AVMetadataItem] = []
    var upNextOffer: UpNextOffer?
    var upNextPreview: UIImage?
    var shownMarker: SkipMarker?
    var isFinishing = false
    var isAdvancing = false
    var isShowingAlert = false
    var isRevealing = false
    var pendingFailure: (message: String, retry: @MainActor () -> Void)?

    private init(api: APIClient, request: PlaybackRequest) {
        self.api = api
        self.request = request
        super.init()
    }

    private func present(from presenter: UIViewController) {
        configurePlayerController()
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
        let session = PlaybackSession(api: api, request: request)
        session.configureItem = { [weak self] item in self?.configure(item: item) }
        self.session = session
        showPreroll()
        loadInfo()
        prepareTask = Task { [weak self] in
            #if DEBUG
            await Self.holdForUITests()
            #endif
            do {
                _ = try await session.prepare()
            } catch {
                guard !Task.isCancelled else { return }
                self?.presentFailure(error.localizedDescription, retry: { self?.startSession() })
                return
            }
            self?.attach(session)
        }
    }

    /// Puts the pre-roll on screen: over the presenting screen for the first start, over the
    /// player when the next episode or a retry starts inside an open player.
    #if DEBUG
    /// UI tests keep the pre-roll up by naming a number of seconds in `CRUCIBLE_PLAYER_HOLD`.
    private static func holdForUITests() async {
        guard let text = ProcessInfo.processInfo.environment["CRUCIBLE_PLAYER_HOLD"], let seconds = Double(text) else { return }
        try? await Task.sleep(for: .seconds(seconds))
    }
    #endif

    private func showPreroll() {
        let headline = TVPlayerMetadata.headline(for: request.metadata)
        let preroll = TVPlayerPrerollViewController(title: headline.title, subtitle: headline.subtitle)
        preroll.onClose = { [weak self] in
            Task { await self?.finish(dismiss: true) }
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
            host.dismiss(animated: false) { [playerVC] in
                host.present(playerVC, animated: false) { [weak self] in
                    self?.playerRevealed()
                }
            }
        } else {
            preroll.close(animated: true)
        }
    }

    private func attach(_ session: PlaybackSession) {
        guard !isFinishing, session === self.session else { return }
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
            if offer.reason == .requested { advance(to: offer) }
        case .failed(let message):
            presentFailure(message, retry: { [weak self] in self?.retryFromPlayhead() })
        case .finished:
            Task { await finish(dismiss: true) }
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
            Task { await self?.finish(dismiss: true) }
        })
        topmost(from: rootPresenter ?? playerVC).present(alert, animated: true)
    }

    private func retryFromPlayhead() {
        let position = session?.absolutePosition ?? request.resumePosition
        request = request.resuming(at: position)
        restartSession()
    }

    /// Ends the current session without leaving the player and starts `request` in its place.
    func restartSession() {
        let old = session
        resetPresentationState()
        prepareTask = Task { [weak self] in
            await old?.stop()
            self?.startSession()
        }
    }

    func advance(to offer: UpNextOffer) {
        guard !isAdvancing, !isFinishing else { return }
        isAdvancing = true
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
    }

    /// Stops the engine (final timeline report, transcode, cache invalidation) and, unless the
    /// system is already dismissing the player, dismisses it once that has finished so the screen
    /// underneath reloads fresh watched state.
    func finish(dismiss: Bool) async {
        guard !isFinishing else { return }
        isFinishing = true
        AppLogger.notice("Playback finishing ratingKey=\(request.ratingKey) dismiss=\(dismiss)", .playback)
        let session = self.session
        resetPresentationState()
        await session?.stop()
        dismissEverything(animated: dismiss)
        if Self.active === self { Self.active = nil }
    }

    /// Takes the pre-roll and the player off screen, back to the screen that started playback.
    private func dismissEverything(animated: Bool) {
        preroll?.suppressCloseReport()
        preroll = nil
        guard let root = rootPresenter, root.presentedViewController != nil else { return }
        root.dismiss(animated: animated)
    }

    func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
        AppLogger.notice("Player asked to dismiss (finishing=\(isFinishing))", .playback)
        if isFinishing { return true }
        Task { await finish(dismiss: true) }
        return false
    }
}

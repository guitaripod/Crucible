import AVKit
import CrucibleCore
import CrucibleDesign
import CrucibleMedia
import MidgarCore
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

    /// How long after the end of an item the system's Up Next card may still come before the engine's
    /// own answer (play the next episode, or close) takes over; a slow Apple TV can need more than a second.
    static let upNextCardGrace: Duration = .seconds(3)

    /// How long the pre-roll waits for the stream to load before the player shows its own buffering.
    private static let revealTimeout: Duration = .seconds(10)

    static func start(api: APIClient, request: PlaybackRequest, from presenter: UIViewController) {
        if let previous = active {
            Task { await previous.finish(animated: false) }
        }
        let coordinator = TVPlayerCoordinator(api: api, request: request)
        active = coordinator
        coordinator.present(from: presenter)
    }

    /// Called on the main actor when a playback has been taken off screen, with whether the viewer finished at least one item
    /// in it. The app uses it to pick its moment for a Crucible Pro note.
    static var onEnded: (@MainActor (_ finishedAnItem: Bool) -> Void)?

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
    var revealTask: Task<Void, Never>?
    var upNextTask: Task<Void, Never>?
    var stopTask: Task<Void, Never>?
    var lifecycleObservers: [any NSObjectProtocol] = []
    var infoItems: [AVMetadataItem] = []
    var upNextOffer: UpNextOffer?
    var upNextPreview: UIImage?
    var upNextCard: TVUpNextViewController?
    var shownMarker: SkipMarker?
    var isFinishing = false
    var finishedAnItem = false
    var isAdvancing = false
    var isShowingAlert = false
    var isRevealing = false
    var isUpNextCardVisible = false
    var unattendedEpisodes = 0
    var viewerActedThisEpisode = true
    #if DEBUG
    var didSimulateSleep = false
    #endif
    var pendingFailure: (message: String, retry: @MainActor () -> Void)?

    private init(api: APIClient, request: PlaybackRequest) {
        self.api = api
        self.request = request
        super.init()
    }

    private func present(from presenter: UIViewController) {
        configurePlayerController()
        observeLifecycle()
        #if DEBUG
        presetUnattendedRunForUITests()
        #endif
        var top = presenter
        while let presented = top.presentedViewController { top = presented }
        rootPresenter = top
        startSession()
    }

    private func configurePlayerController() {
        playerVC.delegate = self
        playerVC.modalPresentationStyle = .fullScreen
        playerVC.modalTransitionStyle = .crossDissolve
        playerVC.appliesPreferredDisplayCriteriaAutomatically = true
        playerVC.speeds = AVPlaybackSpeed.systemDefaultSpeeds
        playerVC.view.accessibilityIdentifier = "player.view"
        installHoldGestures()
    }

    /// Starts a fresh session for `request` behind the pre-roll.
    func startSession() {
        MidgarLog.notice("Play requested ratingKey=\(request.ratingKey) type=\(request.mediaType) resumeSecs=\(Int(request.resumePosition))", category: .playback)
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
        let preroll = TVPlayerPrerollViewController(
            title: headline.title,
            subtitle: headline.subtitle,
            posterPath: request.metadata?.posterPath
        )
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

    /// Dissolves from the pre-roll into the player: the first time the player is presented over the
    /// pre-roll, which stays black underneath, afterwards the pre-roll just fades away over the open
    /// player. There is never a moment with neither on screen.
    private func revealPlayer() {
        guard let preroll else { return }
        self.preroll = nil
        if playerVC.presentingViewController == nil, preroll.presentingViewController != nil {
            preroll.suppressCloseReport()
            isRevealing = true
            preroll.present(playerVC, animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] in
                self?.playerRevealed()
            }
        } else {
            preroll.close(animated: true)
        }
    }

    /// Holds the pre-roll until the stream has loaded enough to show a picture, so the dissolve lands
    /// on video instead of a black player that is still buffering. A failed or slow load reveals the
    /// player anyway, where the engine's own failure or buffering handling takes over.
    private func revealWhenLoaded(_ session: PlaybackSession, item: AVPlayerItem?) {
        revealTask?.cancel()
        revealTask = Task { [weak self] in
            if let item { await Self.waitForLoad(of: item) }
            await self?.preroll?.waitUntilShown()
            guard let self, !Task.isCancelled, !isFinishing, session === self.session, item?.status != .failed else { return }
            revealPlayer()
        }
    }

    private static func waitForLoad(of item: AVPlayerItem) async {
        guard item.status == .unknown else { return }
        var observation: NSKeyValueObservation?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = ResumeGate(continuation)
            observation = item.observe(\.status, options: [.new]) { @Sendable observed, _ in
                guard observed.status != .unknown else { return }
                Task { @MainActor in gate.resume() }
            }
            Task {
                try? await Task.sleep(for: revealTimeout)
                gate.resume()
            }
        }
        observation?.invalidate()
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
        DemoTour.shared.record(.play)
        revealWhenLoaded(session, item: player.currentItem)
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
        case .position(let absolute, _):
            #if DEBUG
            simulateSleepForUITestsIfDue(at: absolute)
            #else
            _ = absolute
            #endif
        case .viewerActed:
            viewerActed()
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
            finishedAnItem = true
            Task { await finish(animated: true) }
        }
    }

    private func showSkip(_ marker: SkipMarker) {
        guard shownMarker != marker else { return }
        shownMarker = marker
        playerVC.contextualActions = [
            UIAction(title: marker.title, image: UIImage(systemName: "forward.fill")) { [weak self] _ in
                self?.viewerActed()
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
                self?.viewerActed()
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

    /// Starts the next episode. One the viewer chose starts a new run; one that started on its own adds to
    /// the run of episodes nobody has touched the remote in, which is what "Still watching?" counts. The
    /// subtitle and audio chosen on the episode before carry over.
    func advance(to offer: UpNextOffer, byViewer: Bool = false) {
        guard !isAdvancing, !isFinishing else { return }
        unattendedEpisodes = byViewer ? 0 : (viewerActedThisEpisode ? 0 : unattendedEpisodes) + 1
        viewerActedThisEpisode = byViewer
        finishedAnItem = true
        isAdvancing = true
        isUpNextCardVisible = false
        request = offer.nextRequest(
            showRatingKey: request.showRatingKey,
            selectedSubtitleId: session?.selectedSubtitleId,
            selectedAudioStreamId: session?.selectedAudioStreamId
        )
        restartSession()
    }

    private func resetPresentationState() {
        eventsTask?.cancel()
        prepareTask?.cancel()
        metadataTask?.cancel()
        revealTask?.cancel()
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
        MidgarLog.notice("Playback finishing ratingKey=\(request.ratingKey) animated=\(animated)", category: .playback)
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
            Self.active = nil
            let finishedAnItem = finishedAnItem
            dismissEverything(animated: animated) { Self.onEnded?(finishedAnItem) }
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
    private func dismissEverything(animated: Bool, completion: @escaping @MainActor () -> Void) {
        preroll?.suppressCloseReport()
        preroll = nil
        guard let root = rootPresenter, root.presentedViewController != nil else {
            completion()
            return
        }
        root.dismiss(animated: animated) { completion() }
    }

    /// The snapshot of the viewer's position is taken when the app resigns active, while the player's
    /// clock is still right; going to the background pauses and reports it, coming back puts the player
    /// where the snapshot says. Each handler runs at once, inside the notification, because the system can
    /// suspend the app as soon as it returns; work deferred to a task may not run until the app is back.
    /// An absence no notification announces (an Apple TV that sleeps from its screen saver) is the session
    /// heartbeat's to notice.
    private func observeLifecycle() {
        lifecycleObservers = [
            observe(UIApplication.willResignActiveNotification) { coordinator in
                coordinator.session?.noteLifecycle("resignActive")
                coordinator.session?.holdPosition()
            },
            observe(UIApplication.didBecomeActiveNotification) { coordinator in
                coordinator.session?.noteLifecycle("becomeActive")
                coordinator.session?.isInForeground = true
                coordinator.session?.releasePositionIfForeground()
            },
            observe(UIApplication.didEnterBackgroundNotification) { coordinator in
                coordinator.session?.noteLifecycle("background")
                coordinator.session?.isInForeground = false
                coordinator.suspendSession()
            },
            observe(UIApplication.willEnterForegroundNotification) { coordinator in
                coordinator.session?.noteLifecycle("foreground")
                coordinator.session?.isInForeground = true
                coordinator.session?.recoverAfterSuspension()
            },
        ]
    }

    private func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (TVPlayerCoordinator) -> Void) -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
    }

    /// Pauses and saves at once, then reports inside a background task, so the system lets the report leave
    /// before it suspends the app.
    private func suspendSession() {
        guard let session else { return }
        let application = UIApplication.shared
        let task = application.beginBackgroundTask(withName: "playback-suspend")
        let report = session.suspendNow()
        #if DEBUG
        resetPlayerClockForUITests()
        #endif
        Task {
            if let report { await session.reportSuspension(report) }
            if task != .invalid { application.endBackgroundTask(task) }
        }
    }

    /// Whatever the viewer does with the remote while an episode plays: it ends a run of unattended episodes.
    func viewerActed() {
        viewerActedThisEpisode = true
    }

    /// Whether the Up Next card asks "Still watching?" instead of counting down.
    var asksStillWatching: Bool {
        !viewerActedThisEpisode && StillWatchingRule.asks(unattended: unattendedEpisodes, limit: Preferences.stillWatchingAfter)
    }

    #if DEBUG
    /// `CRUCIBLE_PLAYER_CLOCK_RESET=1` rewinds the player's own clock to zero right after the app has gone to the
    /// background, the way a player that lost its place while the Apple TV slept reads: zero seconds into its stream.
    private func resetPlayerClockForUITests() {
        guard ProcessInfo.processInfo.environment["CRUCIBLE_PLAYER_CLOCK_RESET"] == "1" else { return }
        MidgarLog.notice("Debug: resetting the player clock to zero", category: .playback)
        session?.player?.seek(to: .zero)
    }
    #endif

    #if DEBUG
    /// `CRUCIBLE_PLAYER_UNATTENDED=<n>` starts the player as if `n` episodes had already played on their own with nobody at the
    /// remote, so a test reaches "Still watching?" without sitting through them.
    private func presetUnattendedRunForUITests() {
        guard let count = ProcessInfo.processInfo.environment["CRUCIBLE_PLAYER_UNATTENDED"].flatMap(Int.init) else { return }
        unattendedEpisodes = count
        viewerActedThisEpisode = false
    }

    /// `CRUCIBLE_PLAYER_SLEEP_AT=<seconds>` with `CRUCIBLE_PLAYER_SLEEP_FOR=<seconds>` acts out an Apple TV that falls asleep without
    /// telling the app: once the playhead passes SLEEP_AT the player pauses, the mock drops the transcode session (`/mock/reap`), and
    /// the session's clock jumps SLEEP_FOR seconds ahead, as it reads after a night asleep. No lifecycle notification is sent.
    private func simulateSleepForUITestsIfDue(at absolute: Double) {
        let environment = ProcessInfo.processInfo.environment
        guard !didSimulateSleep,
              let sleepAt = environment["CRUCIBLE_PLAYER_SLEEP_AT"].flatMap(Double.init), absolute >= sleepAt,
              let length = environment["CRUCIBLE_PLAYER_SLEEP_FOR"].flatMap(Double.init),
              let session else { return }
        didSimulateSleep = true
        MidgarLog.notice("Debug: simulating \(Int(length)) s asleep without lifecycle notifications", category: .playback)
        session.player?.pause()
        let reap = environment["CRUCIBLE_MOCK"].flatMap { mock in
            session.stream.flatMap { URL(string: "\(mock)/mock/reap?session=\($0.sessionId)") }
        }
        Task {
            if let reap { _ = try? await URLSession.shared.data(from: reap) }
            session.debugAdvanceClock(by: .seconds(length))
        }
    }
    #endif

    private func stopObservingLifecycle() {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers.removeAll()
    }

    func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
        MidgarLog.notice("Player asked to dismiss (finishing=\(isFinishing))", category: .playback)
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

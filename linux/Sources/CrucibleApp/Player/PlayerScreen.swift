import CrucibleCore
import CrucibleUI
import CrucibleWeb
import Foundation
import Kiln
import MidgarCore

/// The player (§7.5): the pre-roll until the picture shows, then the picture full window, a Liquid Glass transport that
/// floats in on the pointer or a key and away after three seconds of playing, Skip Intro and Skip Credits (and Undo Skip
/// after an automatic one) over the picture, the info panel, Up Next with "Still watching?", what's next at the end, a
/// sleep timer, and the server told where the playhead is every ten seconds and whenever it stops or pauses.
///
/// Keys: Space or K play and pause, Left and Right or J and L the skip distances (held: what Settings say) and with Shift a
/// precise second, 0 to 9 a tenth of the title, comma and period a frame, Home starts over, Page Up and Page Down move by
/// chapter, [ and ] change the speed and Backspace resets it (with Shift, Go Back), Up and Down volume, M mute, S skip
/// (with Shift, a screenshot; Ctrl+C copies the picture), I the info panel, A and C audio and subtitles, V subtitles on
/// and off, Z and X subtitle sync, minus and equals sound sync, Shift+L the A-B loop, T the sleep timer, N the next
/// episode, F full screen, the Menu key or a right click the player's menu,
/// Escape leaves full screen, then goes back. A click plays and pauses, a double click fills the screen, the wheel moves
/// through the title.
@MainActor
final class PlayerScreen: View {
    /// What plays: a title on the Plex server from a position, a video from the web (`PlayerScreen+Web`), or a local file
    /// (headless checks of the player itself).
    enum Source {
        case plex(APIClient, PlexMetadata, resume: Double)
        case web(WebPlayback)
        case file(URL, title: String)
        case live(LiveSession)
    }

    var onClose: (() -> Void)?
    /// The audio and subtitle streams a title page picked; nil plays the languages the run or the show carries, else what the
    /// server and the viewer's settings choose.
    var chosenTracks: (audio: Int?, subtitle: Int?)?
    /// What this sitting carries from the title before.
    var run = PlayerRun()
    /// Plays the next episode in place of this one (Up Next, the media keys' Next), with the run it continues.
    var onPlayNext: ((PlexMetadata, PlayerRun) -> Void)?
    /// Plays a movie picked at the end in place of this one.
    var onPlayTitle: ((PlexMetadata, PlayerRun) -> Void)?
    /// Opens the page of a show picked at the end, once the player has closed.
    var onOpenTitle: ((PlexMetadata) -> Void)?
    /// Plays the next web video of a queue in place of this one.
    var onPlayWeb: ((WebPlayback, PlayerRun) -> Void)?
    /// The web side of the player while a web video plays.
    var web: WebSession?
    /// The live TV side of the player while a channel plays.
    var live: LiveSession?
    /// The viewer asked for the mini player (P, its button, the menu) or for the full player back from it.
    var onMinimize: (() -> Void)?
    var onExpand: (() -> Void)?
    /// The mini player was dragged by `delta` (window points), or let go (nil), when it settles in the nearest corner.
    var onMiniDrag: ((Point?) -> Void)?
    /// The player plays on in a corner of the window while the viewer browses (`RootView.minimizePlayer`).
    var isMini = false {
        didSet {
            guard isMini != oldValue else { return }
            miniHover.reset(0)
            miniZone = nil
            if isMini {
                contextMenu?.dismiss()
                holdChrome()
                window?.setCursor(.default)
            }
            followFullscreen()
            pacePlayheadReports()
            setNeedsLayout()
            setNeedsDisplay()
        }
    }
    var miniHover = Animated(0)
    /// Refreshes Stream Info's live lines while the info panel is open, with the last minute of bitrate samples and the
    /// server's side of a conversion.
    var infoTicker: Task<Void, Never>?
    var bitrateHistory: [Double] = []
    var serverTranscode: PlexTranscodeSession?
    var miniZone: MiniZone?
    var miniPress: (zone: MiniZone?, start: Point, dragged: Bool)?

    let source: Source
    /// The player on screen, so quitting the app can stop it before its window and GPU go away.
    static weak var active: PlayerScreen?
    /// The stopped report of the last player that closed, until the server has it: quitting waits for it, so the
    /// position the viewer stopped at is the one the server resumes from.
    static var pendingStop: Task<Void, Never>?

    var upNext: UpNextResolver?
    /// What Up Next found after this title, once it asked: the next episode, or that there is nothing next.
    var nextKnown: NextKnown?
    var card: UpNextCard?
    var offerTask: Task<Void, Never>?
    var player: VideoPlayer?
    var videoView: VideoView?
    let transport = TransportView()
    let skip = ButtonView(style: .glass, title: nil, symbol: "forward.end.fill", symbolTrailing: true)
    var preroll: PrerollView?
    /// When the player opened and how ready Instant Start had its title, for the line that says how long the picture took.
    var askedAt: ContinuousClock.Instant?
    var startedFrom = WarmDepth.none
    /// What Instant Start made ready for this title, until the first stream is loaded (`takeWarmPlayer`).
    var warm: StreamWarmUp.Ready?
    var infoPanel: PlayerInfoPanel?
    var postPlay: PostPlayView?
    var stream: ResolvedStream?
    var stills: ScrubStillLoader?
    /// The codecs mpv passes through to the receiver, from the sound output as it was checked when the player opened.
    var spdifCodecs: [String] = []
    /// Direct play failed on this file, so every stream from now on is converted by the server.
    var convertsAfterFailure = false
    var failurePolicy = PlaybackFailurePolicy()
    var heals = HealBudget()
    var pingTask: Task<Void, Never>?
    var sessionWatch: SessionWatch?
    var streamOffset: Double = 0
    var segments: [SkipMarker] = []
    var subtitlesTurnedOff = false
    var detail: PlexMetadata?
    var speed: Double = 1
    var sleepTimer: SleepTimer?
    var volumeBeforeFade: Double?
    var awayDetector = AwayDetector()
    var positionAtLastBeat: Double = 0
    var pausedSince: ContinuousClock.Instant?
    var undo: (returnTo: Double, until: ContinuousClock.Instant)?
    var autoSkipped: Set<SkipMarker> = []
    /// Where a drag along the scrubber began, for Go Back once it is let go.
    var scrubOrigin: Double?
    /// The drag paused playback, so letting go plays on.
    var scrubResumes = false
    /// The preview still standing in for the picture while a seek is on its way (`StillVeil`).
    var seekVeil: StillVeil?
    /// Where the playhead was before the last long jump (a drag, a chapter, a number key), for Go Back.
    var jumpOrigin: Double?
    /// The sync, framing and taste set for this title (`PlayerTweaks`).
    var tweaks = PlayerTweaks()
    var toast: PlayerToast?
    /// A subtitle shown on its own for a while: while the sound is muted, or until the stretch a skip back replays has
    /// played again (`until`, on the title's timeline).
    var borrowedSubtitle: Int?
    /// The repeated stretch of A-B Loop, on the title's timeline.
    var loop: (a: Double?, b: Double?) = (nil, nil)
    /// The subtitle chosen last in this player, which turning subtitles back on brings back.
    var lastChosenSubtitle: Int?
    /// The subtitle position last handed to mpv, so it is only told of a change.
    var placedSubtitlePosition: Int?
    /// The peak the picture was last mapped to, in cd/m² (`applyDisplay`).
    var appliedDisplayPeak: Double?
    var calibration: DisplayCalibrationView?
    weak var contextMenu: ContextMenuView?
    /// Whether a menu of the player's (`presentMenu`) is open, which keeps the chrome up like the right-click menu does.
    var menuHoldsChrome = false
    var holdOrigin: Double?
    /// Whether the window filled the screen when Match Content last looked.
    var matchedFullscreen = false

    /// Match Content follows the window into full screen and out of it: the screen matches the title only while the player
    /// fills it.
    private func followFullscreen() {
        guard let window, (window.isFullscreen && !isMini) != matchedFullscreen, !closed else { return }
        matchedFullscreen = window.isFullscreen && !isMini
        if matchedFullscreen, let stream {
            engageMatchContent(stream)
        } else if !matchedFullscreen {
            MatchContent.release()
        }
    }

    /// How far the gamepad's triggers are pulled, the right one less the left, while they scrub.
    var triggerPull: Float = 0
    /// The scan a held d-pad, the triggers or the wheel is making (`PlayerScreen+Scan`).
    var scan: PlayerScan?
    var holdHandled = false
    /// Where the last seek went and when, so presses that come before the player has got there add up.
    var seekTarget: (position: Double, at: ContinuousClock.Instant)?
    var chrome = Animated(1)
    var hideTask: Task<Void, Never>?
    /// Whether the player was paused at its last report, to start the chrome's rest when playback resumes: mpv reports
    /// the change a moment after Space or a click asked for it, too late for the rest those start.
    private var wasPaused = true
    var resolveTask: Task<Void, Never>?
    var reportTask: Task<Void, Never>?
    var heartbeatTask: Task<Void, Never>?
    var revealTask: Task<Void, Never>?
    var metadataTask: Task<Void, Never>?
    var lastReportedState: String?
    var watchers: [PlaybackWatching] = []
    var watchersStarted = false
    private var lastClick: Date?
    /// Whether the last click on the picture paused or played, which a double click puts back as it goes full screen.
    private var lastClickToggled = false
    var closed = false
    /// Settings' changes to the title rules and the taste reaching an open player; removed when it closes.
    var settingsObservers: [NSObjectProtocol] = []
    /// This title's rules as last read, which the skip button consults on every playhead update.
    var keptTitleRules: TitlePlaybackRules?
    var controls: MediaControls?
    var artworkFile: URL?
    var alert: AlertView?

    init(source: Source) {
        self.source = source
        super.init()
        switch source {
        case .plex(_, let item, _): transport.title = item.grandparentTitle.map { "\($0) · \(item.title)" } ?? item.title
        case .file(_, let title): transport.title = title
        case .web(let playback):
            transport.title = playback.entry.title
            web = WebSession(playback: playback)
        case .live(let session):
            transport.title = session.channel.numberedTitle
            live = session
        }
        transport.onScrub = { [weak self] fraction, phase in
            self?.viewerActed()
            self?.scrub(to: fraction, phase: phase)
        }
        transport.onTogglePause = { [weak self] in
            self?.viewerActed()
            self?.togglePause()
        }
        transport.onControl = { [weak self] control, anchor in
            self?.viewerActed()
            self?.present(control, anchor: anchor)
        }
        transport.onSkip = { [weak self] forward in
            self?.viewerActed()
            self?.press(forward: forward, isRepeat: false)
        }
        transport.onToggleMute = { [weak self] in
            guard let self, let player = self.player else { return }
            self.viewerActed()
            player.setMuted(!player.state.isMuted)
        }
        transport.onVolume = { [weak self] volume in
            guard let self else { return }
            self.viewerActed()
            self.setViewerVolume(volume)
        }
        transport.onMini = { [weak self] in self?.onMinimize?() }
        transport.onToggleFullscreen = { [weak self] in
            guard let window = self?.window else { return }
            self?.viewerActed()
            window.setFullscreen(!window.isFullscreen)
        }
        transport.skipSeconds = (Preferences.skipBackSeconds, Preferences.skipForwardSeconds)
        transport.onPointerActivity = { [weak self] inside in
            guard let self else { return }
            if inside {
                self.pointerActivity(overBar: true)
            } else if self.window?.pointerLocation == nil {
                self.pointerLeftWindow()
            }
        }
        transport.onInteractionBegan = { [weak self] in self?.showChrome(autoHide: true, rest: PlayerScreen.chromeRestOnBar) }
        transport.onInteractionEnded = { [weak self] inside in
            guard let self, self.chromeShown else { return }
            self.showChrome(autoHide: true, rest: inside ? Self.chromeRestOnBar : Self.chromeRest)
        }
        transport.chapterTitle = { [weak self] time in
            guard let chapters = self?.stream?.chapters, let chapter = ChapterList.current(ChapterList.playable(chapters), at: time) else { return nil }
            return chapter.title
        }
        skip.isHidden = true
        skip.onPress = { [weak self] in
            self?.viewerActed()
            self?.skipSegment()
        }
        addSubview(transport)
        addSubview(skip)
        followSettings()
    }

    override var canBecomeFocused: Bool { true }
    override var isPointerInteractive: Bool { true }
    override var cursor: Cursor { chrome.target > 0 ? .default : .hidden }
    override var preferredFocusView: View? { self }

    override func didMoveToWindow() {
        guard window != nil, player == nil, !closed else { return }
        start()
    }

    // MARK: Playback

    func start() {
        guard let window, let loop = window.loop else { return }
        PlayerScreen.active = self
        askedAt = .now
        if run.beganWindowed == nil { run.beganWindowed = !window.isFullscreen }
        sleepTimer = run.sleepTimer
        applyTestPresets()
        do {
            let player = try takeWarmPlayer() ?? VideoPlayer(gpu: window.gpu, loop: loop)
            let view = VideoView(player: player)
            insertSubview(view, at: 0)
            view.frame = bounds
            self.player = player
            videoView = view
            player.onStateChange = { [weak self] state in self?.stateChanged(state) }
            player.onEvent = { [weak self] event in self?.handle(event) }
            pacePlayheadReports()
            window.onDisplayColorChange = { [weak self] _ in self?.applyDisplay() }
            controls = MediaControls(loop: loop)
            controls?.onCommand = { [weak self] command in self?.perform(command) }
            sessionWatch = SessionWatch(loop: loop)
            sessionWatch?.onEvent = { [weak self] event in self?.sessionChanged(event) }
            checkAudioOutput()
        } catch {
            presentFailure(String(describing: error), retry: nil)
            return
        }
        showPreroll()
        startHeartbeat()
        guard case .plex = source else {
            if live != nil {
                startLive()
                return
            }
            if case .file(let url, _) = source {
                loadTweaks()
                player?.load(url)
                player?.setPaused(false)
                ScreenAwake.hold(true, in: window)
                showDemoUpNextIfAsked()
            }
            startWeb()
            return
        }
        loadInfo()
        loadArtworkForMediaControls()
        resolveFirstStream()
    }

    /// Resolves the stream the title starts with (`FirstStreamPlan`), or takes the one Instant Start resolved for it.
    func resolveFirstStream() {
        guard case .plex(let api, let item, let resumePosition) = source else { return }
        let plan = FirstStreamPlan(item: item, resume: resumePosition, tracks: chosenTracks, carried: run.trackLanguages)
        let warm = convertsAfterFailure ? nil : warm?.stream
        resolveTask?.cancel()
        resolveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let ready = try? await warm?.value
                let resolved = if let ready { ready } else { try await plan.resolve(api: api, startSecs: resumePosition, forceTranscode: convertsAfterFailure) }
                guard !Task.isCancelled, !closed else { return }
                subtitlesTurnedOff = resolved.chosenSubtitleId == nil && plan.languages?.subtitlesOff == true
                load(resolved)
            } catch {
                guard !Task.isCancelled else { return }
                MidgarLog.error("Resolving ratingKey=\(item.id) failed: \(error)", category: .playback)
                presentFailure(ConnectionError.message(for: error), retry: { [weak self] in self?.resolveFirstStream() })
            }
        }
    }

    /// Plays `resolved` from `requested` (the title's resume point by default).
    func load(_ resolved: ResolvedStream, from requested: Double? = nil, paused: Bool = false) {
        guard case .plex(let api, let item, let resumePosition) = source else { return }
        stream = resolved
        segments = resolved.segments
        sharpenIntro(of: resolved, ratingKey: item.id, api: api)
        let start = Self.streamStart(of: resolved, at: requested ?? resumePosition)
        streamOffset = resolved.isDirectPlay ? 0 : start
        upNext = UpNextResolver(ratingKey: item.id, isEpisode: item.mediaType == "episode", seasonRatingKey: item.parentRatingKey,
                                showRatingKey: item.grandparentRatingKey, queue: run.queue, markers: resolved.markers)
        applyTitleRules()
        startWatchers(for: item, api: api)
        transport.chapterMarks = ChapterList.playable(resolved.chapters).map(\.startSecs)
        showStills(of: resolved, api: api)
        player?.set("sub-scale", String(format: "%.2f", Double(Preferences.subtitleSize.rawValue) / 100))
        player?.set("speed", String(speed))
        loadTweaks()
        applyDisplay()
        reapplyLoop()
        let headers = PlexHeaders.allHeaders(token: api.token)
        let opensAt = resolved.isDirectPlay ? start : 0
        if !adoptsWarmFile(resolved.url, start: opensAt) {
            player?.load(resolved.url, start: opensAt, headers: headers, options: resolved.isDirectPlay ? FileTracks(resolved).loadOptions : [:])
        }
        player?.setPaused(paused)
        engageMatchContent(resolved)
        matchedFullscreen = window?.isFullscreen ?? false
        ScreenAwake.hold(true, in: window)
        MidgarLog.notice("Playing \(item.id) \(resolved.isDirectPlay ? "directly" : "converted") from \(Int(start)) s", category: .playback)
        DemoTour.shared.record(.play)
        startReporting()
        keepAlive(resolved)
        infoPanel?.update(infoContent)
    }

    /// Resolves the stream again at `position` with the tracks playing now, as after a failure or a long absence.
    func reloadStream(at position: Double, freshSession: Bool, paused: Bool = false, then failed: (() -> Void)? = nil) {
        guard let stream, case .plex(let api, let item, _) = source else { return }
        let subtitle = stream.chosenSubtitleId
        let audio = stream.chosenAudioStreamId
        if freshSession, !stream.isDirectPlay {
            let session = stream.sessionId
            Task { try? await api.requestVoid(.stopTranscode(session: session)) }
        }
        let converts = convertsAfterFailure
        resolveTask?.cancel()
        resolveTask = Task { [weak self] in
            do {
                let resolved = try await StreamResolver.resolve(api: api, ratingKey: item.id, startSecs: position, selectedSubtitleId: subtitle,
                                                                selectedAudioStreamId: audio, forceTranscode: converts)
                guard let self, !Task.isCancelled, !self.closed else { return }
                self.load(resolved, from: position, paused: paused)
            } catch {
                guard !Task.isCancelled else { return }
                MidgarLog.error("Reloading the stream failed: \(error)", category: .playback)
                failed?()
            }
        }
    }

    var position: Double { (player?.state.position ?? 0) + streamOffset }

    /// The position a relative move starts from: where a seek still on its way is going, else the playhead.
    var playhead: Double {
        if let seekTarget, seekTarget.at.duration(to: .now) < .seconds(1) { return seekTarget.position }
        return position
    }

    var duration: Double {
        if case .plex(_, let item, _) = source, item.durationSecs > 0 { return item.durationSecs }
        if let known = web?.video?.duration, known > 0, web?.video?.isLive == false { return known }
        return (player?.state.duration ?? 0) + streamOffset
    }

    var isEpisode: Bool {
        if case .plex(_, let item, _) = source { return item.mediaType == "episode" }
        return false
    }

    func stateChanged(_ playerState: VideoPlayer.State) {
        if let preroll, !preroll.isRevealed, playerState.videoWidth > 0 { revealPicture() }
        transport.update(position: position, duration: duration, buffered: playerState.cachedSeconds, paused: playerState.isPaused,
                         buffering: playerState.isBuffering)
        transport.updateSound(volume: playerState.volume, muted: playerState.isMuted, maximum: player?.maximumVolume ?? 100)
        liveTick(paused: playerState.isPaused)
        updateSkip()
        if var resolver = upNext, card == nil, postPlay == nil, resolver.creditsReached(at: position) {
            upNext = resolver
            offerNext(.credits)
        }
        controls?.update(playing: !playerState.isPaused, title: transport.title, show: showTitle, artURL: artworkFile, duration: duration,
                         position: position, canGoNext: upNext?.canOfferNext ?? (web?.playback.queue.isEmpty == false))
        let reportState = playerState.isPaused ? "paused" : "playing"
        let held = scrubOrigin != nil || scan != nil
        if !held { notePause(playerState.isPaused) }
        if reportState != lastReportedState, !held {
            report(reportState)
            let change: PlaybackChange = playerState.isPaused ? .paused(position: position) : .playing(position: position)
            watchers.forEach { $0.playback(change) }
        }
        if playerState.isPaused, preroll == nil {
            showChrome(autoHide: false)
        } else if !playerState.isPaused, wasPaused, chromeShown {
            showChrome(autoHide: true)
        }
        wasPaused = playerState.isPaused
        followBorrowedSubtitle(muted: playerState.isMuted)
        setNeedsDisplay()
    }

    private func handle(_ event: VideoPlayer.Event) {
        switch event {
        case .loaded:
            settleFileTracks()
        case .seeked:
            seekVeil?.lift()
            stills?.titleSeeks(false)
        case .ended:
            if web?.isReplacing == true { return }
            if endedShort() { return }
            if sleepTimer?.stopsAtEndOfItem == true {
                closeForSleep()
                return
            }
            if let card, card.offer.autoplays || card.offer.playbackEnded { return }
            if card != nil { dismissCard() }
            offerNext(.playbackEnded)
        case .failed(let message):
            MidgarLog.error("Playback failed: \(message)", category: .playback)
            recover(from: message)
        }
    }

    /// Where on the title's timeline `resolved` starts for a position of `at`: a file playing directly opens right there, since
    /// mpv seeks it before the first frame; a converted stream starts where the server can begin it.
    static func streamStart(of resolved: ResolvedStream, at position: Double) -> Double {
        guard resolved.isDirectPlay else { return ResumeStrategy.streamStart(resumePosition: position, isDirectPlay: false) }
        return position.isFinite && position > 0 ? position : 0
    }

    /// Checks the tracks a file playing directly opened on against what it carries, since the server can list streams the file
    /// lacks: a missing audio track falls back to mpv's own pick and a missing subtitle to none. A chosen subtitle beside the
    /// file is fetched and added now that the file is open.
    func settleFileTracks() {
        if web != nil {
            settleWebTracks()
            return
        }
        guard let stream, stream.isDirectPlay, let player else { return }
        let tracks = FileTracks(stream)
        if let audio = tracks.audio, audio > player.fileTrackCount("audio") { player.set("aid", "auto") }
        if let subtitle = tracks.subtitle, subtitle > player.fileTrackCount("sub") { player.setSubtitleTrack(nil) }
        if let sidecar = tracks.sidecar { addSidecar(sidecar, of: stream) }
    }

    /// Fetches a subtitle that sits beside the file from the server and shows it.
    func addSidecar(_ subtitle: PlexStream, of stream: ResolvedStream) {
        guard let key = subtitle.key, var components = URLComponents(url: stream.url, resolvingAgainstBaseURL: false) else { return }
        components.path = key
        components.query = nil
        guard let url = components.url else { return }
        player?.addSubtitle(url, title: subtitle.displayTitle)
    }

    // MARK: Chrome

    /// Whether the transport is showing or on its way in.
    var chromeShown: Bool { chrome.target > 0.5 }

    /// How long the chrome stays after the last sign of the viewer (the pointer moving over the picture, a key, a seek):
    /// Settings' Hide Controls After, by default brief on a desk and a little longer on the couch, read from across the room.
    static var chromeRest: Duration { .milliseconds(Int(PlayerMouse.rest * 1000)) }
    /// The longer rest of a pointer stopped on the transport, aiming at a button or reading the scrubber's preview.
    static var chromeRestOnBar: Duration { .milliseconds(Int((PlayerMouse.rest + (Theme.current.density == .desk ? 1 : 0.5)) * 1000)) }

    /// The rest for the pointer where it is now: the longer one while it is on the transport.
    private var restWherePointerIs: Duration {
        guard let pointer = window?.pointerLocation, transport.frameInWindow.contains(pointer) else { return Self.chromeRest }
        return Self.chromeRestOnBar
    }

    /// Brings the chrome up and, with `autoHide`, hides it again after `rest` (by default the one for where the pointer
    /// is) without the viewer, once nothing holds it (a held button, a scrub or volume drag, an open menu); paused
    /// playback and the info panel keep it up.
    func showChrome(autoHide: Bool, rest: Duration? = nil) {
        guard preroll == nil, !isMini else { return }
        chrome.set(1, animation: .fade)
        pacePlayheadReports()
        transport.hidesPointer = false
        placeSubtitles()
        window?.setCursor(.default)
        startAnimating()
        hideTask?.cancel()
        guard autoHide, player?.state.isPaused == false, infoPanel == nil else { return }
        let rest = rest ?? restWherePointerIs
        hideTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: rest)
                guard let self, !Task.isCancelled, !self.isMini, self.postPlay == nil, self.player?.state.isPaused == false, self.infoPanel == nil
                else { return }
                if self.transport.holdsChrome || self.contextMenu != nil || self.menuHoldsChrome { continue }
                self.hideChrome()
                return
            }
        }
    }

    /// Fades the chrome and the pointer out, remembering where the pointer rests so a nudge from there does not bring
    /// them back.
    private func hideChrome() {
        restingPointer = window?.pointerLocation
        chrome.set(0, animation: .timed(duration: 0.25, curve: .easeInOut))
        pacePlayheadReports()
        transport.hidesPointer = true
        placeSubtitles()
        window?.setCursor(.hidden)
        startAnimating()
    }

    /// The player's reports while the playhead is on screen (the transport up, or the mini player's bar) come every frame;
    /// with it hidden, four a second do for the skip button, the credits and the session controls, and the window is not
    /// drawn again for each frame's report besides the picture.
    func pacePlayheadReports() {
        player?.progressInterval = chromeShown || isMini ? 0 : 0.25
    }

    func holdChrome() {
        hideTask?.cancel()
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [chrome.advance(dt), miniHover.advance(dt)].contains(true)
        transport.alpha = isMini ? 0 : chrome.value
        transport.translation = Point(x: 0, y: (1 - chrome.value) * Theme.current.metrics.tv(40))
        setNeedsDisplay()
        return moving
    }

    // MARK: Input

    override func keyPressed(_ event: KeyEvent) -> Bool {
        guard let player else { return false }
        if event.modifiers == .control, event.key == Key.character("c") {
            screenshot(withSubtitles: false, copy: true)
            return true
        }
        let modifiers = event.modifiers.subtracting(.shift)
        guard modifiers.isEmpty else { return false }
        let onPicture = window?.focusedView === self
        if !onPicture, [Key.left, .right, .up, .down, .return, .keypadEnter, .space].contains(event.key) { return false }
        viewerActed()
        if event.modifiers.contains(.shift), handleShifted(event) {
            showChrome(autoHide: true)
            return true
        }
        if live != nil, liveKey(event) {
            showChrome(autoHide: true)
            return true
        }
        if let tenth = Self.tenth(of: event.key) {
            jump(toTenth: tenth)
            showChrome(autoHide: true)
            return true
        }
        switch event.key {
        case Key.character(","):
            stepFrame(forward: false)
            return true
        case Key.character("."):
            stepFrame(forward: true)
            return true
        case Key.character("z"):
            setSubtitleDelay(tweaks.title.subtitleDelay - 0.1)
            return true
        case Key.character("x"):
            setSubtitleDelay(tweaks.title.subtitleDelay + 0.1)
            return true
        case Key.character("-"):
            setAudioDelay(tweaks.title.audioDelay - 0.1)
            return true
        case Key.character("="):
            setAudioDelay(tweaks.title.audioDelay + 0.1)
            return true
        case Key.character("v"):
            toggleSubtitles()
            return true
        default:
            break
        }
        switch event.key {
        case .space, Key.character("k"), .mediaPlay:
            togglePause()
        case .mediaPause:
            player.setPaused(true)
        case .left, Key.character("j"):
            press(forward: false, isRepeat: event.isRepeat)
        case .right, Key.character("l"):
            press(forward: true, isRepeat: event.isRepeat)
        case .home:
            startOver()
        case .pageUp:
            moveByChapter(forward: false)
        case .pageDown:
            moveByChapter(forward: true)
        case Key.character("["):
            stepSpeed(by: -1)
        case Key.character("]"):
            stepSpeed(by: 1)
        case .backspace:
            setSpeed(1)
        case .up, .down:
            let volume = min(max(player.state.volume + (event.key == .up ? 5 : -5), 0), player.maximumVolume)
            setViewerVolume(volume)
            say(String(localized: "Volume \(Int(volume))%", comment: "Player message with the volume, as in \"Volume 55%\""), symbol: volume <= 0 ? "speaker.slash" : "speaker.wave.2")
            return true
        case Key.character("m"):
            toggleMute()
            return true
        case Key.character("s"), .return:
            if !skip.isHidden { skipSegment() } else { togglePause() }
        case Key.character("p"):
            onMinimize?()
        case Key.character("i"):
            toggleInfo()
        case Key.character("a"):
            present(.audio, anchor: transport.transformToWindow.apply(transport.frame(of: .audio)))
        case Key.character("c"):
            present(.subtitles, anchor: transport.transformToWindow.apply(transport.frame(of: .subtitles)))
        case Key.character("t"):
            present(.sleep, anchor: transport.transformToWindow.apply(transport.frame(of: .sleep)))
        case Key.character("f"), .f11:
            if let window { window.setFullscreen(!window.isFullscreen) }
        case .escape, .back:
            if let card {
                if card.offer.playbackEnded { close() } else { dismissCard() }
            } else if event.key == .escape, LinuxDisplay.leaveFullscreen(window) {
                break
            } else {
                close()
            }
        case Key.character("n"):
            offerNext(.requested)
        default:
            return false
        }
        showChrome(autoHide: true)
        return true
    }

    /// Shift with a key: Left and Right a precise second, Backspace Go Back, L the A-B loop, S a screenshot.
    private func handleShifted(_ event: KeyEvent) -> Bool {
        switch event.key {
        case .left:
            nudge(by: -1)
        case .right:
            nudge(by: 1)
        case .backspace:
            goBack()
        case Key.character("l"), Key.character("L"):
            markLoop()
        case Key.character("s"), Key.character("S"):
            screenshot(withSubtitles: false, copy: false)
        default:
            return false
        }
        return true
    }

    /// The tenth of the title a digit key jumps to: 0 the start, 5 the middle, 9 nine tenths in.
    static func tenth(of key: Key) -> Int? {
        for digit in 0...9 where key == Key.character(Character(String(digit))) { return digit }
        return nil
    }

    /// Left or Right: a press skips the distance Settings give that side; held, the side does what Settings say for a hold
    /// (scan, a jump from where the press began, start over or the next episode).
    private func press(forward: Bool, isRepeat: Bool) {
        let step = Double(forward ? Preferences.skipForwardSeconds : -Preferences.skipBackSeconds)
        guard isRepeat else {
            if scan != nil { endScan() }
            holdOrigin = playhead
            holdHandled = false
            seek(to: playhead + step)
            return
        }
        let action = forward ? Preferences.holdRightAction : Preferences.holdLeftAction
        switch action {
        case .scan:
            beginScan(.hold(forward: forward), from: playhead)?.lastInput = Window.now()
        case .edge:
            guard !holdHandled else { return }
            holdHandled = true
            if forward { offerNext(.requested) } else { startOver() }
        default:
            guard !holdHandled, let seconds = action.jumpSeconds else { return }
            holdHandled = true
            seek(to: (holdOrigin ?? position) + Double(forward ? seconds : -seconds))
        }
    }

    /// Where the pointer last moved over the player, and where it rested when the chrome hid, in window points.
    private var lastPointer: Point?
    private var restingPointer: Point?
    /// What the wheel's current run drives (the volume, or else the playhead) and when its last event came.
    var wheelRun: (turnsVolume: Bool, at: Double)?

    override func pointerMoved(to point: Point) {
        if isMini {
            miniPointerMoved(to: point)
            return
        }
        pointerActivity(overBar: transport.frame.contains(point))
    }

    /// The pointer moved over the player, on the transport when `overBar`. Shown chrome stays for another rest, longer
    /// over the transport; hidden chrome comes back, except for a nudge of a few points from where the pointer rested when
    /// it hid (a bumped desk or a settling mouse). A report of the spot the pointer already was at is no movement at all.
    func pointerActivity(overBar: Bool) {
        guard let location = window?.pointerLocation else { return }
        let previous = lastPointer
        lastPointer = location
        if location == previous { return }
        if chrome.target < 0.5, let rest = restingPointer, abs(location.x - rest.x) + abs(location.y - rest.y) < Theme.current.metrics.tv(24) { return }
        restingPointer = nil
        stills?.prepare()
        showChrome(autoHide: true, rest: overBar ? Self.chromeRestOnBar : Self.chromeRest)
    }

    /// The pointer stays hidden with the chrome over the playing picture, so a nudge too small to bring the chrome back
    /// does not show it either; over the pre-roll, the post-play suggestions and the mini player it always shows.
    override func cursor(at point: Point) -> Cursor {
        !isMini && chrome.target < 0.5 && preroll == nil && postPlay == nil ? .hidden : .default
    }

    override func pointerDragged(to point: Point) {
        if isMini { miniPointerDragged(to: point) }
    }

    override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        if isMini { miniReleased(button, at: point) }
    }

    override func drawOverlay(_ context: inout DrawContext) {
        if isMini { drawMiniControls(&context) }
    }

    override func tooltip(at point: Point) -> String? {
        isMini ? miniTooltip(at: point) : nil
    }

    override func pointerExited() {
        if isMini {
            miniPointerExited()
            return
        }
        guard window?.pointerLocation == nil else { return }
        pointerLeftWindow()
    }

    /// The pointer left the window (onto its border, another window or screen): shown chrome goes after the usual rest,
    /// not at once, and hidden chrome stays hidden.
    private func pointerLeftWindow() {
        lastPointer = nil
        guard chrome.target > 0 else { return }
        showChrome(autoHide: true)
    }

    /// The window changing size (its border dragged) keeps shown chrome up for another rest, so it does not vanish
    /// mid-resize.
    private func windowResized() {
        guard chrome.target > 0, player?.state.isPaused == false else { return }
        showChrome(autoHide: true)
    }

    /// The gamepad's triggers scan (`PlayerScan`): the right one forward and the left one back, faster the further they are
    /// pulled, up to a minute and a half of the title each second, until both are let go.
    override func gamepadTriggered(left: Float, right: Float) -> Bool {
        guard player != nil else { return false }
        let pull = right - left
        triggerPull = abs(pull) > 0.12 ? pull : 0
        if triggerPull != 0 { beginScan(.triggers, from: playhead) }
        return true
    }

    /// A click on the picture does what Settings › Controls says (by default pauses or plays, and twice also goes full
    /// screen), except where the hidden transport sits: the viewer is aiming at a button they cannot see, so that click
    /// brings the transport back instead. A right click on the skip button offers how this show skips that stretch.
    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        viewerActed()
        if isMini { return miniPressed(button, at: point) }
        switch button {
        case .primary:
            if chrome.target < 0.5, transport.frame.contains(point) {
                showChrome(autoHide: true, rest: Self.chromeRestOnBar)
                return true
            }
            clickedPicture()
            return true
        case .middle:
            middleClicked()
            return true
        case .back:
            close()
            return true
        case .secondary:
            guard scrubOrigin == nil else { return false }
            if !skip.isHidden, skip.frame.contains(point), presentSkipMenu(at: transformToWindow.apply(point)) { return true }
            presentContextMenu(at: transformToWindow.apply(point))
            return true
        default:
            return false
        }
    }

    /// One click on the picture, or the second of a double click, as Settings › Controls › Mouse has them.
    private func clickedPicture() {
        let now = Date()
        if let lastClick, now.timeIntervalSince(lastClick) < 0.35, PlayerMouse.doubleClick == .fullScreen, let window {
            window.setFullscreen(!window.isFullscreen)
            if lastClickToggled { togglePause() }
            self.lastClick = nil
            lastClickToggled = false
            showChrome(autoHide: true)
            return
        }
        lastClick = now
        lastClickToggled = false
        switch PlayerMouse.click {
        case .playPause:
            togglePause()
            lastClickToggled = true
            showChrome(autoHide: true)
        case .showControls:
            if chromeShown { hideChrome() } else { showChrome(autoHide: true) }
        case .nothing:
            break
        }
    }

    private func middleClicked() {
        switch PlayerMouse.middleClick {
        case .nothing: return
        case .mute: toggleMute()
        case .playPause: togglePause()
        case .fullScreen: window.map { $0.setFullscreen(!$0.isFullscreen) }
        }
        showChrome(autoHide: true)
    }

    override func showContextMenu(at point: Point?) -> Bool {
        presentContextMenu(at: point)
        return true
    }

    /// The wheel or a touchpad does what Settings › Controls › Mouse says (by default seeks 5 s a notch), except a run
    /// that began over the shown transport's volume slider or mute button, which turns the volume and keeps the transport
    /// up while it does (`wheelTurnsVolume`).
    override func scrolled(_ event: ScrollEvent) -> Bool {
        let wheel = PlayerMouse.wheel
        if wheelTurnsVolume(event) || (wheel == .volume && !isMini) {
            transport.turnVolume(event)
            showChrome(autoHide: true, rest: Self.chromeRestOnBar)
            return true
        }
        guard let notch = wheel.seconds ?? (isMini ? 5 : nil) else { return true }
        let step: Double = event.isDiscrete ? Double(-event.notchesY + event.notchesX) * notch : Double(-event.dy + event.dx) * 0.02 * notch
        guard step != 0 else { return true }
        if isMini {
            viewerActed()
            seek(to: playhead - step)
        } else {
            scanWheel(by: -step)
        }
        return true
    }

    /// The size the player was last laid out at, to tell a resize from other layouts.
    private var laidOutSize: Size?

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        for overlay in [skip, card, infoPanel, toast] as [View?] { overlay?.alpha = isMini ? 0 : 1 }
        transport.alpha = isMini ? 0 : chrome.value
        if isMini {
            laidOutSize = nil
            followFullscreen()
            for layer in [videoView, web?.poster, seekVeil, calibration, preroll, postPlay] as [View?] { layer?.frame = bounds }
            return
        }
        if let previous = laidOutSize, previous != bounds.size { windowResized() }
        laidOutSize = bounds.size
        followFullscreen()
        videoView?.frame = bounds
        web?.poster?.frame = bounds
        seekVeil?.frame = bounds
        calibration?.frame = bounds
        preroll?.frame = bounds
        postPlay?.frame = bounds
        let desk = Theme.current.density == .desk
        let width = desk ? frame.width - metrics.tv(64) : min(frame.width - metrics.sideMargin * 2, metrics.tv(1600))
        let height = transport.sizeThatFits(Size(width: width, height: 0)).height
        transport.frame = Rect(x: ((frame.width - width) / 2).rounded(), y: frame.height - height - metrics.tv(desk ? 32 : 48), width: width, height: height)
        transport.isFullscreen = window?.isFullscreen ?? false
        if let infoPanel {
            let room = transport.frame.y - metrics.tv(24) - metrics.tv(desk ? 32 : 48)
            let panelHeight = infoPanel.sizeThatFits(Size(width: width, height: room)).height
            infoPanel.frame = Rect(x: transport.frame.x, y: transport.frame.y - panelHeight - metrics.tv(24), width: width, height: panelHeight)
        }
        layoutToast()
        placeSubtitles()
        let above = infoPanel?.frame.y ?? transport.frame.y
        let size = skip.sizeThatFits(Size(width: 600, height: 200))
        skip.frame = Rect(x: frame.width - metrics.sideMargin - size.width, y: above - size.height - metrics.tv(32),
                          width: size.width, height: size.height)
        if let card {
            let cardSize = card.sizeThatFits(bounds.size)
            card.frame = Rect(x: frame.width - metrics.sideMargin - cardSize.width, y: above - cardSize.height - metrics.tv(32),
                              width: cardSize.width, height: cardSize.height)
        }
    }
}

/// What Up Next learned about the title after the one playing.
enum NextKnown {
    case offer(UpNextOffer)
    case nothingNext
}

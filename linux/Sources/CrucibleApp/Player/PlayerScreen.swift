import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// The player (§7.5): the pre-roll until the picture shows, then the picture full window, a Liquid Glass transport that
/// floats in on the pointer or a key and away after three seconds of playing, Skip Intro and Skip Credits (and Undo Skip
/// after an automatic one) over the picture, the info panel, Up Next with "Still watching?", what's next at the end, a
/// sleep timer, and the server told where the playhead is every ten seconds and whenever it stops or pauses.
///
/// Keys: Space or K play and pause, Left and Right or J and L the skip distances (held: what Settings say), Home starts
/// over, Page Up and Page Down move by chapter, [ and ] change the speed and Backspace resets it, Up and Down volume,
/// M mute, S skip, I the info panel, A and C audio and subtitles, T the sleep timer, N the next episode, F full screen,
/// Escape leaves full screen, then goes back. A click plays and pauses, a double click fills the screen, the wheel moves
/// through the title.
@MainActor
final class PlayerScreen: View {
    /// What plays: a title on the Plex server from a position, or a local file (headless checks of the player itself).
    enum Source {
        case plex(APIClient, PlexMetadata, resume: Double)
        case file(URL, title: String)
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
    private var videoView: VideoView?
    let transport = TransportView()
    let skip = ButtonView(style: .glass, title: nil, symbol: "forward.end.fill", symbolTrailing: true)
    var preroll: PrerollView?
    var infoPanel: PlayerInfoPanel?
    var postPlay: PostPlayView?
    var stream: ResolvedStream?
    var stills: ScrubStillLoader?
    /// The codecs mpv passes through to the receiver, from the sound output as it was checked when the player opened.
    private var spdifCodecs: [String] = []
    /// Direct play failed on this file, so every stream from now on is converted by the server.
    var convertsAfterFailure = false
    private var failurePolicy = PlaybackFailurePolicy()
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
    var holdOrigin: Double?
    /// Whether the window filled the screen when Match Content last looked.
    private var matchedFullscreen = false

    /// Match Content follows the window into full screen and out of it: the screen matches the title only while the player
    /// fills it.
    private func followFullscreen() {
        guard let window, window.isFullscreen != matchedFullscreen, !closed else { return }
        matchedFullscreen = window.isFullscreen
        if matchedFullscreen, let stream {
            MatchContent.engage(stream, in: window)
        } else if !matchedFullscreen {
            MatchContent.release()
        }
    }

    /// How far the gamepad's triggers are pulled, the right one less the left, while they scrub.
    private var triggerPull: Float = 0
    private var triggerScrub: Task<Void, Never>?
    var holdHandled = false
    /// Where the last seek went and when, so presses that come before the player has got there add up.
    private var seekTarget: (position: Double, at: ContinuousClock.Instant)?
    private var chrome = Animated(1)
    private var hideTask: Task<Void, Never>?
    var resolveTask: Task<Void, Never>?
    private var reportTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    var metadataTask: Task<Void, Never>?
    private var lastReportedState: String?
    private var watchers: [PlaybackWatching] = []
    private var watchersStarted = false
    private var lastClick: Date?
    private(set) var closed = false
    var controls: MediaControls?
    var artworkFile: URL?
    private var alert: AlertView?

    init(source: Source) {
        self.source = source
        super.init()
        switch source {
        case .plex(_, let item, _): transport.title = item.grandparentTitle.map { "\($0) · \(item.title)" } ?? item.title
        case .file(_, let title): transport.title = title
        }
        transport.onSeek = { [weak self] fraction in
            self?.viewerActed()
            self?.seek(toFraction: fraction)
        }
        transport.onTogglePause = { [weak self] in
            self?.viewerActed()
            self?.togglePause()
        }
        transport.onControl = { [weak self] control, anchor in
            self?.viewerActed()
            self?.present(control, anchor: anchor)
        }
        transport.chapterTitle = { [weak self] time in
            guard let chapters = self?.stream?.chapters, let chapter = ChapterList.current(ChapterList.playable(chapters), at: time) else { return nil }
            return ChapterList.menuTitle(chapter)
        }
        skip.isHidden = true
        skip.onPress = { [weak self] in
            self?.viewerActed()
            self?.skipSegment()
        }
        addSubview(transport)
        addSubview(skip)
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

    private func start() {
        guard let window, let loop = window.loop else { return }
        PlayerScreen.active = self
        if run.beganWindowed == nil { run.beganWindowed = !window.isFullscreen }
        sleepTimer = run.sleepTimer
        applyTestPresets()
        do {
            let player = try VideoPlayer(gpu: window.gpu, loop: loop)
            let view = VideoView(player: player)
            insertSubview(view, at: 0)
            view.frame = bounds
            self.player = player
            videoView = view
            player.onStateChange = { [weak self] state in self?.stateChanged(state) }
            player.onEvent = { [weak self] event in self?.handle(event) }
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
            if case .file(let url, _) = source {
                player?.load(url)
                player?.setPaused(false)
                ScreenAwake.hold(true, in: window)
                showDemoUpNextIfAsked()
            }
            return
        }
        loadInfo()
        loadArtworkForMediaControls()
        resolveFirstStream()
    }

    /// Resolves the stream the title starts with: the tracks a title page chose, else the languages the episode before or
    /// the show last played in, else what the server and the viewer's settings pick.
    func resolveFirstStream() {
        guard case .plex(let api, let item, let resumePosition) = source else { return }
        let tracks = chosenTracks
        let languages = tracks == nil ? startingLanguages : nil
        resolveTask?.cancel()
        resolveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await StreamResolver.resolve(api: api, ratingKey: item.id, startSecs: resumePosition,
                                                                selectedSubtitleId: tracks?.subtitle, selectedAudioStreamId: tracks?.audio,
                                                                languages: languages, honorsServerSelection: tracks == nil && languages == nil,
                                                                forceTranscode: convertsAfterFailure)
                guard !Task.isCancelled, !closed else { return }
                subtitlesTurnedOff = resolved.chosenSubtitleId == nil && languages?.subtitlesOff == true
                load(resolved)
            } catch {
                guard !Task.isCancelled else { return }
                MidgarLog.error("Resolving ratingKey=\(item.id) failed: \(error)", category: .playback)
                presentFailure(ConnectionError.message(for: error), retry: { [weak self] in self?.resolveFirstStream() })
            }
        }
    }

    /// Asks the sound output what it takes before the stream is resolved; a check that ends after the first file started
    /// still reaches mpv, which reopens its audio for the change.
    private func checkAudioOutput() {
        let setting = Preferences.audioPassthrough
        Task { [weak self] in
            let codecs = await AudioOutput.prepare(setting)
            guard let self, codecs != self.spdifCodecs else { return }
            self.spdifCodecs = codecs
            if self.stream != nil { self.player?.set("audio-spdif", codecs.joined(separator: ",")) }
        }
    }

    /// Plays `resolved` from `requested` (the title's resume point by default).
    func load(_ resolved: ResolvedStream, from requested: Double? = nil, paused: Bool = false) {
        guard case .plex(let api, let item, let resumePosition) = source else { return }
        stream = resolved
        segments = resolved.segments
        let start = Self.streamStart(of: resolved, at: requested ?? resumePosition)
        streamOffset = resolved.isDirectPlay ? 0 : start
        upNext = UpNextResolver(ratingKey: item.id, isEpisode: item.mediaType == "episode", seasonRatingKey: item.parentRatingKey,
                                showRatingKey: item.grandparentRatingKey, queue: run.queue, markers: resolved.markers)
        startWatchers(for: item, api: api)
        transport.chapterMarks = ChapterList.playable(resolved.chapters).map(\.startSecs)
        showStills(of: resolved, api: api)
        player?.set("sub-scale", String(format: "%.2f", Double(Preferences.subtitleSize.rawValue) / 100))
        player?.set("audio-spdif", spdifCodecs.joined(separator: ","))
        player?.set("speed", String(speed))
        let headers = PlexHeaders.allHeaders(token: api.token)
        player?.load(resolved.url, start: resolved.isDirectPlay ? start : 0, headers: headers,
                     options: resolved.isDirectPlay ? FileTracks(resolved).loadOptions : [:])
        player?.setPaused(paused)
        if let window { MatchContent.engage(resolved, in: window) }
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
        return (player?.state.duration ?? 0) + streamOffset
    }

    var isEpisode: Bool {
        if case .plex(_, let item, _) = source { return item.mediaType == "episode" }
        return false
    }

    private func stateChanged(_ playerState: VideoPlayer.State) {
        if let preroll, !preroll.isRevealed, playerState.videoWidth > 0 { revealPicture() }
        transport.update(position: position, duration: duration, buffered: playerState.cachedSeconds, paused: playerState.isPaused,
                         buffering: playerState.isBuffering)
        updateSkip()
        if var resolver = upNext, card == nil, postPlay == nil, resolver.creditsReached(at: position) {
            upNext = resolver
            offerNext(.credits)
        }
        controls?.update(playing: !playerState.isPaused, title: transport.title, show: showTitle, artURL: artworkFile, duration: duration,
                         position: position, canGoNext: upNext?.canOfferNext ?? false)
        notePause(playerState.isPaused)
        let reportState = playerState.isPaused ? "paused" : "playing"
        if reportState != lastReportedState {
            report(reportState)
            let change: PlaybackChange = playerState.isPaused ? .paused(position: position) : .playing(position: position)
            watchers.forEach { $0.playback(change) }
        }
        if playerState.isPaused, preroll == nil { showChrome(autoHide: false) }
        setNeedsDisplay()
    }

    private func handle(_ event: VideoPlayer.Event) {
        switch event {
        case .loaded:
            settleFileTracks()
        case .seeked:
            break
        case .ended:
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
    private func settleFileTracks() {
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

    /// Answers a failed stream as `PlaybackSession` does: a file that fails to play as it is gets converted by the server
    /// from the playhead, once; anything else says so with Retry, and stops keeping the dead session alive, whose ping would
    /// otherwise rebuild it behind the error every 20 seconds.
    private func recover(from message: String) {
        switch failurePolicy.decide(wasDirectPlay: stream?.isDirectPlay ?? false, isOffline: false) {
        case .fallBackToTranscode:
            fallBackToTranscode(after: message)
        case .ignore:
            break
        case .restartTranscode, .fail:
            pingTask?.cancel()
            presentFailure(message, retry: { [weak self] in self?.retryFromPlayhead() })
        }
    }

    /// Plays the file converted by the server from where direct play stopped, or from the resume point when it never started.
    private func fallBackToTranscode(after message: String) {
        guard case .plex(_, let item, let resumePosition) = source else { return }
        let start = PlaybackFailurePolicy.fallbackStart(lastAbsolute: position, resumePosition: resumePosition)
        MidgarLog.notice("Direct play of \(item.id) failed (\(message)); converting from \(Int(start)) s", category: .playback)
        convertsAfterFailure = true
        reloadStream(at: start, freshSession: false) { [weak self] in
            self?.failurePolicy.recordFailure()
            self?.presentFailure(message, retry: { [weak self] in self?.retryFromPlayhead() })
        }
    }

    /// Plays again from where it failed, in the same tracks.
    private func retryFromPlayhead() {
        failurePolicy = PlaybackFailurePolicy()
        guard stream != nil else {
            resolveFirstStream()
            return
        }
        let at = position
        reloadStream(at: at, freshSession: true) { [weak self] in
            self?.presentFailure(String(localized: "The server didn’t answer."), retry: { [weak self] in self?.retryFromPlayhead() })
        }
    }

    /// Playback Error with Retry and Close (`TVPlayerCoordinator.presentFailure`); Escape closes. One alert at a time.
    func presentFailure(_ message: String, retry: (() -> Void)?) {
        guard alert == nil, !closed, let window else { return }
        var actions = [AlertView.Action(String(localized: "Close", comment: "Alert button that dismisses the error"), role: .cancel) { [weak self] in
            self?.alert = nil
            self?.close()
        }]
        if let retry {
            actions.insert(AlertView.Action(String(localized: "Retry")) { [weak self] in
                self?.alert = nil
                retry()
            }, at: 0)
        }
        let shown = AlertView(title: String(localized: "Playback Error"), message: String(localized: "This video couldn’t be played.\n\(message)"),
                              actions: actions)
        alert = shown
        shown.present(in: window)
    }

    private func seek(toFraction fraction: Float) {
        guard duration > 0 else { return }
        seek(to: Double(fraction) * duration)
    }

    /// `CRUCIBLE_PLAYER_SLEEP_TIMER=<seconds>` starts with a timed sleep timer that runs out that many seconds later (`end`
    /// for one that stops at the end of the item), and `CRUCIBLE_PLAYER_UNATTENDED=<n>` as if `n` episodes had played with
    /// nobody at the keyboard, so headless checks reach the end of a timer and "Still watching?" without waiting for them.
    private func applyTestPresets() {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["CRUCIBLE_PLAYER_SLEEP_TIMER"], run.sleepTimer == nil {
            if value == "end" {
                sleepTimer = SleepTimer(choice: .endOfItem)
            } else if let seconds = Double(value) {
                sleepTimer = SleepTimer(choice: .minutes(15), now: Date().addingTimeInterval(seconds - 15 * 60))
            }
            transport.isSleepTimerSet = sleepTimer != nil
        }
        if let count = environment["CRUCIBLE_PLAYER_UNATTENDED"].flatMap(Int.init) {
            run.unattendedEpisodes = count
            run.viewerActedThisEpisode = false
        }
    }

    // MARK: Pre-roll

    private func showPreroll() {
        let headline = prerollHeadline
        let shown = PrerollView(title: headline.title, subtitle: headline.subtitle, posterPath: headline.posterPath)
        preroll = shown
        insertSubview(shown, below: transport)
        chrome.reset(0)
        setNeedsLayout()
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: PrerollView.revealTimeout)
            guard let self, !Task.isCancelled else { return }
            self.revealPicture()
        }
    }

    /// The pre-roll's title and its episode or year line, before the server's full record arrives.
    var prerollHeadline: (title: String, subtitle: String?, posterPath: String?) {
        switch source {
        case .file(_, let title):
            return (title, nil, nil)
        case .plex(_, let item, _):
            if let show = item.grandparentTitle {
                let code = Formatters.episodeCode(item.parentIndex, item.index)
                return (item.title, [show, code].compactMap { $0 }.joined(separator: " · "), item.grandparentThumb ?? item.thumb)
            }
            let line = [item.year.map(String.init), item.contentRating].compactMap { $0 }.joined(separator: " · ")
            return (item.title, line.isEmpty ? nil : line, item.thumb)
        }
    }

    /// Dissolves from the pre-roll into the picture, the transport coming up with it.
    private func revealPicture() {
        revealTask?.cancel()
        guard let preroll, !preroll.isRevealed else { return }
        preroll.reveal()
        self.preroll = nil
        showChrome(autoHide: true)
    }

    // MARK: Up Next

    /// Asks for the next episode; shows the card, or plays at once when asked for, or what's next at the end with none.
    func offerNext(_ reason: UpNextOffer.Reason) {
        guard let resolver = upNext, case .plex(let api, _, _) = source else {
            if reason == .playbackEnded { endOfPlayback() }
            return
        }
        offerTask?.cancel()
        offerTask = Task { [weak self] in
            let answer = await Result { try await resolver.loadOffer(api: api, reason: reason) }
            guard let self, !Task.isCancelled, !self.closed else { return }
            if case .success(let found) = answer { self.nextKnown = found.map(NextKnown.offer) ?? .nothingNext }
            guard case .success(let found) = answer, let offer = found else {
                if reason == .playbackEnded { self.endOfPlayback() }
                return
            }
            if reason == .requested {
                self.playNext(offer, byViewer: true)
            } else {
                self.show(offer)
            }
        }
    }

    private func show(_ offer: UpNextOffer) {
        card?.removeFromSuperview()
        let next = UpNextCard(offer: offer, asksStillWatching: run.asksStillWatching, stopsAfterItem: sleepTimer?.stopsAtEndOfItem == true)
        next.onPlay = { [weak self] byViewer in self?.playNext(offer, byViewer: byViewer) }
        next.onLeave = { [weak self] in
            self?.viewerActed()
            if offer.playbackEnded { self?.close() } else { self?.dismissCard() }
        }
        card = next
        addSubview(next)
        setNeedsLayout()
        next.appearNow()
        window?.focus.focus(next, animated: false)
        showChrome(autoHide: true)
    }

    /// `CRUCIBLE_UPNEXT_DEMO=1` with a local file shows the Up Next card two seconds in, for headless checks of its look.
    private func showDemoUpNextIfAsked() {
        guard ProcessInfo.processInfo.environment["CRUCIBLE_UPNEXT_DEMO"] == "1" else { return }
        let json = #"{"ratingKey":"demo-2","key":"/library/metadata/2","type":"episode","title":"What the Bees Know","index":2,"parentIndex":1}"#
        guard let episode = try? JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8)) else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.show(UpNextOffer(episode: episode, seasonRatingKey: "demo", reason: .credits, autoplays: true))
        }
    }

    func dismissCard() {
        card?.stopCounting()
        card?.removeFromSuperview()
        card = nil
        window?.focus.focus(self, animated: false)
    }

    /// Ends this playback (the server hears it stopped) and hands the next episode, or the playlist's next entry, on with the
    /// run it continues.
    private func playNext(_ offer: UpNextOffer, byViewer: Bool) {
        let next = run.advancing(byViewer: byViewer, languages: trackLanguages, sleepTimer: sleepTimer, queue: offer.queue)
        let hand = onPlayNext
        onClose = nil
        close()
        hand?(offer.episode, next)
    }

    private var showTitle: String? {
        if case .plex(_, let item, _) = source { return item.grandparentTitle }
        return nil
    }

    private func perform(_ command: MediaControls.Command) {
        guard let player else { return }
        switch command {
        case .playPause: togglePause()
        case .play: player.setPaused(false)
        case .pause: player.setPaused(true)
        case .stop: close()
        case .seek(let offset):
            guard offset != 0 else { return }
            seek(to: playhead + Double(offset > 0 ? Preferences.skipForwardSeconds : -Preferences.skipBackSeconds))
        case .setPosition(let target): seek(to: target)
        case .next: offerNext(.requested)
        case .previous: startOver()
        case .raise: window?.raise()
        case .quit: MediaControls.onQuit?()
        }
    }

    func togglePause() {
        player?.togglePause()
    }

    func seek(to absolute: Double) {
        let target = min(max(absolute, 0), max(duration - 1, 0))
        seekTarget = (target, .now)
        player?.seek(to: target - streamOffset)
        controls?.seeked(to: target)
        showChrome(autoHide: true)
    }

    /// Back to the start of the title, playing on if it was playing.
    func startOver() {
        seek(to: 0)
    }

    // MARK: Skipping

    /// Shows Skip Intro or Skip Credits inside a segment, or skips it at once when Settings say so (once per segment, so
    /// seeking back into it plays it), then offers Undo Skip for a few seconds.
    private func updateSkip() {
        if let undo {
            if ContinuousClock.now < undo.until { return }
            self.undo = nil
        }
        let now = position
        if let segment = segments.first(where: { now >= $0.startSecs && now < $0.endSecs - 1 }), card == nil {
            let automatic = segment.isCredits ? Preferences.skipOutroMode == .automatic : Preferences.skipIntroMode == .automatic
            let off = segment.isCredits ? Preferences.skipOutroMode == .off : Preferences.skipIntroMode == .off
            if off { return }
            if automatic, !segment.isCredits, !autoSkipped.contains(segment) {
                autoSkipped.insert(segment)
                seek(to: segment.endSecs)
                offerUndo(returningTo: now)
                return
            }
            showSkip(title: segment.title, symbol: "forward.end.fill")
        } else if !skip.isHidden {
            skip.isHidden = true
        }
    }

    private func showSkip(title: String, symbol: Symbol) {
        skip.title = title
        skip.symbol = symbol
        if skip.isHidden {
            skip.isHidden = false
            setNeedsLayout()
        }
    }

    private func offerUndo(returningTo position: Double) {
        undo = (position, ContinuousClock.now.advanced(by: PlaybackTiming.autoSkipUndoWindow))
        showSkip(title: String(localized: "Undo Skip"), symbol: "arrow.uturn.backward")
    }

    private func skipSegment() {
        if let undo {
            self.undo = nil
            skip.isHidden = true
            seek(to: undo.returnTo)
            return
        }
        let now = position
        guard let segment = segments.first(where: { now >= $0.startSecs && now < $0.endSecs }) else { return }
        if segment.isCredits && segment.endSecs >= duration - 2 {
            close()
        } else {
            seek(to: segment.endSecs)
        }
    }

    // MARK: Timeline

    /// The integrations that follow this title (Trakt scrobbling), made once for it: a stream restarted mid-play keeps
    /// them, so a play is never started twice.
    private func startWatchers(for item: PlexMetadata, api: APIClient) {
        guard !watchersStarted else { return }
        watchersStarted = true
        watchers = Integrations.playbackWatchers(for: PlaybackSubject(
            ratingKey: item.id, mediaType: item.mediaType, showRatingKey: item.grandparentRatingKey, title: item.title,
            showTitle: item.grandparentTitle, seasonNumber: item.parentIndex, episodeNumber: item.index, durationSecs: duration,
            server: ServerBootstrap.savedMachineIdentifier ?? "", api: api))
    }

    private func startReporting() {
        reportTask?.cancel()
        reportTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(PlaybackTiming.timelineInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.report(self.player?.state.isPaused == true ? "paused" : "playing")
            }
        }
    }

    /// Beats four times a second for as long as the player is open: the sleep timer counts and fades on it, and a beat that
    /// comes long after the last one means the machine slept, which brings the player back where it was.
    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                self.beat()
            }
        }
    }

    @discardableResult
    func report(_ playbackState: String) -> Task<Void, Never>? {
        guard stream != nil, duration > 0, case .plex(let api, let item, _) = source else { return nil }
        lastReportedState = playbackState
        let endpoint = PlexEndpoint.timeline(ratingKey: item.id, state: playbackState, timeMs: Int(position * 1000), durationMs: Int(duration * 1000))
        return Task {
            do {
                try await api.requestVoid(endpoint)
            } catch {
                MidgarLog.error("Timeline report failed: \(error)", category: .playback)
            }
        }
    }

    /// Stops playback, tells the server where it stopped and leaves.
    func close() {
        guard !closed else { return }
        closed = true
        MatchContent.release()
        resolveTask?.cancel()
        reportTask?.cancel()
        heartbeatTask?.cancel()
        pingTask?.cancel()
        revealTask?.cancel()
        metadataTask?.cancel()
        hideTask?.cancel()
        offerTask?.cancel()
        card?.stopCounting()
        alert?.dismiss()
        alert = nil
        let finished = WatchedRule.isFinished(positionSecs: position, durationSecs: duration, creditsStartSecs: upNext?.creditsStartSecs)
        watchers.forEach { $0.playback(.stopped(position: position, finished: finished, at: Date())) }
        if finished { recordFinish() }
        watchers = []
        if let stopped = report("stopped") {
            let pending = Task { @MainActor in
                await stopped.value
                PlayerScreen.pendingStop = nil
            }
            PlayerScreen.pendingStop = pending
        }
        if let stream, !stream.isDirectPlay, case .plex(let api, _, _) = source {
            let session = stream.sessionId
            Task { try? await api.requestVoid(.stopTranscode(session: session)) }
        }
        player?.stop()
        player?.shutDown()
        player = nil
        controls?.close()
        controls = nil
        sessionWatch?.close()
        sessionWatch = nil
        ScreenAwake.hold(false, in: window)
        window?.setCursor(.default)
        restoreWindow()
        onClose?()
    }

    /// Takes the window back out of full screen as the sitting's last title closes, whichever way it closes, when the sitting
    /// began in a window; a hand-over to the next title (no `onClose`) keeps it full screen.
    private func restoreWindow() {
        guard onClose != nil, run.beganWindowed == true else { return }
        _ = LinuxDisplay.leaveFullscreen(window)
    }

    /// Notes a finished movie or episode in the ledger behind Rate What You Watched and the shows the viewer follows
    /// (`PlaybackSession.recordFinish`): an episode closed its season when the next one belongs to another season, and
    /// closed the show when there was nothing next; a playlist's entries close neither.
    private func recordFinish() {
        guard case .plex(_, let item, _) = source else { return }
        let kind: FinishedTitle.Kind
        switch item.mediaType {
        case "movie": kind = .movie
        case "episode": kind = .episode
        default: return
        }
        var endedShow = false
        var endedSeason = false
        if kind == .episode, run.queue == nil {
            switch nextKnown {
            case .offer(let offer):
                endedSeason = offer.episode.parentIndex != nil && offer.episode.parentIndex != item.parentIndex
            case .nothingNext:
                endedShow = true
            case nil:
                break
            }
        }
        FinishedTitlesLedger.shared.record(FinishedTitle(
            ratingKey: item.id, kind: kind, title: item.title, showTitle: item.grandparentTitle, showRatingKey: item.grandparentRatingKey,
            seasonNumber: item.parentIndex, episodeNumber: item.index, posterPath: item.thumb, showPosterPath: item.grandparentThumb,
            finishedAt: Date(), endedShow: endedShow, endedSeason: endedSeason, librarySectionID: item.librarySectionID
        ), server: ServerBootstrap.savedMachineIdentifier)
    }

    // MARK: Chrome

    func showChrome(autoHide: Bool) {
        guard preroll == nil else { return }
        chrome.set(1, animation: .fade)
        window?.setCursor(.default)
        startAnimating()
        hideTask?.cancel()
        guard autoHide, player?.state.isPaused == false, infoPanel == nil else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled, self.player?.state.isPaused == false, self.infoPanel == nil else { return }
            self.chrome.set(0, animation: .timed(duration: 0.4, curve: .easeInOut))
            self.window?.setCursor(.hidden)
            self.startAnimating()
        }
    }

    func holdChrome() {
        hideTask?.cancel()
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = chrome.advance(dt)
        transport.alpha = chrome.value
        transport.translation = Point(x: 0, y: (1 - chrome.value) * Theme.current.metrics.tv(40))
        setNeedsDisplay()
        return moving
    }

    // MARK: Input

    override func keyPressed(_ event: KeyEvent) -> Bool {
        guard let player else { return false }
        let modifiers = event.modifiers.subtracting(.shift)
        guard modifiers.isEmpty else { return false }
        let onPicture = window?.focusedView === self
        if !onPicture, [Key.left, .right, .up, .down, .return, .keypadEnter, .space].contains(event.key) { return false }
        viewerActed()
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
        case .up:
            player.setVolume(player.state.volume + 5)
        case .down:
            player.setVolume(player.state.volume - 5)
        case Key.character("m"):
            player.setMuted(!player.state.isMuted)
        case Key.character("s"), .return:
            if !skip.isHidden { skipSegment() } else { togglePause() }
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

    /// Left or Right: a press skips the distance Settings give that side; held, the side does what Settings say for a hold
    /// (scan, a jump from where the press began, start over or the next episode).
    private func press(forward: Bool, isRepeat: Bool) {
        let step = Double(forward ? Preferences.skipForwardSeconds : -Preferences.skipBackSeconds)
        guard isRepeat else {
            holdOrigin = playhead
            holdHandled = false
            seek(to: playhead + step)
            return
        }
        let action = forward ? Preferences.holdRightAction : Preferences.holdLeftAction
        switch action {
        case .scan:
            seek(to: playhead + (forward ? 2 : -2))
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

    override func pointerMoved(to point: Point) {
        showChrome(autoHide: !transport.frame.contains(point))
    }

    /// The gamepad's triggers scrub: the right one forward and the left one back, faster the further they are pulled, up to
    /// a minute and a half of the title each second, with a seek a few times a second while either is held.
    override func gamepadTriggered(left: Float, right: Float) -> Bool {
        guard player != nil else { return false }
        let pull = right - left
        triggerPull = abs(pull) > 0.12 ? pull : 0
        guard triggerPull != 0, triggerScrub == nil else { return true }
        viewerActed()
        showChrome(autoHide: true)
        triggerScrub = Task { [weak self] in
            var last = Window.now()
            while !Task.isCancelled, let self, self.triggerPull != 0 {
                try? await Task.sleep(for: .milliseconds(150))
                let now = Window.now()
                let pull = Double(self.triggerPull)
                self.seek(to: max(0, self.playhead + pull * abs(pull) * 90 * (now - last)))
                self.showChrome(autoHide: true)
                last = now
            }
            self?.triggerScrub = nil
        }
        return true
    }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        viewerActed()
        switch button {
        case .primary:
            let now = Date()
            if let lastClick, now.timeIntervalSince(lastClick) < 0.35, let window {
                window.setFullscreen(!window.isFullscreen)
                togglePause()
            } else {
                togglePause()
            }
            lastClick = now
            showChrome(autoHide: true)
            return true
        case .back:
            close()
            return true
        default:
            return false
        }
    }

    override func scrolled(_ event: ScrollEvent) -> Bool {
        let step: Double = event.isDiscrete ? Double(-event.notchesY + event.notchesX) * 5 : Double(-event.dy + event.dx) * 0.1
        guard step != 0 else { return true }
        viewerActed()
        seek(to: playhead - step)
        return true
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        followFullscreen()
        videoView?.frame = bounds
        preroll?.frame = bounds
        postPlay?.frame = bounds
        let width = min(frame.width - metrics.sideMargin * 2, metrics.tv(1600))
        let height = transport.sizeThatFits(Size(width: width, height: 0)).height
        transport.frame = Rect(x: ((frame.width - width) / 2).rounded(), y: frame.height - height - metrics.tv(48), width: width, height: height)
        if let infoPanel {
            let panelHeight = infoPanel.sizeThatFits(Size(width: width, height: 0)).height
            infoPanel.frame = Rect(x: transport.frame.x, y: transport.frame.y - panelHeight - metrics.tv(24), width: width, height: panelHeight)
        }
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

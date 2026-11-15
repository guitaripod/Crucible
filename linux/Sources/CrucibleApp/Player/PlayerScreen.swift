import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// The player (§7.5): the picture full window, a Liquid Glass transport that floats in on the pointer or a key and away
/// after three seconds of playing, Skip Intro and Skip Credits over the picture, and the server told where the playhead
/// is every ten seconds and whenever it stops or pauses.
///
/// Keys: Space or K play and pause, Left and Right or J and L ten seconds, Up and Down volume, M mute, S skip, F full
/// screen, Escape back. A click plays and pauses, a double click fills the screen, the wheel moves through the title.
@MainActor
final class PlayerScreen: View {
    /// What plays: a title on the Plex server from a position, or a local file (headless checks of the player itself).
    enum Source {
        case plex(APIClient, PlexMetadata, resume: Double)
        case file(URL, title: String)
    }

    var onClose: (() -> Void)?
    /// Plays the next episode in place of this one (Up Next, the media keys' Next).
    var onPlayNext: ((PlexMetadata) -> Void)?

    private let source: Source
    /// The player on screen, so quitting the app can stop it before its window and GPU go away.
    static weak var active: PlayerScreen?

    private var upNext: UpNextResolver?
    private var card: UpNextCard?
    private var offerTask: Task<Void, Never>?
    private var player: VideoPlayer?
    private var videoView: VideoView?
    private let transport = TransportView()
    private let skip = ButtonView(style: .glass, title: nil, symbol: "forward.end.fill", symbolTrailing: true)
    private let state = StateView()
    private var stream: ResolvedStream?
    private var streamOffset: Double = 0
    private var segments: [SkipMarker] = []
    private var chrome = Animated(1)
    private var hideTask: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?
    private var reportTask: Task<Void, Never>?
    private var lastReportedState: String?
    private var lastClick: Date?
    private var closed = false
    private var controls: MediaControls?

    init(source: Source) {
        self.source = source
        super.init()
        state.isHidden = true
        switch source {
        case .plex(_, let item, _): transport.title = item.grandparentTitle.map { "\($0) · \(item.title)" } ?? item.title
        case .file(_, let title): transport.title = title
        }
        transport.onSeek = { [weak self] fraction in self?.seek(toFraction: fraction) }
        transport.onTogglePause = { [weak self] in self?.player?.togglePause() }
        transport.onAudio = { [weak self] anchor in self?.showTracks(audio: true, anchor: anchor) }
        transport.onSubtitles = { [weak self] anchor in self?.showTracks(audio: false, anchor: anchor) }
        skip.isHidden = true
        skip.onPress = { [weak self] in self?.skipSegment() }
        addSubview(transport)
        addSubview(skip)
        addSubview(state)
    }

    override var canBecomeFocused: Bool { true }
    override var isPointerInteractive: Bool { true }
    override var cursor: Cursor { chrome.target > 0 ? .default : .hidden }
    override var preferredFocusView: View? { state.isHidden ? self : state }

    override func didMoveToWindow() {
        guard window != nil, player == nil, !closed else { return }
        start()
    }

    // MARK: Playback

    private func start() {
        guard let window, let loop = window.loop else { return }
        PlayerScreen.active = self
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
        } catch {
            fail(String(describing: error))
            return
        }
        state.isHidden = false
        state.show(.loading(title: nil))
        guard case .plex(let api, let item, let resumePosition) = source else {
            if case .file(let url, _) = source {
                player?.load(url)
                player?.setPaused(false)
                window.inhibitIdle(true)
                showDemoUpNextIfAsked()
            }
            return
        }
        resolveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await StreamResolver.resolve(api: api, ratingKey: item.id, startSecs: resumePosition,
                                                                selectedSubtitleId: nil, selectedAudioStreamId: nil, honorsServerSelection: true)
                guard !Task.isCancelled, !closed else { return }
                load(resolved)
            } catch {
                guard !Task.isCancelled else { return }
                fail(ConnectionError.message(for: error))
            }
        }
    }

    private func load(_ resolved: ResolvedStream, from requested: Double? = nil) {
        guard case .plex(let api, let item, let resumePosition) = source else { return }
        stream = resolved
        segments = resolved.segments
        let start = ResumeStrategy.streamStart(resumePosition: requested ?? resumePosition, isDirectPlay: resolved.isDirectPlay)
        streamOffset = resolved.isDirectPlay ? 0 : start
        upNext = UpNextResolver(ratingKey: item.id, isEpisode: item.mediaType == "episode", seasonRatingKey: item.parentRatingKey,
                                showRatingKey: item.grandparentRatingKey, markers: resolved.markers)
        let headers = PlexHeaders.allHeaders(token: api.token)
        player?.load(resolved.url, start: resolved.isDirectPlay ? start : 0, headers: headers)
        player?.setPaused(false)
        window?.inhibitIdle(true)
        MidgarLog.notice("Playing \(item.id) \(resolved.isDirectPlay ? "directly" : "converted") from \(Int(start)) s", category: .playback)
        startReporting()
    }

    private var position: Double { (player?.state.position ?? 0) + streamOffset }

    private var duration: Double {
        if case .plex(_, let item, _) = source, item.durationSecs > 0 { return item.durationSecs }
        return (player?.state.duration ?? 0) + streamOffset
    }

    private func stateChanged(_ playerState: VideoPlayer.State) {
        if !state.isHidden, playerState.videoWidth > 0 { state.isHidden = true }
        transport.update(position: position, duration: duration, buffered: playerState.cachedSeconds, paused: playerState.isPaused,
                         buffering: playerState.isBuffering)
        updateSkip()
        if var resolver = upNext, card == nil, resolver.creditsReached(at: position) {
            upNext = resolver
            offerNext(.credits)
        }
        controls?.update(playing: !playerState.isPaused, title: transport.title, show: showTitle, artURL: nil, duration: duration, position: position,
                         canGoNext: upNext?.canOfferNext ?? false)
        let reportState = playerState.isPaused ? "paused" : "playing"
        if reportState != lastReportedState { report(reportState) }
        if playerState.isPaused { showChrome(autoHide: false) }
        setNeedsDisplay()
    }

    private func handle(_ event: VideoPlayer.Event) {
        switch event {
        case .loaded, .seeked:
            break
        case .ended:
            if let card, card.offer.autoplays || card.offer.playbackEnded { return }
            if card != nil { dismissCard() }
            offerNext(.playbackEnded)
        case .failed(let message):
            fail(message)
        }
    }

    private func fail(_ message: String) {
        state.isHidden = false
        state.show(.error(title: String(localized: "Couldn’t Play This Title"), message: message, retryTitle: String(localized: "Back"),
                          retry: { [weak self] in self?.close() }))
        window?.focus.focus(state, animated: false)
    }

    private func seek(toFraction fraction: Float) {
        guard duration > 0 else { return }
        seek(to: Double(fraction) * duration)
    }

    // MARK: Up Next

    /// Asks for the next episode; shows the card, or plays at once when asked for, or leaves at the end with none.
    private func offerNext(_ reason: UpNextOffer.Reason) {
        guard let resolver = upNext, case .plex(let api, _, _) = source else {
            if reason == .playbackEnded { close() }
            return
        }
        offerTask?.cancel()
        offerTask = Task { [weak self] in
            let offer = try? await resolver.loadOffer(api: api, reason: reason)
            guard let self, !Task.isCancelled, !self.closed else { return }
            guard let offer else {
                if reason == .playbackEnded { self.close() }
                return
            }
            if reason == .requested {
                self.playNext(offer.episode)
            } else {
                self.show(offer)
            }
        }
    }

    private func show(_ offer: UpNextOffer) {
        card?.removeFromSuperview()
        let next = UpNextCard(offer: offer)
        next.onPlay = { [weak self] in self?.playNext(offer.episode) }
        next.onLeave = { [weak self] in
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

    private func dismissCard() {
        card?.stopCounting()
        card?.removeFromSuperview()
        card = nil
        window?.focus.focus(self, animated: false)
    }

    /// Ends this playback (the server hears it stopped) and hands the next episode on.
    private func playNext(_ episode: PlexMetadata) {
        let hand = onPlayNext
        onClose = nil
        close()
        hand?(episode)
    }

    // MARK: Tracks

    /// The Audio or Subtitles menu: the file's streams with the one playing checked. A file playing directly switches in
    /// place; a converted stream is asked for again from where it is, with the new choice.
    private func showTracks(audio: Bool, anchor: Rect) {
        guard let window, let stream else { return }
        let streams = audio ? stream.audioTracks : stream.subtitles
        let chosen = audio ? stream.chosenAudioStreamId : stream.chosenSubtitleId
        var items = streams.enumerated().map { index, track in
            MenuView.Item(id: "\(track.id ?? -1)", title: track.displayTitle ?? track.title ?? track.language ?? "\(index + 1)",
                          detail: track.title.flatMap { $0 == track.displayTitle ? nil : $0 }, isChecked: track.id == chosen)
        }
        if !audio { items.insert(MenuView.Item(id: "off", title: String(localized: "Off"), isChecked: chosen == nil), at: 0) }
        let menu = MenuView(title: audio ? String(localized: "Audio") : String(localized: "Subtitles"), items: items, anchor: anchor)
        menu.onSelect = { [weak self] item in self?.choose(track: item.id == "off" ? nil : Int(item.id), audio: audio) }
        menu.present(in: window)
        hideTask?.cancel()
    }

    private func choose(track id: Int?, audio: Bool) {
        guard let stream, case .plex(let api, let item, _) = source else { return }
        if stream.isDirectPlay {
            let streams = audio ? stream.audioTracks : stream.subtitles
            if audio {
                if let index = streams.firstIndex(where: { $0.id == id }) { player?.setAudioTrack(index + 1) }
            } else if let id, let track = streams.first(where: { $0.id == id }) {
                if let key = track.key, var components = URLComponents(url: stream.url, resolvingAgainstBaseURL: false) {
                    components.path = key
                    components.query = nil
                    guard let url = components.url else { return }
                    player?.addSubtitle(url, title: track.displayTitle)
                } else {
                    let embedded = streams.filter { $0.key == nil }
                    if let index = embedded.firstIndex(where: { $0.id == id }) { player?.setSubtitleTrack(index + 1) }
                }
            } else {
                player?.setSubtitleTrack(nil)
            }
            self.stream = ResolvedStream(url: stream.url, isDirectPlay: true, sessionId: stream.sessionId, subtitles: stream.subtitles,
                                         audioTracks: stream.audioTracks, markers: stream.markers, media: stream.media, decision: stream.decision,
                                         chapters: stream.chapters, chosenSubtitleId: audio ? stream.chosenSubtitleId : id,
                                         chosenAudioStreamId: audio ? id : stream.chosenAudioStreamId, segments: stream.segments)
            return
        }
        let resumeAt = position
        let subtitle = audio ? stream.chosenSubtitleId : id
        let audioId = audio ? id : stream.chosenAudioStreamId
        resolveTask?.cancel()
        resolveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await StreamResolver.resolve(api: api, ratingKey: item.id, startSecs: resumeAt, selectedSubtitleId: subtitle,
                                                                selectedAudioStreamId: audioId)
                guard !Task.isCancelled, !closed else { return }
                load(resolved, from: resumeAt)
            } catch {
                MidgarLog.error("Switching tracks failed: \(error)", category: .playback)
            }
        }
    }

    private var showTitle: String? {
        if case .plex(_, let item, _) = source { return item.grandparentTitle }
        return nil
    }

    private func perform(_ command: MediaControls.Command) {
        guard let player else { return }
        switch command {
        case .playPause: player.togglePause()
        case .play: player.setPaused(false)
        case .pause: player.setPaused(true)
        case .stop: close()
        case .seek(let offset): seek(to: position + offset)
        case .setPosition(let target): seek(to: target)
        case .next: offerNext(.requested)
        case .previous, .raise: break
        }
    }

    private func seek(to absolute: Double) {
        let target = min(max(absolute, 0), max(duration - 1, 0))
        player?.seek(to: target - streamOffset)
        controls?.seeked(to: target)
        showChrome(autoHide: true)
    }

    private func updateSkip() {
        let now = position
        if let segment = segments.first(where: { now >= $0.startSecs && now < $0.endSecs - 1 }) {
            skip.title = segment.title
            if skip.isHidden {
                skip.isHidden = false
                setNeedsLayout()
            }
        } else if !skip.isHidden {
            skip.isHidden = true
        }
    }

    private func skipSegment() {
        let now = position
        guard let segment = segments.first(where: { now >= $0.startSecs && now < $0.endSecs }) else { return }
        if segment.isCredits && segment.endSecs >= duration - 2 {
            close()
        } else {
            seek(to: segment.endSecs)
        }
    }

    // MARK: Timeline

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

    private func report(_ playbackState: String) {
        guard stream != nil, duration > 0, case .plex(let api, let item, _) = source else { return }
        lastReportedState = playbackState
        let endpoint = PlexEndpoint.timeline(ratingKey: item.id, state: playbackState, timeMs: Int(position * 1000), durationMs: Int(duration * 1000))
        Task {
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
        resolveTask?.cancel()
        reportTask?.cancel()
        hideTask?.cancel()
        offerTask?.cancel()
        card?.stopCounting()
        report("stopped")
        if let stream, !stream.isDirectPlay, case .plex(let api, _, _) = source {
            let session = stream.sessionId
            Task { try? await api.requestVoid(.stopTranscode(session: session)) }
        }
        player?.stop()
        player?.shutDown()
        player = nil
        controls?.close()
        controls = nil
        window?.inhibitIdle(false)
        window?.setCursor(.default)
        onClose?()
    }

    // MARK: Chrome

    private func showChrome(autoHide: Bool) {
        chrome.set(1, animation: .fade)
        window?.setCursor(.default)
        startAnimating()
        hideTask?.cancel()
        guard autoHide, player?.state.isPaused == false else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled, self.player?.state.isPaused == false else { return }
            self.chrome.set(0, animation: .timed(duration: 0.4, curve: .easeInOut))
            self.window?.setCursor(.hidden)
            self.startAnimating()
        }
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
        switch event.key {
        case .space, Key.character("k"):
            player.togglePause()
        case .left, Key.character("j"):
            seek(to: position - 10)
        case .right, Key.character("l"):
            seek(to: position + 10)
        case .up:
            player.setVolume(player.state.volume + 5)
        case .down:
            player.setVolume(player.state.volume - 5)
        case Key.character("m"):
            player.setMuted(!player.state.isMuted)
        case Key.character("s"), .return:
            if !skip.isHidden { skipSegment() } else { player.togglePause() }
        case Key.character("a"):
            showTracks(audio: true, anchor: transport.frameInWindow)
        case Key.character("c"):
            showTracks(audio: false, anchor: transport.frameInWindow)
        case Key.character("f"), .f11:
            if let window { window.setFullscreen(!window.isFullscreen) }
        case .escape, .back:
            if card != nil { dismissCard() } else { close() }
        case Key.character("n"):
            offerNext(.requested)
        default:
            return false
        }
        showChrome(autoHide: true)
        return true
    }

    override func pointerMoved(to point: Point) {
        showChrome(autoHide: !transport.frame.contains(point))
    }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        switch button {
        case .primary:
            let now = Date()
            if let lastClick, now.timeIntervalSince(lastClick) < 0.35, let window {
                window.setFullscreen(!window.isFullscreen)
                player?.togglePause()
            } else {
                player?.togglePause()
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
        seek(to: position - step)
        return true
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        videoView?.frame = bounds
        state.frame = bounds
        let width = min(frame.width - metrics.sideMargin * 2, metrics.tv(1600))
        let height = transport.sizeThatFits(Size(width: width, height: 0)).height
        transport.frame = Rect(x: ((frame.width - width) / 2).rounded(), y: frame.height - height - metrics.tv(48), width: width, height: height)
        let size = skip.sizeThatFits(Size(width: 600, height: 200))
        skip.frame = Rect(x: frame.width - metrics.sideMargin - size.width, y: transport.frame.y - size.height - metrics.tv(32),
                          width: size.width, height: size.height)
        if let card {
            let cardSize = card.sizeThatFits(bounds.size)
            card.frame = Rect(x: frame.width - metrics.sideMargin - cardSize.width, y: transport.frame.y - cardSize.height - metrics.tv(32),
                              width: cardSize.width, height: cardSize.height)
        }
    }
}

/// The floating glass transport: the title, a scrubber with what is buffered, the time played and left, and play/pause.
@MainActor
final class TransportView: View {
    var title = "" { didSet { setNeedsDisplay() } }
    var onSeek: ((Float) -> Void)?
    var onTogglePause: (() -> Void)?
    var onAudio: ((Rect) -> Void)?
    var onSubtitles: ((Rect) -> Void)?

    /// The Audio and Subtitles buttons at the end of the title row, in this view's points.
    var audioButton: Rect {
        let metrics = Theme.current.metrics
        let side = metrics.tv(56)
        return Rect(x: frame.width - metrics.tv(48) - side * 2 - metrics.tv(16), y: metrics.tv(20), width: side, height: side)
    }

    var subtitlesButton: Rect {
        let metrics = Theme.current.metrics
        let side = metrics.tv(56)
        return Rect(x: frame.width - metrics.tv(48) - side, y: metrics.tv(20), width: side, height: side)
    }
    private var position: Double = 0
    private var duration: Double = 0
    private var buffered: Double = 0
    private var paused = true
    private var buffering = false
    private var hoverFraction: Float?
    private var scrubbing = false
    private var tone = GlassTone()

    func update(position: Double, duration: Double, buffered: Double, paused: Bool, buffering: Bool) {
        self.position = position
        self.duration = duration
        self.buffered = buffered
        self.paused = paused
        self.buffering = buffering
        setNeedsDisplay()
    }

    override var isPointerInteractive: Bool { true }
    override var cursor: Cursor { .default }

    override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: Theme.current.metrics.tv(150))
    }

    private var bar: Rect {
        let metrics = Theme.current.metrics
        let inset = metrics.tv(48)
        let playSize = metrics.tv(64)
        return Rect(x: inset + playSize + metrics.tv(32), y: frame.height - metrics.tv(52), width: frame.width - inset * 2 - playSize - metrics.tv(32),
                    height: metrics.tv(10))
    }

    private var playButton: Rect {
        let metrics = Theme.current.metrics
        let side = metrics.tv(64)
        return Rect(x: metrics.tv(48), y: bar.midY - side / 2, width: side, height: side)
    }

    private func fraction(at point: Point) -> Float {
        min(max((point.x - bar.x) / max(bar.width, 1), 0), 1)
    }

    override func pointerMoved(to point: Point) {
        hoverFraction = point.y > bar.y - Theme.current.metrics.tv(40) && point.x >= bar.x ? fraction(at: point) : nil
        if scrubbing { onSeek?(fraction(at: point)) }
        setNeedsDisplay()
    }

    override func pointerExited() {
        hoverFraction = nil
        setNeedsDisplay()
    }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard button == .primary else { return false }
        if playButton.insetBy(-8, -8).contains(point) {
            onTogglePause?()
            return true
        }
        if audioButton.insetBy(-6, -6).contains(point) {
            onAudio?(transformToWindow.apply(audioButton))
            return true
        }
        if subtitlesButton.insetBy(-6, -6).contains(point) {
            onSubtitles?(transformToWindow.apply(subtitlesButton))
            return true
        }
        if point.x >= bar.x - 8 {
            scrubbing = true
            onSeek?(fraction(at: point))
        }
        return true
    }

    override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        scrubbing = false
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    override func draw(_ context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        guard let scale = window?.scale else { return }
        if tone.update(context, rect: bounds) { startAnimating() }
        GlassStyle.capsule(in: bounds, radius: metrics.radiusL, light: Point(x: bounds.midX, y: bounds.minY - bounds.height), floating: true,
                           tone: tone.value, context: &context)
        let label = GlassStyle.label(tone: tone.value)
        let secondary = GlassStyle.secondaryLabel(tone: tone.value)
        let titleLayout = TextLayout(title, font: theme.type.headline, maxWidth: audioButton.minX - metrics.tv(72), scale: scale)
        context.text(titleLayout, at: Point(x: metrics.tv(48), y: metrics.tv(28)), color: label)
        for (button, glyph) in [(audioButton, Symbol("waveform")), (subtitlesButton, Symbol("captions.bubble"))] {
            context.symbol(glyph, in: button.insetBy(button.width * 0.22, button.height * 0.22), color: label)
        }
        let symbol: Symbol = paused ? "play.fill" : "pause.fill"
        let play = playButton
        context.symbol(symbol, in: play.insetBy(play.width * 0.22, play.height * 0.22), color: label)
        let track = bar
        context.fill(track, radius: track.height / 2, color: label.withAlpha(0.22))
        if duration > 0 {
            let bufferedEnd = min((position + buffered) / duration, 1)
            context.fill(Rect(x: track.x, y: track.y, width: track.width * Float(bufferedEnd), height: track.height), radius: track.height / 2,
                         color: label.withAlpha(0.18))
            let played = Float(min(max(position / duration, 0), 1))
            context.fill(Rect(x: track.x, y: track.y, width: max(track.width * played, track.height), height: track.height), radius: track.height / 2,
                         color: theme.palette.accent)
            let knob = metrics.tv(22)
            context.fill(Rect(x: track.x + track.width * played - knob / 2, y: track.midY - knob / 2, width: knob, height: knob), radius: knob / 2,
                         color: .white)
            if let hoverFraction {
                let preview = TextLayout(Self.clock(Double(hoverFraction) * duration), font: theme.type.caption1, scale: scale)
                let x = track.x + track.width * hoverFraction - preview.size.width / 2
                context.text(preview, at: Point(x: x, y: track.y - preview.size.height - metrics.tv(14)), color: label)
            }
        }
        let elapsed = TextLayout(Self.clock(position), font: theme.type.caption1, scale: scale)
        let remaining = TextLayout("-" + Self.clock(max(duration - position, 0)), font: theme.type.caption1, scale: scale)
        context.text(elapsed, at: Point(x: track.x, y: track.maxY + metrics.tv(8)), color: secondary)
        context.text(remaining, at: Point(x: track.maxX - remaining.size.width, y: track.maxY + metrics.tv(8)), color: secondary)
        if buffering {
            let note = TextLayout(String(localized: "Buffering…"), font: theme.type.caption1, scale: scale)
            context.text(note, at: Point(x: track.midX - note.size.width / 2, y: track.maxY + metrics.tv(8)), color: secondary)
        }
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = tone.advance(dt)
        setNeedsDisplay()
        return moving
    }
}

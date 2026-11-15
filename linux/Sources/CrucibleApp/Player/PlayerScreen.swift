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

    private let source: Source
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
        do {
            let player = try VideoPlayer(gpu: window.gpu, loop: loop)
            let view = VideoView(player: player)
            insertSubview(view, at: 0)
            view.frame = bounds
            self.player = player
            videoView = view
            player.onStateChange = { [weak self] state in self?.stateChanged(state) }
            player.onEvent = { [weak self] event in self?.handle(event) }
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

    private func load(_ resolved: ResolvedStream) {
        guard case .plex(let api, let item, let resumePosition) = source else { return }
        stream = resolved
        segments = resolved.segments
        let start = ResumeStrategy.streamStart(resumePosition: resumePosition, isDirectPlay: resolved.isDirectPlay)
        streamOffset = resolved.isDirectPlay ? 0 : start
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
            close()
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

    private func seek(to absolute: Double) {
        let target = min(max(absolute, 0), max(duration - 1, 0))
        player?.seek(to: target - streamOffset)
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
        report("stopped")
        if let stream, !stream.isDirectPlay, case .plex(let api, _, _) = source {
            let session = stream.sessionId
            Task { try? await api.requestVoid(.stopTranscode(session: session)) }
        }
        player?.stop()
        player?.shutDown()
        player = nil
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
        case Key.character("f"), .f11:
            if let window { window.setFullscreen(!window.isFullscreen) }
        case .escape, .back:
            close()
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
    }
}

/// The floating glass transport: the title, a scrubber with what is buffered, the time played and left, and play/pause.
@MainActor
final class TransportView: View {
    var title = "" { didSet { setNeedsDisplay() } }
    var onSeek: ((Float) -> Void)?
    var onTogglePause: (() -> Void)?
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
        let titleLayout = TextLayout(title, font: theme.type.headline, maxWidth: bounds.width - metrics.tv(96), scale: scale)
        context.text(titleLayout, at: Point(x: metrics.tv(48), y: metrics.tv(28)), color: label)
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

import CrucibleCore
import CrucibleUI
import CrucibleWeb
import Foundation
import Kiln
import MidgarCore

/// One of the Shorts player's few players and the clip it holds: the one playing, the next one opened and held at its
/// first frame so a swipe shows it at once, or the one just left. It asks yt-dlp for the clip, picks the picture that
/// fits the pane, hands it to mpv, plays the next best stream when one is refused, and draws the clip's frames.
@MainActor
final class WebShortSlot {
    enum Phase: Equatable {
        case idle
        /// yt-dlp is being asked, or the site is about to serve the streams.
        case resolving
        /// mpv has the address and is opening it.
        case opening
        case open
        case failed(String)
    }

    let player: VideoPlayer
    private(set) var index: Int?
    private(set) var entry: WebEntry?
    private(set) var video: WebVideo?
    private(set) var phase = Phase.idle
    /// A frame of the clip it holds has been drawn.
    private(set) var hasPicture = false
    /// Whether the clip plays as soon as it can, or waits at its first frame.
    var plays = false {
        didSet {
            guard plays != oldValue else { return }
            player.progressInterval = plays ? 0 : 0.5
            player.setLater("demuxer-readahead-secs", plays ? "30" : "6")
            if phase == .open || phase == .opening { player.setPausedLater(!plays) }
        }
    }
    /// Whether a clip that ends starts over, or says so and waits (`onEnded`).
    var repeats = true {
        didSet { player.setLater("loop-file", repeats ? "inf" : "no") }
    }
    /// The phase, the playhead or the pause changed.
    var onChange: ((WebShortSlot) -> Void)?
    /// yt-dlp answered with the clip's facts.
    var onResolved: ((WebShortSlot, WebVideo) -> Void)?
    var onEnded: ((WebShortSlot) -> Void)?
    /// A frame is waiting; return whether the clip is on screen, where drawing it takes the frame.
    var onFrame: ((WebShortSlot) -> Bool)?

    private var texture: Texture?
    private var acceptsFrames = false
    private var owesFrame = false
    private var task: Task<Void, Never>?
    private var generation = 0
    private var refused: Set<String> = []
    private var selection: WebSelection?
    private var askedAgain = false
    private var pane: (width: Int, height: Int) = (0, 0)
    private var wantedSize: (width: Int, height: Int, since: Double)?
    private weak var window: Window?

    init(gpu: GPU, loop: EventLoop) throws(RenderError) {
        player = try VideoPlayer(gpu: gpu, loop: loop)
        player.progressInterval = 0.5
        player.setLater("loop-file", "inf")
        player.setLater("demuxer-readahead-secs", "6")
        player.setLater("sub-visibility", "no")
        player.audioFilters = Self.loudnessFilters
        player.onStateChange = { [weak self] _ in
            guard let self else { return }
            self.onChange?(self)
        }
        player.onEvent = { [weak self] event in self?.handle(event) }
        player.onFrame = { [weak self] in self?.frameArrived() }
    }

    /// Gives the slot `entry`, the clip at `index` of the feed, letting go of the one it held.
    func assign(_ entry: WebEntry, at index: Int) {
        clear()
        self.entry = entry
        self.index = index
    }

    /// Lets go of the clip: nothing plays and nothing is asked for.
    func clear() {
        generation += 1
        task?.cancel()
        task = nil
        if phase != .idle { player.commandLater(["stop"]) }
        entry = nil
        index = nil
        video = nil
        selection = nil
        refused = []
        askedAgain = false
        hasPicture = false
        acceptsFrames = false
        owesFrame = false
        plays = false
        phase = .idle
    }

    /// Opens the clip for a pane of `pane` pixels: from its file when it was downloaded, else through yt-dlp. `fresh` asks
    /// yt-dlp again, as after its stream addresses failed.
    func open(in window: Window, pane: (width: Int, height: Int), fresh: Bool = false) {
        guard let entry else { return }
        self.pane = pane
        self.window = window
        task?.cancel()
        set(.resolving)
        if let path = WebService.shared.library.download(of: entry.id)?.path, FileManager.default.fileExists(atPath: path) {
            start(location: path, userAgent: nil, headers: [:], caches: false)
            return
        }
        let token = generation
        task = Task { [weak self, weak window] in
            do {
                let video = try await WebService.shared.video(entry.url, fresh: fresh)
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.video = video
                self.onResolved?(self, video)
                await self.load(video, in: window, token: token)
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                MidgarLog.error("Reading a Short failed: \(error)", category: .playback)
                self.set(.failed(WebService.message(for: error)))
            }
        }
    }

    /// Chooses the streams that fit the pane and hands them to mpv, waiting first when the site holds them back.
    private func load(_ video: WebVideo, in window: Window?, token: Int) async {
        var preferences = WebService.shared.preferences(in: window, surround: false, excluded: refused)
        preferences.allowsHDR = false
        preferences.maximumHeight = WebShorts.heightLimit(of: video, paneWidth: pane.width, paneHeight: pane.height,
                                                          shortSide: WebSettings.quality.maximumHeight)
        guard let selection = WebFormatPicker.pick(from: video, preferences: preferences), let plan = WebPlaybackPlan(selection) else {
            set(.failed(String(localized: "yt-dlp found nothing to play in this video.", comment: "Web video error: no stream without protection")))
            return
        }
        self.selection = selection
        let wait = min(selection.readyAt?.timeIntervalSinceNow ?? 0, 10)
        if wait > 0.05 {
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000) + 200))
            guard !Task.isCancelled, generation == token else { return }
        }
        start(location: plan.location, userAgent: plan.userAgent ?? WebArtwork.userAgent, headers: plan.headers, caches: true)
        MidgarLog.notice("Playing a Short at \(selection.quality?.label ?? "its one quality")\(plays ? "" : ", held at its first frame")", category: .playback)
    }

    private func start(location: String, userAgent: String?, headers: [String: String], caches: Bool) {
        acceptsFrames = false
        hasPicture = false
        player.loadLater(location: location, headers: headers, userAgent: userAgent, paused: !plays, caches: caches)
        set(.opening)
    }

    /// Opens the clip again after it failed.
    func retry(in window: Window) {
        refused = []
        askedAgain = true
        open(in: window, pane: pane, fresh: true)
    }

    private func set(_ next: Phase) {
        guard next != phase else { return }
        phase = next
        onChange?(self)
    }

    private func handle(_ event: VideoPlayer.Event) {
        switch event {
        case .loaded:
            acceptsFrames = true
            set(.open)
        case .ended:
            if phase == .open { onEnded?(self) }
        case .failed(let message):
            recover(from: message)
        case .seeked:
            break
        }
    }

    /// A stream the site refuses gives way to the next best one; when none is left yt-dlp is asked again once, since the
    /// addresses it named may have run out, and a failure after that is said.
    private func recover(from message: String) {
        guard let video, let selection, let window else {
            set(.failed(message))
            return
        }
        refused.formUnion(selection.formats)
        var preferences = WebService.shared.preferences(in: window, surround: false, excluded: refused)
        preferences.allowsHDR = false
        if refused.count <= 6, WebFormatPicker.pick(from: video, preferences: preferences) != nil {
            MidgarLog.notice("A Short's stream failed (\(message)); playing the next best one", category: .playback)
            let token = generation
            task?.cancel()
            task = Task { [weak self, weak window] in await self?.load(video, in: window, token: token) }
            return
        }
        guard !askedAgain else {
            set(.failed(message))
            return
        }
        askedAgain = true
        refused = []
        MidgarLog.notice("A Short's streams failed (\(message)); asking yt-dlp again", category: .playback)
        open(in: window, pane: pane, fresh: true)
    }

    /// A frame the clip's page is not on screen to draw is let go, so mpv does not wait for it, and drawn once the page shows.
    private func frameArrived() {
        if acceptsFrames, onFrame?(self) == true { return }
        player.skipFrame()
        owesFrame = acceptsFrames
    }

    /// The clip's picture fitted into `pane` (the slot's page, in its points): the pane whole for an upright clip, a band
    /// across it for a wide one. Nil until mpv knows the picture's size.
    func pictureRect(in pane: Rect) -> Rect? {
        let state = player.state
        guard state.videoWidth > 0, state.videoHeight > 0 else { return nil }
        let fit = min(pane.width / Float(state.videoWidth), pane.height / Float(state.videoHeight))
        let width = (Float(state.videoWidth) * fit).rounded()
        let height = (Float(state.videoHeight) * fit).rounded()
        if abs(width - pane.width) <= 2 && abs(height - pane.height) <= 2 { return pane }
        return Rect(x: (pane.midX - width / 2).rounded(), y: (pane.midY - height / 2).rounded(), width: width, height: height)
    }

    /// Draws the newest frame into `rect`, rendering it first when one is waiting; returns whether a picture was drawn. The
    /// picture is rendered at the page's size at rest, so a page shrinking and growing as the feed moves scales the picture
    /// it has instead of holding back mpv's frames until a new size has rested.
    @discardableResult
    func draw(in rect: Rect, radius: Float, opacity: Float, context: inout DrawContext, window: Window) -> Bool {
        guard acceptsFrames else { return false }
        let width = max(Int((rect.width * context.rasterScale).rounded()), 1)
        let height = max(Int((rect.height * context.rasterScale).rounded()), 1)
        if texture?.width != width || texture?.height != height, texture == nil || sizeHeld(width, height, window: window) {
            texture = try? window.gpu.texture(width: width, height: height, format: .rgba16f, renderable: true)
            if let texture, player.render(into: texture) { hasPicture = true }
            owesFrame = false
        } else if player.hasNewFrame || owesFrame, let texture {
            if player.render(into: texture) { hasPicture = true }
            owesFrame = false
        }
        guard let texture, hasPicture else { return false }
        context.image(texture, in: rect, radius: radius, opacity: opacity, srgb: false)
        return true
    }

    /// Whether the pane has held a new size long enough to render at it: while a window edge is dragged the picture it
    /// has is scaled, and drawn at the exact size once the size rests.
    private func sizeHeld(_ width: Int, _ height: Int, window: Window) -> Bool {
        let now = Window.now()
        if wantedSize?.width != width || wantedSize?.height != height {
            wantedSize = (width, height, now)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak window] in
                MainActor.assumeIsolated { window?.setNeedsDisplay() }
            }
            return false
        }
        return now - (wantedSize?.since ?? now) >= 0.25
    }

    /// Moves the clip to `seconds` without waiting for mpv: on the keyframe nearest it while a drag is under way, else on
    /// the exact frame.
    func seek(to seconds: Double, exact: Bool = true) {
        player.commandLater(["seek", String(format: "%.3f", max(seconds, 0)), exact ? "absolute+exact" : "absolute+keyframes"])
    }

    func setMuted(_ muted: Bool) {
        player.setLater("mute", muted ? "yes" : "no")
    }

    /// Every clip brought to about one loudness, its peaks just under full scale: the normaliser lifts a quiet clip and lowers
    /// a loud one over a window of about a second either side, aiming its peaks at 0.85, and the limiter after it, run at
    /// four times the rate so it sees the peaks between samples too, holds them at 0.87. Measured on four NileRed Shorts
    /// that spanned -16.2 to -23.6 LUFS with true peaks up to +2.4 dBTP: -15.1 to -17.3 LUFS, true peaks -1.2 to -1.4 dBTP,
    /// for 0.6 s of CPU on a 71 s clip.
    static let loudnessFilters = [
        "@shortsloudness:lavfi=[dynaudnorm=f=150:g=15:p=0.85:m=12]",
        "@shortslimiter:lavfi=[aresample=192000,alimiter=limit=0.87:attack=5:release=80:asc=1:level=0,aresample=48000]",
    ]

    /// Stops the player for good.
    func shutDown() {
        generation += 1
        task?.cancel()
        onChange = nil
        onEnded = nil
        onFrame = nil
        onResolved = nil
        player.shutDown()
    }
}

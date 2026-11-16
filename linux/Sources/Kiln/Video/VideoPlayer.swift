import CKilnGPU
import Foundation

/// libmpv on Kiln's Vulkan device: decodes on the GPU, renders each frame with gpu-next into a texture in Kiln's linear
/// light, and reports position, duration, pause and buffering on the main actor.
@MainActor
public final class VideoPlayer {
    public struct State: Equatable, Sendable {
        public var position: Double = 0
        public var duration: Double = 0
        public var cachedSeconds: Double = 0
        public var volume: Double = 100
        public var isPaused = true
        public var isBuffering = false
        public var isSeeking = false
        public var isMuted = false
        public var videoWidth = 0
        public var videoHeight = 0
        public var hardwareDecoder = ""
    }

    public enum Event: Sendable {
        case loaded
        case seeked
        case ended
        case failed(String)
    }

    public private(set) var state = State()
    /// A new frame is waiting to be rendered.
    public private(set) var hasNewFrame = false
    public var onStateChange: ((State) -> Void)?
    public var onEvent: ((Event) -> Void)?
    public var onFrame: (() -> Void)?

    private let handle: OpaquePointer
    private let gpu: GPU
    private weak var loop: EventLoop?
    private var raw = kiln_video_state()

    public init(gpu: GPU, loop: EventLoop) throws(RenderError) {
        var error = [CChar](repeating: 0, count: 256)
        guard let handle = kiln_video_create(gpu.handle, &error, error.count) else {
            throw .device("mpv: " + error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
        }
        self.handle = handle
        self.gpu = gpu
        self.loop = loop
        loop.add(fd: kiln_video_wakeup_fd(handle)) { [weak self] readable in
            if readable { self?.poll() }
        }
    }

    /// Plays `url` from `start` seconds, sending `headers` with every request (the Plex token); `options` are mpv options
    /// for this file alone, such as the `aid` and `sid` it opens with.
    public func load(_ url: URL, start: Double = 0, headers: [String: String] = [:], options: KeyValuePairs<String, String> = [:]) {
        let fields = headers.map { "\($0.key): \($0.value)" }.joined(separator: ",")
        set("http-header-fields", fields)
        typicalSeekTime = nil
        seekSent = nil
        pendingSeek = nil
        var perFile = ["start=\(String(format: "%.3f", max(start, 0)))"]
        if url.isFileURL { perFile.append("cache=no") }
        perFile += options.map { "\($0.key)=\($0.value)" }
        command(["loadfile", url.isFileURL ? url.path : url.absoluteString, "replace", "-1", perFile.joined(separator: ",")])
    }

    /// An mpv property as text, or nil when mpv has none now.
    public func get(_ property: String) -> String? {
        var value = [CChar](repeating: 0, count: 512)
        guard kiln_video_get_property(handle, property, &value, value.count) else { return nil }
        return value.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// How many tracks of `type` ("video", "audio" or "sub") the open file carries itself, leaving out subtitles added beside it.
    public func fileTrackCount(_ type: String) -> Int {
        let count = get("track-list/count").flatMap(Int.init) ?? 0
        return (0..<count).filter { get("track-list/\($0)/type") == type && get("track-list/\($0)/external") != "yes" }.count
    }

    public func setPaused(_ paused: Bool) { set("pause", paused ? "yes" : "no") }

    public func togglePause() { setPaused(!state.isPaused) }

    /// How a seek lands: on the exact frame, or on the keyframe nearest it, which needs no decoding up to the target and so
    /// keeps a drag across the bar showing pictures.
    public enum SeekMode: Sendable {
        case exact, keyframe
    }

    /// Seeks to `seconds`. One seek is on its way at a time: one asked for meanwhile waits, and only the newest waiting one
    /// goes once mpv has landed (or after `seekPatience`, should it never say), so a drag never queues stale positions.
    public func seek(to seconds: Double, mode: SeekMode = .exact) {
        let target = (seconds: max(seconds, 0), mode: mode)
        if let sent = seekSent, sent.duration(to: .now) < Self.seekPatience {
            pendingSeek = target
            return
        }
        send(target)
    }

    /// How long a seek may take before the next one goes anyway, should mpv never say it landed; longer than the slowest
    /// real seek (a spinning disk behind a server), so each landing belongs to the seek sent last.
    private static let seekPatience: Duration = .seconds(2)
    private var seekSent: ContinuousClock.Instant?
    private var pendingSeek: (seconds: Double, mode: SeekMode)?

    private func send(_ target: (seconds: Double, mode: SeekMode)) {
        pendingSeek = nil
        let sent = ContinuousClock.now
        seekSent = sent
        command(["seek", String(format: "%.3f", target.seconds), target.mode == .exact ? "absolute+exact" : "absolute+keyframes"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.seekSent == sent else { return }
                self.seekLanded()
            }
        }
    }

    /// The seek on its way landed (or ran out of patience): the newest one waiting goes now.
    private func seekLanded() {
        if let seekSent { noteSeekTime(seekSent.duration(to: .now)) }
        seekSent = nil
        if let pendingSeek { send(pendingSeek) }
    }

    /// How long seeks take to land on this file lately, weighted toward the latest: a few tens of milliseconds from a fast
    /// disk, most of a second from a spinning one behind a server. Nil until a seek landed.
    public private(set) var typicalSeekTime: Duration?

    private func noteSeekTime(_ time: Duration) {
        typicalSeekTime = typicalSeekTime.map { $0 * 0.6 + time * 0.4 } ?? time
    }

    /// Steps one frame forward or back, pausing as mpv does.
    public func frameStep(forward: Bool) {
        command([forward ? "frame-step" : "frame-back-step"])
    }

    public func seek(by seconds: Double) {
        command(["seek", String(format: "%.3f", seconds), "relative+exact"])
    }

    /// The loudest the volume goes, in percent: 100 plays the file as it is, more amplifies it (mpv's volume-max).
    public var maximumVolume: Double = 100 {
        didSet { set("volume-max", String(format: "%.0f", maximumVolume)) }
    }

    public func setVolume(_ volume: Double) { set("volume", String(format: "%.0f", min(max(volume, 0), maximumVolume))) }

    public func setMuted(_ muted: Bool) { set("mute", muted ? "yes" : "no") }

    /// Selects audio track `id` (mpv's numbering, from 1), or turns audio off with nil.
    public func setAudioTrack(_ id: Int?) { set("aid", id.map(String.init) ?? "no") }

    /// Selects subtitle track `id` (mpv's numbering), or none.
    public func setSubtitleTrack(_ id: Int?) { set("sid", id.map(String.init) ?? "no") }

    /// Adds an external subtitle file or URL and selects it.
    public func addSubtitle(_ url: URL, title: String?) {
        command(["sub-add", url.absoluteString, "select", title ?? ""])
    }

    public func stop() { command(["stop"]) }

    @discardableResult
    public func command(_ arguments: [String]) -> Int32 {
        var pointers = arguments.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
                kiln_video_command(handle, $0)
            }
        }
    }

    @discardableResult
    public func set(_ property: String, _ value: String) -> Int32 {
        kiln_video_set_property(handle, property, value)
    }

    /// Renders the newest frame into `target` (a renderable FP16 texture); returns whether it drew.
    @discardableResult
    public func render(into target: Texture) -> Bool {
        hasNewFrame = false
        return kiln_video_render(handle, gpu.handle, target.handle)
    }

    public func reportSwap() { kiln_video_report_swap(handle) }

    private func poll() {
        let happened = kiln_video_poll(handle, &raw)
        if happened & UInt32(KILN_VIDEO_STATE) != 0 {
            var next = State()
            next.position = raw.position
            next.duration = raw.duration
            next.cachedSeconds = raw.cache_seconds
            next.volume = raw.volume
            next.isPaused = raw.paused
            next.isBuffering = raw.buffering
            next.isSeeking = raw.seeking
            next.isMuted = raw.muted
            next.videoWidth = Int(raw.width)
            next.videoHeight = Int(raw.height)
            next.hardwareDecoder = withUnsafeBytes(of: raw.hwdec) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if next != state {
                state = next
                onStateChange?(next)
            }
        }
        if happened & UInt32(KILN_VIDEO_LOADED) != 0 { onEvent?(.loaded) }
        if happened & UInt32(KILN_VIDEO_SEEKED) != 0 {
            seekLanded()
            onEvent?(.seeked)
        }
        if happened & UInt32(KILN_VIDEO_ENDED) != 0 { onEvent?(.ended) }
        if happened & UInt32(KILN_VIDEO_FAILED) != 0 {
            onEvent?(.failed(withUnsafeBytes(of: raw.error) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }))
        }
        if happened & UInt32(KILN_VIDEO_FRAME) != 0 {
            hasNewFrame = true
            onFrame?()
        }
    }

    /// Stops playback and frees libmpv; the player cannot be used after.
    public func shutDown() {
        loop?.remove(fd: kiln_video_wakeup_fd(handle))
        kiln_video_destroy(handle)
    }
}

/// The video picture: renders the player's frames into a texture at the view's pixel size and draws it fitted, with
/// black bars, in Kiln's linear light so HDR highlights pass through to the swapchain.
@MainActor
public final class VideoView: View {
    public let player: VideoPlayer
    private var texture: Texture?

    public init(player: VideoPlayer) {
        self.player = player
        super.init()
        player.onFrame = { [weak self] in self?.setNeedsDisplay() }
    }

    /// mpv draws into the whole view, bars included, so its own framing (zoom, pan, crop to fill, a forced shape, rotation)
    /// reaches the screen.
    public override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: .black)
        guard let window, player.state.videoWidth > 0, player.state.videoHeight > 0 else { return }
        let picture = bounds
        let pixels = context.transform.apply(picture)
        let width = max(Int(pixels.width.rounded()), 1)
        let height = max(Int(pixels.height.rounded()), 1)
        if texture?.width != width || texture?.height != height, texture == nil || sizeHeld(width, height) {
            texture = try? window.gpu.texture(width: width, height: height, format: .rgba16f, renderable: true)
            if let texture { player.render(into: texture) }
        } else if player.hasNewFrame, let texture {
            player.render(into: texture)
        }
        if let texture { context.image(texture, in: picture, srgb: false) }
    }

    private var wantedSize: (width: Int, height: Int, since: Double)?

    /// Whether the view has held a new size long enough to render at it. While a window edge is being dragged the size
    /// changes every frame, and a new texture each time would also make mpv rebuild its output at every size; the picture
    /// it has is scaled to the view meanwhile, and redrawn at the exact size once the size rests.
    private func sizeHeld(_ width: Int, _ height: Int) -> Bool {
        let now = Window.now()
        if wantedSize?.width != width || wantedSize?.height != height {
            wantedSize = (width, height, now)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.setNeedsDisplay() }
            }
            return false
        }
        return now - (wantedSize?.since ?? now) >= 0.25
    }
}

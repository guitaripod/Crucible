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

        /// Whether `self` differs from `other` in the playhead or the buffered amount alone, which move with every frame.
        public func onlyProgressDiffers(from other: State) -> Bool {
            var moved = self
            moved.position = other.position
            moved.cachedSeconds = other.cachedSeconds
            return moved == other && self != other
        }
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
    /// The least time in seconds between reports (`onStateChange`) that only move the playhead or the buffered amount;
    /// any other change reports at once, with the latest of both. 0 reports every frame, for a screen that shows the
    /// playhead; one that does not keeps each frame from drawing the window twice (once for the report, once for the
    /// picture).
    public var progressInterval: Double = 0
    private var lastReport: Double = 0
    /// Whether mpv's chroma upscaler was last set for a picture shown at half its size or smaller.
    private var chromaForShrinking: Bool?
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

    /// The loudest the volume goes, in percent: 100 plays the file as it is, more amplifies it. mpv applies its own volume
    /// after the audio filters, where nothing holds the peaks it lifts past full scale, so mpv's stops at 100% and the rest
    /// is a gain in the filters ahead of a limiter (`boostFilters`).
    public var maximumVolume: Double = 100 {
        didSet {
            guard maximumVolume != oldValue else { return }
            if volume > maximumVolume {
                setVolume(maximumVolume)
            } else {
                applyAudioFilters()
            }
        }
    }

    /// The sound's own filters, in mpv's `af` syntax; the volume boost's gain and limiter follow them while the volume may
    /// pass 100%.
    public var audioFilters: [String] = [] {
        didSet { applyAudioFilters() }
    }

    /// Whether the sound runs through any filter, so it has to be decoded here rather than passed through to a receiver.
    public var filtersSound: Bool { !audioFilters.isEmpty || maximumVolume > 100 }

    /// The volume asked for, in percent, which `state` reports: mpv plays up to 100% of it, the boost's gain the rest.
    private var volume: Double = 100
    /// The `af` list mpv was last given, so a volume change that leaves the boost's gain as it was rebuilds nothing.
    private var appliedAudioFilters: String?

    public func setVolume(_ volume: Double) {
        let level = min(max(volume, 0), maximumVolume).rounded()
        self.volume = level
        set("volume", String(format: "%.0f", min(level, 100)))
        applyAudioFilters()
        guard state.volume != level else { return }
        state.volume = level
        onStateChange?(state)
    }

    /// Hands mpv the sound's filters and, while the volume may pass 100%, the boost after them. mpv rebuilds only the
    /// filters whose settings changed, and the gain holds no samples, so a volume drag rebuilds it at every step without a
    /// gap or a click; a seek rebuilds every filter from this list, so the gain lives in it rather than being sent to the
    /// running filter, which would lose it at the next seek.
    private func applyAudioFilters() {
        var filters = audioFilters
        if maximumVolume > 100 { filters += Self.boostFilters(volume: volume) }
        let list = filters.joined(separator: ",")
        guard list != appliedAudioFilters, set("af", list) >= 0 else { return }
        appliedAudioFilters = list
    }

    /// Volume Boost's filters for `volume` percent: the gain past 100% on the cubic curve mpv's own volume follows below it
    /// (so a step sounds alike either side of 100%, and 200% is 8 times the amplitude), then a lookahead limiter holding the
    /// peaks at -1 dBFS with a release that adapts to dense passages, where clipping would flatten the voices and leave
    /// their echo as loud as they are.
    nonisolated static func boostFilters(volume: Double) -> [String] {
        let gain = pow(max(volume, 100) / 100, 3)
        return ["@boost:lavfi=[volume=\(String(format: "%.4f", gain))]",
                "@limiter:lavfi=[alimiter=limit=\(limiterCeiling):attack=5:release=150:asc=1:level=0]"]
    }

    /// The level the boost's limiter holds the peaks at: -1 dBFS, room for the overshoot between samples.
    nonisolated static let limiterCeiling = 0.891

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

    /// mpv brings a subsampled picture's colour planes up to the size of its brightness plane with its chroma upscaler
    /// (Lanczos by default) before it scales the picture into the view, a pass at the picture's full size. Shown at half
    /// its size or smaller, the picture's colour planes already hold as many samples as the view shows, so nothing that
    /// pass sharpens survives the shrinking: there a bilinear pass serves, which for 4K on a Steam Deck took most of mpv's
    /// GPU time and kept 60 fps titles near 40 fps. A picture shown larger keeps mpv's default.
    func fitChromaUpscaler(toWidth width: Int, height: Int) {
        guard state.videoWidth > 0, state.videoHeight > 0 else { return }
        let shrinking = Self.showsAtHalfOrLess(videoWidth: state.videoWidth, videoHeight: state.videoHeight, viewWidth: width, viewHeight: height)
        guard shrinking != chromaForShrinking else { return }
        chromaForShrinking = shrinking
        set("cscale", shrinking ? "bilinear" : "")
    }

    /// Whether a picture fitted into the view (as mpv fits it, whole and centred) shows at half its size or smaller.
    public nonisolated static func showsAtHalfOrLess(videoWidth: Int, videoHeight: Int, viewWidth: Int, viewHeight: Int) -> Bool {
        guard videoWidth > 0, videoHeight > 0 else { return false }
        let fit = min(Double(viewWidth) / Double(videoWidth), Double(viewHeight) / Double(videoHeight))
        return fit <= 0.5
    }

    private func poll() {
        let happened = kiln_video_poll(handle, &raw)
        if happened & UInt32(KILN_VIDEO_STATE) != 0 {
            var next = State()
            next.position = raw.position
            next.duration = raw.duration
            next.cachedSeconds = raw.cache_seconds
            next.volume = volume
            next.isPaused = raw.paused
            next.isBuffering = raw.buffering
            next.isSeeking = raw.seeking
            next.isMuted = raw.muted
            next.videoWidth = Int(raw.width)
            next.videoHeight = Int(raw.height)
            next.hardwareDecoder = withUnsafeBytes(of: raw.hwdec) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if next != state {
                let progressOnly = next.onlyProgressDiffers(from: state)
                state = next
                let now = Window.now()
                if !progressOnly || now - lastReport >= progressInterval {
                    lastReport = now
                    onStateChange?(next)
                }
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
        player.fitChromaUpscaler(toWidth: width, height: height)
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

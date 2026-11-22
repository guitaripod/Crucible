import CrucibleCore
import Foundation
import Kiln
import MidgarCore

/// Preview stills for the scrubber made here, for a file the server has made none for (one just added, a library with
/// video preview thumbnails off, another server's defaults): a second mpv with no sound and no subtitles opens the file
/// the first time the scrubber asks, stays paused, and seeks to the keyframe nearest each moment asked for, decoding that
/// one picture and drawing it small through the renderer the player uses, so HDR and Dolby Vision look as they do
/// playing. `LocalStillPlan` says where each seek goes: to where the scrubber points, else to its neighbours, else on
/// through an overview of the whole title, which is what a jump across a file on a slow disk shows at once while its own
/// still takes its second to arrive. The overview starts when the viewer first reaches for the controls (`prepare`). One
/// seek is on its way at a time, except that where the scrubber points never waits behind a still nobody is looking at:
/// its seek goes at once and takes the other's place.
@MainActor
final class LocalStillMaker {
    /// A still arrived, so the scrubber should draw again.
    var onChange: (() -> Void)?

    private let url: URL
    private let headers: [String: String]
    private let plan: LocalStillPlan
    private let aspect: Double
    private weak var window: Window?
    private var player: VideoPlayer?
    private var hasFailed = false
    private var stills: [Int: Texture] = [:]
    private var arrival: [Int] = []
    private var overview: [Int: Texture] = [:]
    private var unmakeable: Set<Int> = []
    private var inFlight: Int?
    /// Whether the seek on its way is for where the scrubber pointed when it went.
    private var inFlightIsPointed = false
    /// How many seeks went since a still was last kept: past one, a landing may be an overtaken seek's.
    private var outstanding = 0
    private var patience: Task<Void, Never>?
    /// Until when the playing title's own seek has the file, the decoder and the server's disk to itself.
    private var yieldsUntil: ContinuousClock.Instant?
    private var resumption: Task<Void, Never>?
    private var pointer: (slot: Int, at: ContinuousClock.Instant)?
    /// Stills drawn that the GPU has yet to finish, with when their seeks went.
    private var developing: [(slot: Int, still: Texture, sent: ContinuousClock.Instant)] = []
    private var development: Task<Void, Never>?
    private var sent = ContinuousClock.now
    private var made = 0

    /// How many stills stay in memory beside the overview's (about 460 KB each at 320 by 180 in the player's 16-bit
    /// linear light).
    private static let capacity = 96
    /// How wide a still is drawn, in pixels, as the server's own are.
    private static let width = 320
    /// How long after the scrubber last asked its place still counts as where it points.
    private static let pointerRest: Duration = .seconds(2)
    /// How far before the moment asked for a keyframe may lie and its picture still be taken for that seek's, in seconds,
    /// when another seek was overtaken and either may have landed.
    private static let keyframeReach = 60.0
    /// The longest the title's own seek is given way to before stills go on, should it never say it landed.
    private static let longestYield: Duration = .seconds(2)
    /// How long a landing that looked like an overtaken seek's is waited past before the picture mpv holds is taken.
    private static let overtakenPatience: Duration = .seconds(3)

    /// `width` and `height` are the picture's, for the shape of the stills; a file that does not say gets 16:9.
    init(url: URL, headers: [String: String], duration: Double, width: Int?, height: Int?, window: Window?) {
        self.url = url
        self.headers = headers
        plan = LocalStillPlan(duration: duration)
        hasFailed = duration <= 0
        if let width, let height, width > 0, height > 0 {
            aspect = Double(width) / Double(height)
        } else {
            aspect = 16.0 / 9.0
        }
        self.window = window
    }

    isolated deinit {
        patience?.cancel()
        resumption?.cancel()
        development?.cancel()
        player?.onEvent = nil
        player?.onFrame = nil
        player?.onStateChange = nil
        player?.shutDown()
    }

    /// The viewer reached for the controls: the file is opened and its overview begun, so the scrubber has stills to
    /// show by the time it is pointed at.
    func prepare() {
        guard !hasFailed, inFlight == nil else { return }
        makeNext()
    }

    /// The title playing seeks: nothing more is asked of the file until that has landed, so a still nobody may need never
    /// slows the picture the viewer is waiting for. A drag the picture follows is one seek after another, and the picture
    /// itself is the preview then.
    func titleSeekBegan() {
        yieldsUntil = .now + Self.longestYield
        resumption?.cancel()
        resumption = Task { [weak self] in
            try? await Task.sleep(for: Self.longestYield)
            guard !Task.isCancelled else { return }
            self?.titleSeekLanded()
        }
    }

    func titleSeekLanded() {
        guard yieldsUntil != nil else { return }
        yieldsUntil = nil
        resumption?.cancel()
        if player != nil, inFlight == nil { makeNext() }
    }

    private var isYielding: Bool {
        yieldsUntil.map { $0 > .now } ?? false
    }

    /// The still for `seconds` into the title, or the nearest one held while it is made; nil when there is none to show.
    func still(at seconds: Double) -> Texture? {
        guard !hasFailed else { return nil }
        let slot = plan.slot(at: seconds)
        pointer = (slot, .now)
        if let held = held(slot) {
            if inFlight == nil { makeNext() }
            return held
        }
        if inFlight == nil {
            makeNext()
        } else if !inFlightIsPointed, inFlight != slot, !unmakeable.contains(slot), !isYielding {
            make(slot, isPointed: true)
        }
        let near = stills.keys.filter { abs($0 - slot) <= plan.standInReach } + overview.keys.filter { abs($0 - slot) <= plan.standInReach }
        return near.min { abs($0 - slot) < abs($1 - slot) }.flatMap(held)
    }

    private func held(_ slot: Int) -> Texture? {
        stills[slot] ?? overview[slot]
    }

    /// Sends mpv to the slot the plan gives next, if any is left to make.
    private func makeNext() {
        guard !isYielding else { return }
        let pointed = pointer.flatMap { $0.at.duration(to: .now) < Self.pointerRest ? $0.slot : nil }
        let isSettled = { (slot: Int) in self.held(slot) != nil || self.unmakeable.contains(slot) || self.developing.contains { $0.slot == slot } }
        guard let slot = plan.next(pointer: pointed, isSettled: isSettled) else { return }
        make(slot, isPointed: slot == pointed)
    }

    /// Sends mpv to `slot`, opening the file there the first time. A seek already on its way is overtaken.
    private func make(_ slot: Int, isPointed: Bool) {
        let moment = plan.moment(of: slot)
        sent = .now
        inFlightIsPointed = isPointed
        patience?.cancel()
        patience = nil
        if let player {
            inFlight = slot
            outstanding += 1
            player.commandLater(["seek", String(format: "%.3f", moment), "absolute+keyframes"])
            return
        }
        guard let opened = open(at: moment) else {
            hasFailed = true
            return
        }
        player = opened
        inFlight = slot
        outstanding = 1
    }

    /// An mpv that only ever shows single keyframes: no sound, no subtitles, no reading ahead of the picture it shows. It
    /// decodes as the player does, on the GPU where that works: a 4K HEVC keyframe takes 19 ms there against 69 ms in
    /// software on the desktop.
    private func open(at moment: Double) -> VideoPlayer? {
        guard let window, let loop = window.loop else { return nil }
        let player: VideoPlayer
        do {
            player = try VideoPlayer(gpu: window.gpu, loop: loop)
        } catch {
            MidgarLog.error("Scrub stills: no player to make them here: \(error)", category: .playback)
            return nil
        }
        let options: KeyValuePairs<String, String> = [
            "pause": "yes", "aid": "no", "sid": "no", "hr-seek": "no", "cache": "no",
            "demuxer-max-bytes": "8MiB", "demuxer-max-back-bytes": "0", "demuxer-readahead-secs": "0",
            "vd-lavc-threads": "2", "vd-lavc-skiploopfilter": "all", "vd-lavc-fast": "yes", "cscale": "bilinear",
        ]
        for (name, value) in options { player.set(name, value) }
        player.onFrame = { [weak self] in self?.letGo() }
        player.onStateChange = { [weak self] _ in self?.positionMoved() }
        player.onEvent = { [weak self] event in
            switch event {
            case .seeked: self?.landed()
            case .failed(let reason): self?.fail(reason)
            case .loaded, .ended: break
            }
        }
        player.load(url, start: moment, headers: headers)
        MidgarLog.info("Scrub stills: none on the server, making them here", category: .playback)
        return player
    }

    /// mpv has a picture, which may still be the one from before the seek: it is let go undrawn, since mpv holds its next
    /// step a fifth of a second for a picture nobody takes, and drawn once the seek has landed.
    private func letGo() {
        player?.skipFrame()
    }

    /// Draws the picture mpv holds now into a new still; nil when mpv did not draw.
    private func drawStill() -> Texture? {
        guard let player, let window else { return nil }
        let height = max(Int((Double(Self.width) / aspect).rounded()), 1)
        guard let still = try? window.gpu.texture(width: Self.width, height: height, format: .rgba16f, renderable: true),
              player.render(into: still) else { return nil }
        return still
    }

    /// A seek landed, which mpv says once the picture there is the one it holds. After a seek was overtaken the landing
    /// may be either's, so the picture has to lie where a keyframe for the newest would. One that does not is the
    /// overtaken seek's, or mpv has yet to say where it is: the newest's is then waited for, or word of the position
    /// (`positionMoved`), though not for long, since mpv may have run only the newest and a file's keyframes may lie far apart.
    private func landed() {
        guard let slot = inFlight else { return }
        guard outstanding > 1, !isWhereKeyframeWouldBe(for: slot) else {
            settle(slot)
            return
        }
        outstanding = 1
        patience = Task { [weak self] in
            try? await Task.sleep(for: Self.overtakenPatience)
            guard !Task.isCancelled else { return }
            self?.settle(slot)
        }
    }

    /// mpv says where it is: a landing held back for want of that is taken now if it is the newest seek's.
    private func positionMoved() {
        guard patience != nil, let slot = inFlight, isWhereKeyframeWouldBe(for: slot) else { return }
        settle(slot)
    }

    /// Whether the picture mpv holds lies where a keyframe for `slot`'s moment would.
    private func isWhereKeyframeWouldBe(for slot: Int) -> Bool {
        guard let position = player?.state.position else { return false }
        let moment = plan.moment(of: slot)
        return position >= moment - Self.keyframeReach && position <= moment + plan.interval
    }

    /// Draws the picture mpv holds as `slot`'s still and sends mpv where the plan says next. The still is kept once the
    /// GPU has finished it (`develop`), so the scrubber never waits for one.
    private func settle(_ slot: Int) {
        guard inFlight == slot else { return }
        patience?.cancel()
        patience = nil
        inFlight = nil
        outstanding = 0
        if let still = drawStill() {
            developing.append((slot, still, sent))
            develop()
        } else {
            unmakeable.insert(slot)
        }
        makeNext()
    }

    /// Keeps the stills the GPU has finished, and looks again shortly while any is still being drawn.
    private func develop() {
        development?.cancel()
        let ready = developing.filter { $0.still.isVideoDrawn }
        developing.removeAll { $0.still.isVideoDrawn }
        for entry in ready { keep(entry.still, at: entry.slot, sent: entry.sent) }
        guard !developing.isEmpty else { return }
        development = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2))
            guard !Task.isCancelled else { return }
            self?.develop()
        }
    }

    /// The overview's stills stay for as long as the title plays; of the others the oldest go once there are `capacity`.
    private func keep(_ still: Texture, at slot: Int, sent: ContinuousClock.Instant) {
        if plan.overview.contains(slot) {
            overview[slot] = still
            stills[slot] = nil
        } else {
            if stills.updateValue(still, forKey: slot) == nil { arrival.append(slot) }
            while arrival.count > Self.capacity {
                stills[arrival.removeFirst()] = nil
            }
        }
        made += 1
        if made == 1 || made % 50 == 0 {
            let elapsed = sent.duration(to: .now).components
            let milliseconds = Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
            MidgarLog.info("Scrub stills: \(made) made here, the last in \(milliseconds) ms", category: .playback)
        }
        onChange?()
    }

    private func fail(_ reason: String) {
        MidgarLog.notice("Scrub stills: could not be made here: \(reason)", category: .playback)
        hasFailed = true
        inFlight = nil
        patience?.cancel()
        development?.cancel()
        developing = []
        player?.onEvent = nil
        player?.onFrame = nil
        player?.onStateChange = nil
        player?.shutDown()
        player = nil
    }
}

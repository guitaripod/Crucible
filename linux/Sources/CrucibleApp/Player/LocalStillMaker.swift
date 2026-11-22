import CrucibleCore
import Foundation
import Kiln
import MidgarCore

/// Preview stills for the scrubber made here, for a file the server has made none for (one just added, a library with
/// video preview thumbnails off, another server's defaults): a second mpv with no sound and no subtitles opens the file
/// the first time the scrubber asks, stays paused, and seeks to the keyframe nearest each moment asked for, decoding that
/// one picture in software and drawing it small through the renderer the player uses, so HDR and Dolby Vision look as
/// they do playing. The bar is divided into slots of `interval` seconds with one still each; one seek is on its way at a
/// time and the next goes to where the scrubber points then, so a drag asks for no stale moments.
@MainActor
final class LocalStillMaker {
    /// A still arrived, so the scrubber should draw again.
    var onChange: (() -> Void)?

    private let url: URL
    private let headers: [String: String]
    private let duration: Double
    private let aspect: Double
    private weak var window: Window?
    private var player: VideoPlayer?
    private var hasFailed = false
    private var stills: [Int: Texture] = [:]
    private var arrival: [Int] = []
    private var inFlight: Int?
    private var wanted: Int?
    private var canvas: Texture?
    private var sent = ContinuousClock.now
    private var made = 0

    /// How many stills stay in memory (about 720 KB each at 400 by 225 in the player's 16-bit linear light).
    private static let capacity = 80
    /// How wide a still is drawn, in pixels: the card over the scrubber is at most a little wider on a 4K screen.
    private static let width = 400
    /// The most slots a bar is divided into, which is more than a pointer can tell apart along it.
    private static let slots = 1000.0
    /// The shortest stretch of a title one still stands for, in seconds: keyframes rarely sit closer.
    private static let shortestInterval = 2.0

    /// `width` and `height` are the picture's, for the shape of the stills; a file that does not say gets 16:9.
    init(url: URL, headers: [String: String], duration: Double, width: Int?, height: Int?, window: Window?) {
        self.url = url
        self.headers = headers
        self.duration = duration
        if let width, let height, width > 0, height > 0 {
            aspect = Double(width) / Double(height)
        } else {
            aspect = 16.0 / 9.0
        }
        self.window = window
    }

    isolated deinit {
        player?.onEvent = nil
        player?.onFrame = nil
        player?.shutDown()
    }

    /// How many seconds of the title one still stands for.
    private var interval: Double { max(duration / Self.slots, Self.shortestInterval) }

    /// The still for `seconds` into the title, or the nearest one held while it is made; nil when there is none to show.
    func still(at seconds: Double) -> Texture? {
        guard duration > 0, !hasFailed else { return nil }
        let slot = Int(min(max(seconds, 0), duration) / interval)
        if let held = stills[slot] { return held }
        wanted = slot
        if inFlight == nil { make(slot) }
        let reach = max(Int(Double(ScrubStills.standInReach) / interval), 1)
        return ScrubStillQueue.standIn(for: slot, among: stills.keys, reach: reach).flatMap { stills[$0] }
    }

    /// Sends mpv to `slot`, opening the file there the first time.
    private func make(_ slot: Int) {
        let moment = min((Double(slot) + 0.5) * interval, max(duration - 1, 0))
        wanted = nil
        sent = .now
        if let player {
            inFlight = slot
            player.seek(to: moment, mode: .keyframe)
            return
        }
        guard let opened = open(at: moment) else {
            hasFailed = true
            return
        }
        player = opened
        inFlight = slot
    }

    /// An mpv that only ever shows single keyframes: no sound, no subtitles, software decoding (one picture at a time
    /// needs no decoder on the GPU, and takes none from the title playing), no reading ahead of the picture it shows.
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
            "pause": "yes", "aid": "no", "sid": "no", "hwdec": "no", "hr-seek": "no", "cache": "no",
            "demuxer-max-bytes": "8MiB", "demuxer-max-back-bytes": "0", "demuxer-readahead-secs": "0",
            "vd-lavc-threads": "2", "vd-lavc-skiploopfilter": "all", "vd-lavc-fast": "yes", "cscale": "bilinear",
        ]
        for (name, value) in options { player.set(name, value) }
        player.onFrame = { [weak self] in self?.draw() }
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

    /// mpv has a picture: it is drawn at once, since mpv holds its next step until it is. It may still be the one from
    /// before the seek, so nothing is kept until the seek has landed.
    private func draw() {
        guard inFlight != nil else { return }
        drawCanvas()
    }

    /// Draws the picture mpv holds now into the still being made; false when there is nothing to draw into or mpv did not.
    @discardableResult
    private func drawCanvas() -> Bool {
        guard let player, let window else { return false }
        if canvas == nil {
            let height = max(Int((Double(Self.width) / aspect).rounded()), 1)
            canvas = try? window.gpu.texture(width: Self.width, height: height, format: .rgba16f, renderable: true)
        }
        guard let canvas else { return false }
        return player.render(into: canvas)
    }

    /// The seek landed, which mpv says once the picture there is the one it holds: that picture is drawn again, whatever
    /// was drawn before, and kept as the slot's still; then mpv goes to where the scrubber points now.
    private func landed() {
        guard let slot = inFlight else { return }
        inFlight = nil
        if drawCanvas(), let still = canvas {
            canvas = nil
            keep(still, at: slot)
        }
        if let next = wanted, stills[next] == nil {
            make(next)
        } else {
            wanted = nil
        }
    }

    private func keep(_ still: Texture, at slot: Int) {
        if stills.updateValue(still, forKey: slot) == nil { arrival.append(slot) }
        while arrival.count > Self.capacity {
            stills[arrival.removeFirst()] = nil
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
        wanted = nil
        canvas = nil
        player?.onEvent = nil
        player?.onFrame = nil
        player?.shutDown()
        player = nil
    }
}

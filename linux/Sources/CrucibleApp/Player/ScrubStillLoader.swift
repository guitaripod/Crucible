import CrucibleCore
import Foundation
import Kiln
import MidgarCore

/// The playing file's preview stills for the scrubber (`ScrubStills`). The whole index (`BIFIndex`) is fetched once as the
/// player opens, so any point of the bar has its still at once; each is decoded and uploaded off the main thread the first
/// time it is shown, and the nearest one already held stands in for the moment that takes. A server without the whole
/// index is asked for one still at a time instead, and a file the server has made no stills for, or serves none of, has
/// them made here (`LocalStillMaker`). Nothing is written to the artwork cache: stills are throwaway.
@MainActor
final class ScrubStillLoader {
    /// A still arrived, so the scrubber should draw again.
    var onChange: (() -> Void)?

    let partID: Int
    private let api: APIClient
    private let fetch: ImageStore.Fetch
    private weak var window: Window?
    private var queue = ScrubStillQueue()
    private var stills: [Int: Texture] = [:]
    private var arrival: [Int] = []
    private var task: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var index: (data: Data, frames: BIFIndex)?
    private var indexFailed = false
    private var decoding: Int?
    private var wantedFrame: Int?
    /// Makes the stills here; nil for a file that cannot be (`local` stays nil then).
    private let makeLocal: () -> LocalStillMaker?
    private var local: LocalStillMaker?

    /// How many stills stay in memory (about 230 KB each at 320 by 180).
    private static let capacity = 120

    /// `hasServerStills` is whether the server says it has made the file's stills; without them, and when it turns out to
    /// serve none, `makeLocal` gives what makes them here.
    init(partID: Int, api: APIClient, window: Window?, hasServerStills: Bool, makeLocal: @escaping () -> LocalStillMaker?) {
        self.partID = partID
        self.api = api
        fetch = PlexArtworkPipeline.fetcher(token: api.token)
        self.window = window
        self.makeLocal = makeLocal
        if hasServerStills {
            loadIndex()
        } else {
            indexFailed = true
            useLocal()
        }
    }

    deinit {
        task?.cancel()
        indexTask?.cancel()
    }

    /// The still for `seconds` into the title, or the nearest one held while it loads; nil when there is none to show.
    func still(at seconds: Double) -> Texture? {
        if let local { return local.still(at: seconds) }
        if let index {
            guard let frame = index.frames.frame(at: seconds) else { return nil }
            if let held = stills[frame] { return held }
            want(frame)
            return ScrubStillQueue.standIn(for: frame, among: stills.keys, reach: standInFrames).flatMap { stills[$0] }
        }
        guard indexFailed else { return nil }
        let second = ScrubStills.second(seconds)
        let held = stills[second]
        if let next = queue.want(second, held: held != nil) { load(next) }
        if queue.isUnavailable, useLocal() { return local?.still(at: seconds) }
        if let held { return held }
        return ScrubStillQueue.standIn(for: second, among: stills.keys).flatMap { stills[$0] }
    }

    /// The viewer reached for the controls: stills made here are begun ahead of the scrubber asking.
    func prepare() {
        local?.prepare()
    }

    /// The title playing began a seek of its own, or that seek landed: stills made here give way to it meanwhile.
    func titleSeeks(_ isSeeking: Bool) {
        if isSeeking { local?.titleSeekBegan() } else { local?.titleSeekLanded() }
    }

    /// Turns to stills made here from now on; false when this file's cannot be.
    @discardableResult
    private func useLocal() -> Bool {
        guard local == nil, let maker = makeLocal() else { return local != nil }
        maker.onChange = { [weak self] in self?.onChange?() }
        local = maker
        return true
    }

    /// How many frames of the index a stand-in still may be from the one wanted: `ScrubStills.standInReach` seconds.
    private var standInFrames: Int {
        guard let frames = index?.frames.frames, frames.count > 1 else { return 1 }
        let interval = max(frames[1].seconds - frames[0].seconds, 1)
        return max(Int(Double(ScrubStills.standInReach) / interval), 1)
    }

    /// Fetches and reads the whole index off the main thread; a server that does not serve it leaves the scrubber asking
    /// for stills one at a time.
    private func loadIndex() {
        let api = api
        let path = String(ScrubStills.indexPath(partID: partID).dropFirst())
        let fetch = fetch
        indexTask = Task { [weak self] in
            let url = await api.baseURL.appendingPathComponent(path)
            let loaded: (Data, BIFIndex)? = await Task.detached(priority: .utility) {
                guard let data = try? await fetch(url), let frames = BIFIndex(data) else { return nil }
                return (data, frames)
            }.value
            guard !Task.isCancelled, let self else { return }
            if let loaded {
                self.index = loaded
                MidgarLog.info("Scrub stills: \(loaded.1.frames.count) in one index", category: .playback)
            } else {
                self.indexFailed = true
            }
            self.onChange?()
        }
    }

    /// Asks for `frame` of the index, one decode at a time: a frame asked for while another decodes waits, and only the
    /// newest waiting one is decoded next.
    private func want(_ frame: Int) {
        wantedFrame = frame
        guard decoding == nil else { return }
        decode(frame)
    }

    private func decode(_ frame: Int) {
        guard let index, let window, frame < index.frames.frames.count else { return }
        decoding = frame
        wantedFrame = nil
        let bytes = index.data[index.frames.frames[frame].bytes]
        let uploader = window.gpu.uploader
        task = Task { [weak self] in
            let detached: DetachedTexture? = await Task.detached(priority: .userInitiated) {
                guard let decoded = try? ImageDecoder.decode(Data(bytes)), let uploader else { return nil }
                return decoded.pixels.withUnsafeBytes {
                    uploader.rgba8(width: decoded.width, height: decoded.height, pixels: $0.baseAddress!, rowBytes: decoded.width * 4)
                }
            }.value
            guard !Task.isCancelled, let self, let gpu = self.window?.gpu else {
                if let detached { uploader?.discard(detached) }
                return
            }
            self.decoding = nil
            if let detached {
                self.keep(gpu.adopt(detached), at: frame)
                self.onChange?()
            }
            if let next = self.wantedFrame, self.stills[next] == nil { self.decode(next) }
        }
    }

    private func load(_ second: Int) {
        let api = api
        let path = String(ScrubStills.path(partID: partID, second: second).dropFirst())
        let fetch = fetch
        task = Task { [weak self] in
            let data = try? await fetch(api.baseURL.appendingPathComponent(path))
            guard !Task.isCancelled, let self else { return }
            let texture = data.flatMap { try? self.window?.images?.texture(from: $0) }
            if let texture { self.keep(texture, at: second) }
            if let next = self.queue.landed(texture != nil) { self.load(next) }
            if texture != nil { self.onChange?() }
        }
    }

    private func keep(_ texture: Texture, at key: Int) {
        if stills.updateValue(texture, forKey: key) == nil { arrival.append(key) }
        while arrival.count > Self.capacity {
            stills[arrival.removeFirst()] = nil
        }
    }
}

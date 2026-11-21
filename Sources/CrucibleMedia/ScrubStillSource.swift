#if canImport(UIKit)
import AVFoundation
import CrucibleCore
import Foundation
import MidgarCore
import UIKit

/// Where a scrubber's preview gets the picture for the moment it points at.
@MainActor
package protocol ScrubStillSource: AnyObject {
    /// A still arrived, so the preview should look again.
    var onChange: (() -> Void)? { get set }

    /// Whether the title has stills at all, as far as is known: false once a server has said it has none.
    var offersStills: Bool { get }

    /// The still for `seconds` into the title, or the nearest one held while it loads; nil when there is none to show.
    func still(at seconds: Double) -> ScrubStill?

    /// Playback is at `seconds`, the place a scrub is most likely to start from, so its still is worth having ready.
    func playheadMoved(to seconds: Double)
}

/// A still as a scrubber shows it: the picture, and whether it is the one for the moment asked or a neighbour standing in.
package struct ScrubStill {
    package let image: UIImage
    package let isExact: Bool
}

/// The decoded stills a source keeps in memory, the oldest dropped first (about 230 KB each at 320 by 180).
@MainActor
struct HeldStills {
    private static let capacity = 48

    private var images: [Int: UIImage] = [:]
    private var arrival: [Int] = []

    func holds(_ key: Int) -> Bool {
        images[key] != nil
    }

    mutating func keep(_ image: UIImage, at key: Int) {
        if images.updateValue(image, forKey: key) == nil { arrival.append(key) }
        while arrival.count > Self.capacity {
            images[arrival.removeFirst()] = nil
        }
    }

    /// The still at `key`, else the nearest one held within `reach` keys of it.
    func still(at key: Int, reach: Int) -> ScrubStill? {
        if let image = images[key] { return ScrubStill(image: image, isExact: true) }
        return ScrubStillQueue.standIn(for: key, among: images.keys, reach: reach).flatMap { images[$0] }.map { ScrubStill(image: $0, isExact: false) }
    }
}

/// A server's preview stills for the file being played (`ScrubStills`), held so that a scrub over a file on the far side
/// of a network shows its pictures as one over a file on the device would.
///
/// The header and table of the part's index come first, in one small ranged request, and say which bytes hold which
/// still. From then on stills travel in spans of neighbours: the spans around the playhead are fetched as playback goes,
/// the rest of the file fills in behind the picture where the network is free to use (never on mobile data, in Low Data
/// Mode or Low Power Mode, and never while the stream itself waits for data), and a scrub that reaches a span not yet
/// held fetches it at once, on any network, while the nearest still held stands in. The bytes go to a file in the
/// temporary directory, not to memory, and only the stills shown are decoded, off the main thread.
///
/// A server that answers a ranged request with the whole file is asked for one still at a time instead.
@MainActor
package final class ServerScrubStills: ScrubStillSource {
    package var onChange: (() -> Void)?
    /// Whether the stream being played is waiting for data, which the background fill stands aside for.
    package var isStreamStarved: (@MainActor () -> Bool)?

    package let partID: Int

    private enum Mode {
        case reading
        case spans(BIFIndex, StillFile)
        case single
        case none
    }

    /// How many stills travel in one request: a span is about 300 KB of a typical index, 48 seconds of a film.
    private static let spanSize = 24
    /// How many spans one request of the background fill asks for.
    private static let fillRun = 4
    /// How much of an index the background fill fetches: every still of all but the longest titles.
    private static let fillBudget = 48 << 20
    /// How much of the file the first request asks for: the table of any title up to four and a half hours.
    private static let headLength = 64 << 10

    private let api: APIClient
    private let session: URLSession
    private var mode = Mode.reading {
        didSet {
            if case .none = mode { onChange?() }
        }
    }
    private var held = HeldStills()
    private var loaded: Set<Int> = []
    private var fetching: [Int: Task<Bool, Never>] = [:]
    private var wanted: Int?
    private var isWorking = false
    private var playhead: Double?
    private var playheadSpan: Int?
    private var prepareTask: Task<Void, Never>?
    private var fillTask: Task<Void, Never>?
    private var fillEnded = false
    private var filled = 0
    private var queue = ScrubStillQueue()
    private let startedAt = ContinuousClock.now

    package init(api: APIClient, partID: Int) {
        self.api = api
        self.partID = partID
        session = HTTPSession.current
        prepareTask = Task { [weak self] in await self?.readIndex() }
    }

    deinit {
        prepareTask?.cancel()
        fillTask?.cancel()
        fetching.values.forEach { $0.cancel() }
    }

    package var offersStills: Bool {
        if case .none = mode { return false }
        return true
    }

    package func still(at seconds: Double) -> ScrubStill? {
        switch mode {
        case .reading, .none:
            return nil
        case .spans(let index, _):
            guard let frame = index.frame(at: seconds) else { return nil }
            if !held.holds(frame) { want(frame) }
            return held.still(at: frame, reach: max(Int(Double(ScrubStills.standInReach) / index.interval), 1))
        case .single:
            let second = ScrubStills.second(seconds)
            if let next = queue.want(second, held: held.holds(second)) { loadSingle(next) }
            return held.still(at: second, reach: ScrubStills.standInReach)
        }
    }

    package func playheadMoved(to seconds: Double) {
        playhead = seconds
        guard case .spans(let index, _) = mode, let frame = index.frame(at: seconds) else { return }
        if !held.holds(frame), !isWorking { want(frame) }
        let span = frame / Self.spanSize
        guard span != playheadSpan else { return }
        playheadSpan = span
        guard mayUseTheNetworkUnasked else { return }
        for near in [span, span + 1] where near < index.spanCount(size: Self.spanSize) && !loaded.contains(near) {
            _ = fetch(near..<near + 1, unasked: true)
        }
        startFilling()
    }

    // MARK: - The index

    /// Reads the header and table off the start of the index. The answer's status is looked at before its body, so a
    /// server that ignores the range and sends a whole index of tens of megabytes is hung up on.
    private func readIndex() async {
        let path = ScrubStills.indexPath(partID: partID)
        guard let (bytes, response) = try? await session.bytes(for: await request(path, range: 0..<Self.headLength)),
              let http = response as? HTTPURLResponse, !Task.isCancelled else { return }
        guard http.statusCode == 206 else {
            bytes.task.cancel()
            mode = http.statusCode == 200 ? .single : .none
            MidgarLog.info("Scrub stills: part \(partID) answered \(http.statusCode) to a ranged request, \(http.statusCode == 200 ? "asking for stills one at a time" : "none")", category: .playback)
            return
        }
        var head = Data()
        head.reserveCapacity(Self.headLength)
        do {
            for try await byte in bytes { head.append(byte) }
        } catch {
            return
        }
        guard let tableLength = BIFIndex.tableLength(header: head) else {
            mode = .none
            return
        }
        if head.count < tableLength {
            guard let rest = await data(path, range: head.count..<tableLength, unasked: false) else { return }
            head.append(rest)
        }
        guard !Task.isCancelled, let index = BIFIndex(table: head), let file = StillFile(length: index.length) else {
            mode = .none
            return
        }
        mode = .spans(index, file)
        MidgarLog.info("Scrub stills: part \(partID) has \(index.frames.count), one every \(Int(index.interval.rounded())) s, in \(index.length >> 10) KB", category: .playback)
        if let playhead { playheadMoved(to: playhead) }
        if wanted != nil { work() }
        onChange?()
    }

    // MARK: - Spans

    private func want(_ frame: Int) {
        wanted = frame
        work()
    }

    /// Fetches and decodes the still wanted, one at a time; a still asked for meanwhile waits, and only the newest one
    /// waiting is worked on next, so a fast scrub decodes where it is and not everywhere it has been.
    private func work() {
        guard !isWorking, let frame = wanted, case .spans(let index, let file) = mode else { return }
        wanted = nil
        guard !held.holds(frame), frame < index.frames.count else { return }
        isWorking = true
        let span = frame / Self.spanSize
        let bytes = index.frames[frame].bytes
        Task { [weak self] in
            let isHeld = await self?.hold(span) ?? false
            let image = isHeld ? await file.image(in: bytes) : nil
            guard let self else { return }
            isWorking = false
            if let image {
                held.keep(image, at: frame)
                onChange?()
            }
            work()
        }
    }

    /// Makes sure `span` is in the file, fetching it now if it is not; false when it could not be fetched.
    private func hold(_ span: Int) async -> Bool {
        if loaded.contains(span) { return true }
        return await fetch(span..<span + 1, unasked: false).value
    }

    /// Fetches a run of spans in one request, unless a request for the first of them is already on its way.
    private func fetch(_ spans: Range<Int>, unasked: Bool) -> Task<Bool, Never> {
        if let running = fetching[spans.lowerBound] { return running }
        guard case .spans(let index, let file) = mode,
              let first = index.span(spans.lowerBound, size: Self.spanSize),
              let last = index.span(spans.upperBound - 1, size: Self.spanSize) else { return Task { false } }
        let bytes = first.bytes.lowerBound..<last.bytes.upperBound
        let path = ScrubStills.indexPath(partID: partID)
        let task = Task { [weak self] in
            guard let data = await self?.data(path, range: bytes, unasked: unasked), data.count == bytes.count,
                  await file.write(data, at: bytes.lowerBound) else {
                self?.finished(spans, held: false, bytes: 0)
                return false
            }
            self?.finished(spans, held: true, bytes: unasked ? bytes.count : 0)
            return true
        }
        for span in spans { fetching[span] = task }
        return task
    }

    private func finished(_ spans: Range<Int>, held: Bool, bytes: Int) {
        for span in spans { fetching[span] = nil }
        filled += bytes
        if held { loaded.formUnion(spans) }
    }

    // MARK: - The background fill

    /// Whether stills may be fetched before a scrub asks for them: not in Low Power Mode, and the requests themselves
    /// refuse mobile data, a personal hotspot and Low Data Mode (`request`).
    private var mayUseTheNetworkUnasked: Bool {
        !fillEnded && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func startFilling() {
        guard fillTask == nil, mayUseTheNetworkUnasked, case .spans(let index, _) = mode, let playheadSpan else { return }
        let order = index.spansOutward(from: playheadSpan * Self.spanSize, size: Self.spanSize)
        fillTask = Task { [weak self] in
            for span in order {
                guard let self, !Task.isCancelled, await fill(from: span, of: order.count) else { break }
            }
            self?.endFilling(spans: order.count)
        }
    }

    /// Fetches the run of spans not yet held that starts at `span`, once the stream has the data it wants. False when
    /// the fill should stop: it reached its budget, or the network turned it down.
    private func fill(from span: Int, of count: Int) async -> Bool {
        guard !loaded.contains(span), fetching[span] == nil else { return true }
        guard filled < Self.fillBudget, mayUseTheNetworkUnasked else { return false }
        while isStreamStarved?() == true {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return false }
        }
        var end = span + 1
        while end < min(span + Self.fillRun, count), !loaded.contains(end), fetching[end] == nil { end += 1 }
        return await fetch(span..<end, unasked: true).value
    }

    private func endFilling(spans: Int) {
        fillEnded = true
        let seconds = Double((ContinuousClock.now - startedAt).components.seconds)
        MidgarLog.info("Scrub stills: part \(partID) holds \(loaded.count) of \(spans) spans (\(filled >> 10) KB fetched unasked) \(Int(seconds)) s in", category: .playback)
    }

    // MARK: - One still at a time

    private func loadSingle(_ second: Int) {
        let path = ScrubStills.path(partID: partID, second: second)
        Task { [weak self] in
            let data = await self?.data(path, range: nil, unasked: false)
            let image = await Task.detached(priority: .userInitiated) { data.flatMap(StillFile.decode) }.value
            guard let self else { return }
            if let image {
                held.keep(image, at: second)
                onChange?()
            }
            if let next = queue.landed(image != nil) { loadSingle(next) }
        }
    }

    // MARK: - Requests

    /// A request to the server with the Plex headers. One nobody asked for (the fill, the spans around the playhead)
    /// stays off networks that cost the viewer money or that they asked to spare.
    private func request(_ path: String, range: Range<Int>?, unasked: Bool = false) async -> URLRequest {
        var request = URLRequest(url: await api.baseURL.appendingPathComponent(String(path.dropFirst())))
        request.timeoutInterval = 15
        for (key, value) in PlexHeaders.allHeaders(token: api.token) { request.setValue(value, forHTTPHeaderField: key) }
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
        if unasked {
            request.allowsExpensiveNetworkAccess = false
            request.allowsConstrainedNetworkAccess = false
            request.networkServiceType = .background
        }
        return request
    }

    /// The body of a request, when the server answered it as asked: 206 to a range, 200 to a whole file.
    private func data(_ path: String, range: Range<Int>?, unasked: Bool) async -> Data? {
        guard let (data, response) = try? await session.data(for: await request(path, range: range, unasked: unasked)),
              (response as? HTTPURLResponse)?.statusCode == (range == nil ? 200 : 206), !Task.isCancelled else { return nil }
        return data
    }
}

/// The bytes of a preview index on disk: a file as long as the index, written wherever a span arrives and read one still
/// at a time. It lives in the temporary directory for as long as its title plays; one a crash left behind goes when the
/// next is made.
private actor StillFile {
    private static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScrubStills", isDirectory: true)
    private static let sweep: Void = {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }()

    private let url: URL
    private let handle: FileHandle

    init?(length: Int) {
        _ = Self.sweep
        let url = Self.directory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil), let handle = try? FileHandle(forUpdating: url),
              (try? handle.truncate(atOffset: UInt64(length))) != nil else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        self.url = url
        self.handle = handle
    }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ data: Data, at offset: Int) -> Bool {
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    /// The still whose JPEG bytes are at `bytes`, decoded and ready to draw.
    func image(in bytes: Range<Int>) -> UIImage? {
        guard (try? handle.seek(toOffset: UInt64(bytes.lowerBound))) != nil,
              let data = try? handle.read(upToCount: bytes.count), data.count == bytes.count else { return nil }
        return Self.decode(data)
    }

    /// Decodes a still here, off the main thread, so showing it costs the main thread nothing.
    static func decode(_ data: Data) -> UIImage? {
        UIImage(data: data)?.preparingForDisplay()
    }
}

/// Preview stills cut from a file on the device, for a download: the frame nearest each few seconds, made the first time
/// a scrub passes it.
@MainActor
package final class FileScrubStills: ScrubStillSource {
    package var onChange: (() -> Void)?

    /// How far apart the stills are, in seconds, and how far from its moment the frame used for one may be: the nearest
    /// frame that decodes on its own is there many times sooner than the exact one.
    private static let interval = 2.0

    private let generator: AVAssetImageGenerator
    private var held = HeldStills()
    private var wanted: Int?
    private var isWorking = false

    package init(fileURL: URL) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let tolerance = CMTime(seconds: Self.interval, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
    }

    package let offersStills = true

    package func still(at seconds: Double) -> ScrubStill? {
        let key = Int((max(seconds, 0) / Self.interval).rounded(.down))
        if !held.holds(key) {
            wanted = key
            work()
        }
        return held.still(at: key, reach: Int(Double(ScrubStills.standInReach) / Self.interval))
    }

    package func playheadMoved(to seconds: Double) {}

    private func work() {
        guard !isWorking, let key = wanted else { return }
        wanted = nil
        guard !held.holds(key) else { return }
        isWorking = true
        let generator = generator
        let time = CMTime(seconds: Double(key) * Self.interval, preferredTimescale: 600)
        Task { [weak self] in
            let image: UIImage? = await withCheckedContinuation { continuation in
                generator.generateCGImageAsynchronously(for: time) { frame, _, _ in
                    continuation.resume(returning: frame.flatMap { UIImage(cgImage: $0).preparingForDisplay() })
                }
            }
            guard let self else { return }
            isWorking = false
            if let image {
                held.keep(image, at: key)
                onChange?()
            }
            work()
        }
    }
}
#endif

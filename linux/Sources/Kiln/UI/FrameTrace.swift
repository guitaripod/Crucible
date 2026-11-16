import Foundation

/// Where a window's frame time goes: each frame's animation, layout, drawing and present on the CPU, the GPU time of its
/// passes, the passes, new text rasterisations and texture uploads it caused, how long it waited for the compositor,
/// and how long an input took to reach the screen. `KILN_TRACE=path` writes a line there for every second of drawing
/// and for every burst of frames that ends; the HUD shows the last second.
@MainActor
public final class FrameTrace {
    public struct Frame: Sendable {
        public var start: Double = 0
        public var animate: Double = 0
        public var layout: Double = 0
        public var draw: Double = 0
        public var present: Double = 0
        public var passes = 0
        public var rasterised = 0
        public var uploads = 0
        public var glass = 0
        public var rasterTime: Double = 0
        public var textureTime: Double = 0
        public var symbolTime: Double = 0
        public var passTime: Double = 0
        public var animatingViews = 0
        public var animatingNames: [String] = []
        public var inputLatency: Double?
        public var callbackWait: Double?
        public var gpu: Double?

        public var cpu: Double { animate + layout + draw + present }
    }

    public static var passes = 0
    public static var rasterised = 0
    public static var uploads = 0
    public static var glass = 0
    /// Seconds this frame spent laying out and rasterising new labels, and creating and filling their textures.
    public static var rasterTime: Double = 0
    public static var textureTime: Double = 0
    /// Seconds spent rasterising new symbols, and recording GPU passes (which includes building a pipeline the first
    /// time a shader is used).
    public static var symbolTime: Double = 0
    public static var passTime: Double = 0

    private(set) var recent: [Frame] = []
    private var pending: [Frame] = []
    private var pendingInput: Double?
    private var pendingWait: Double?
    private var pendingGPU: Double?
    private var requested: Double?
    private var lastWrite = Window.now()
    private let opened = Window.now()
    private var output: FileHandle?
    /// Whether `KILN_TRACE` named the file, which `record(to:)` then leaves alone.
    private let fromEnvironment: Bool

    public init() {
        if let path = ProcessInfo.processInfo.environment["KILN_TRACE"], !path.isEmpty,
           FileManager.default.createFile(atPath: path, contents: nil) {
            output = FileHandle(forWritingAtPath: path)
            fromEnvironment = true
        } else {
            output = nil
            fromEnvironment = false
        }
    }

    /// Starts writing the trace to `url`, emptied first, or stops with nil; a trace `KILN_TRACE` started keeps going.
    public func record(to url: URL?) {
        guard !fromEnvironment else { return }
        try? output?.close()
        output = nil
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.createFile(atPath: url.path, contents: nil) { output = FileHandle(forWritingAtPath: url.path) }
    }

    public var isWriting: Bool { output != nil }

    /// An input arrived; the next frame presented answers it.
    func inputArrived() {
        if pendingInput == nil { pendingInput = Window.now() }
    }

    func frameRequested() { requested = Window.now() }

    func frameCallbackArrived() {
        if let requested { pendingWait = (Window.now() - requested) * 1000 }
        requested = nil
    }

    func gpu(_ milliseconds: Double) {
        if milliseconds > 0 { pendingGPU = milliseconds }
    }

    func begin() -> Frame {
        Self.passes = 0
        Self.rasterised = 0
        Self.uploads = 0
        Self.glass = 0
        Self.rasterTime = 0
        Self.textureTime = 0
        Self.symbolTime = 0
        Self.passTime = 0
        return Frame(start: Window.now())
    }

    /// Records a finished frame; `settled` says nothing is left to draw, which closes the burst in the trace.
    func end(_ frame: Frame, settled: Bool) {
        var finished = frame
        finished.passes = Self.passes
        finished.rasterised = Self.rasterised
        finished.uploads = Self.uploads
        finished.glass = Self.glass
        finished.rasterTime = Self.rasterTime
        finished.textureTime = Self.textureTime
        finished.symbolTime = Self.symbolTime
        finished.passTime = Self.passTime
        finished.callbackWait = pendingWait
        finished.gpu = pendingGPU
        pendingWait = nil
        pendingGPU = nil
        if let pendingInput {
            finished.inputLatency = (Window.now() - pendingInput) * 1000
            self.pendingInput = nil
        }
        recent.append(finished)
        if recent.count > 240 { recent.removeFirst(recent.count - 240) }
        guard output != nil else { return }
        pending.append(finished)
        if settled || Window.now() - lastWrite >= 1 { write() }
    }

    /// The last second for the HUD.
    public var summary: String {
        let now = Window.now()
        let second = recent.filter { now - $0.start < 1 }
        return second.isEmpty ? "idle" : Self.describe(second, span: 1)
    }

    /// Frames, CPU per frame by phase, GPU per frame, compositor waits, the worst frame's work, and input latency, as
    /// median/worst.
    private static func describe(_ frames: [Frame], span: Double) -> String {
        func stat(_ values: [Double]) -> String {
            let sorted = values.sorted()
            guard let last = sorted.last else { return "-" }
            return String(format: "%.1f/%.1f", sorted[sorted.count / 2], last)
        }
        let rate = span > 0 ? Double(frames.count) / span : 0
        var line = String(format: "%d frames %.0f fps", frames.count, rate)
        line += "  cpu \(stat(frames.map { $0.cpu * 1000 })) ms"
        line += " (anim \(stat(frames.map { $0.animate * 1000 })) layout \(stat(frames.map { $0.layout * 1000 }))"
        line += " draw \(stat(frames.map { $0.draw * 1000 })) present \(stat(frames.map { $0.present * 1000 })))"
        line += "  gpu \(stat(frames.compactMap(\.gpu)))  wait \(stat(frames.compactMap(\.callbackWait)))"
        line += "  passes \(frames.map(\.passes).max() ?? 0)  text \(frames.map(\.rasterised).reduce(0, +))"
        line += "  uploads \(frames.map(\.uploads).reduce(0, +))  glass \(frames.map(\.glass).max() ?? 0)"
        line += "  animating \(frames.map(\.animatingViews).max() ?? 0)"
        let latencies = frames.compactMap(\.inputLatency)
        line += "  input \(latencies.isEmpty ? "-" : stat(latencies))"
        line += "  [\(Set(frames.flatMap(\.animatingNames)).sorted().joined(separator: ","))]"
        return line
    }

    private func write() {
        guard let output, let first = pending.first, let last = pending.last else { return }
        lastWrite = Window.now()
        let span = max(last.start + last.cpu - first.start, 1.0 / 60)
        output.write(Data(String(format: "%8.3f  ", first.start - opened).utf8))
        output.write(Data((Self.describe(pending, span: span) + "\n").utf8))
        for frame in pending where frame.cpu * 1000 > 12 || (frame.callbackWait ?? 0) > 40 {
            output.write(Data(String(format: "  slow frame +%.3f: anim %.1f layout %.1f draw %.1f (text %.1f + %.1f, symbols %.1f, passes %.1f) present %.1f wait %.1f ms, %d passes, %d text, %d uploads\n",
                                     frame.start - first.start, frame.animate * 1000, frame.layout * 1000, frame.draw * 1000, frame.rasterTime * 1000,
                                     frame.textureTime * 1000, frame.symbolTime * 1000, frame.passTime * 1000, frame.present * 1000, frame.callbackWait ?? 0, frame.passes, frame.rasterised,
                                     frame.uploads).utf8))
        }
        pending.removeAll(keepingCapacity: true)
    }
}

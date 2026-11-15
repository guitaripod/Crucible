import CKiln
import Foundation
import Kiln

/// P0 spike: an FP16 scRGB window on KWin, a Liquid Glass tab bar over a moving HDR scene, GPU and presentation timing,
/// the main actor driven by Kiln's loop, and readbacks written as PPM files for review.
@MainActor
final class Spike: WaylandWindowDelegate {
    let highlightNits: Float = 1000
    let frameLimit: Int
    let outputDirectory: String
    let loop = EventLoop()
    var window: WaylandWindow?
    var gpu: GPU?
    var glass: LiquidGlassRenderer?
    var sceneTarget: Texture?
    var finalTarget: Texture?
    var width = 0
    var height = 0
    var frame = 0
    var waitingForFrame = false
    var gpuTimes: [Double] = []
    var presentations: [UInt64] = []
    var refreshNanoseconds: UInt32 = 0
    var mainActorTicks = 0
    var finished = false
    var report: [String: String] = [:]

    init(frameLimit: Int, outputDirectory: String) {
        self.frameLimit = frameLimit
        self.outputDirectory = outputDirectory
    }

    func run() throws {
        guard let window = WaylandWindow() else { throw SpikeError("no Wayland display") }
        self.window = window
        guard window.open(title: "Kiln spike", appID: "org.guitaripod.Crucible.KilnSpike", delegate: self) else { throw SpikeError("window failed") }
        window.setFullscreen(true)
        _ = window.pump(readable: false)
        loop.add(fd: window.fileDescriptor) { [weak self] readable in
            guard let self, let window = self.window else { return }
            if !window.pump(readable: readable) { self.finished = true }
        }
        for _ in 0..<20 { loop.runOnce(timeoutMilliseconds: 10) }
        report["colorSupport"] = String(window.colorSupport.rawValue, radix: 2)
        try setUpRendering(on: window)
        scheduleMainActorTick()
        let started = Date()
        loop.run { [unowned self] in
            if !self.waitingForFrame && self.frame < self.frameLimit { self.renderFrame() }
            return self.finished || (self.frame >= self.frameLimit && self.presentations.count >= self.frameLimit - 3) || Date().timeIntervalSince(started) > 60
        }
        report["frames"] = String(frame)
        report["seconds"] = String(format: "%.2f", Date().timeIntervalSince(started))
        report["mainActorTicks"] = String(mainActorTicks)
        summarizeTimings()
        gpu?.finish()
        glass = nil
        sceneTarget = nil
        finalTarget = nil
        gpu = nil
        window.close()
    }

    /// The GPU lives only in `self.gpu`, so tearing it down before the Wayland connection closes is explicit.
    func setUpRendering(on window: WaylandWindow) throws {
        let gpu = try GPU(display: window.display, surface: window.surface)
        self.gpu = gpu
        report["device"] = gpu.deviceName
        if let size = gpu.resize(width: width, height: height) { report["swapchain"] = "\(size.width)x\(size.height)" }
        report["size"] = "\(width)x\(height)"
        glass = try LiquidGlassRenderer(gpu: gpu, width: width, height: height)
        sceneTarget = try gpu.texture(width: width, height: height, format: .rgba16f, renderable: true)
        finalTarget = try gpu.texture(width: width, height: height, format: .rgba16f, renderable: true)
    }

    func scheduleMainActorTick() {
        Task { @MainActor in
            self.mainActorTicks += 1
            if !self.finished && self.frame < self.frameLimit { self.scheduleMainActorTick() }
        }
    }

    func renderFrame() {
        guard let gpu, let glass, let sceneTarget, let finalTarget, let window else { return }
        let time = Float(frame) / 144 + 4.65
        gpu.pass(into: sceneTarget, header: SpikeScene.header, body: SpikeScene.body, uniforms: [
            .init("size", Float(width), Float(height)),
            .init("time", time),
            .init("highlight", highlightNits / 203),
        ])
        glass.blur(sceneTarget)
        glass.composite(scene: sceneTarget, into: finalTarget, element: tabBar(at: time))
        if frame == 90 || frame == frameLimit - 1 { capture(finalTarget, name: "frame-\(frame)") }
        window.requestFrame()
        waitingForFrame = true
        gpu.present(finalTarget)
        window.flush()
        let milliseconds = gpu.takeGPUMilliseconds()
        if milliseconds > 0 { gpuTimes.append(milliseconds) }
        frame += 1
    }

    /// The tab bar of the Apple TV, floating near the top: its selection pill walks the tabs, a round search button
    /// melts into its end and out again, and the light circles the bar.
    func tabBar(at time: Float) -> LiquidGlass {
        let w = Float(width)
        let h = Float(height)
        let barHalfWidth = w * 0.20
        let barHalfHeight = h * 0.032
        let barX = w * 0.5
        let barY = h * 0.09
        var element = LiquidGlass(
            primary: .init(centerX: barX, centerY: barY, halfWidth: barHalfWidth, halfHeight: barHalfHeight, radius: barHalfHeight),
            lightX: barX + cos(time * 1.4) * barHalfWidth * 1.2,
            lightY: barY - sin(time * 1.4) * barHalfHeight * 3
        )
        let slots: Float = 5
        let slotWidth = (barHalfWidth * 2 - barHalfHeight) / slots
        let walk = (sin(time * 0.9) * 0.5 + 0.5) * (slots - 1)
        let pillX = barX - barHalfWidth + barHalfHeight * 0.5 + slotWidth * (walk + 0.5)
        element.pill = .init(centerX: pillX, centerY: barY, halfWidth: slotWidth * 0.46, halfHeight: barHalfHeight * 0.74, radius: barHalfHeight * 0.74)
        let gap = (sin(time * 0.7) * 0.5 + 0.5) * barHalfHeight * 3.2
        let buttonRadius = barHalfHeight
        element.secondary = .init(centerX: barX + barHalfWidth + buttonRadius + gap, centerY: barY, halfWidth: buttonRadius, halfHeight: buttonRadius, radius: buttonRadius)
        element.blend = barHalfHeight * 0.9
        element.rimWidth = barHalfHeight * 0.55
        element.refraction = h * 0.011
        element.shadowOffsetY = h * 0.008
        element.shadowRadius = h * 0.024
        return element
    }

    func summarizeTimings() {
        let sorted = gpuTimes.sorted()
        if !sorted.isEmpty {
            report["gpuMsMedian"] = String(format: "%.3f", sorted[sorted.count / 2])
            report["gpuMsP99"] = String(format: "%.3f", sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))])
            report["gpuMsMax"] = String(format: "%.3f", sorted.last!)
        }
        let intervals = zip(presentations.dropFirst(), presentations).map { Double($0 - $1) / 1_000_000 }.sorted()
        if !intervals.isEmpty {
            report["presentIntervalMsMedian"] = String(format: "%.3f", intervals[intervals.count / 2])
            report["presentIntervalMsMax"] = String(format: "%.3f", intervals.last!)
        }
        report["refreshMs"] = String(format: "%.3f", Double(refreshNanoseconds) / 1_000_000)
        report["presented"] = String(presentations.count)
    }

    /// Writes the target as an 8-bit PPM (reference white as white, highlights clipped) and records the HDR value read
    /// back at the sun's centre.
    func capture(_ target: Texture, name: String) {
        let pixels = target.download()
        let sunX = Int(Float(target.width) * 0.64)
        let sunY = Int(Float(target.height) * 0.47)
        let sunIndex = (sunY * target.width + sunX) * 4
        report["\(name).sunLinear"] = String(format: "%.3f,%.3f,%.3f", pixels[sunIndex], pixels[sunIndex + 1], pixels[sunIndex + 2])
        var data = Data("P6\n\(target.width) \(target.height)\n255\n".utf8)
        data.reserveCapacity(target.width * target.height * 3 + 32)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 { data.append(Self.encode(pixels[index + channel])) }
        }
        let path = "\(outputDirectory)/\(name).ppm"
        try? data.write(to: URL(fileURLWithPath: path))
        report["\(name).path"] = path
    }

    static func encode(_ linear: Float) -> UInt8 {
        let value = min(max(linear, 0), 1)
        let encoded = value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
        return UInt8((encoded * 255).rounded())
    }

    func windowConfigured(_ window: WaylandWindow, width: Int, height: Int, fullscreen: Bool) {
        self.width = width
        self.height = height
        report["fullscreen"] = String(fullscreen)
    }

    func windowClosed(_ window: WaylandWindow) { finished = true }
    func windowScaleChanged(_ window: WaylandWindow, scale: Double) { report["scale"] = String(scale) }

    func windowPresented(_ window: WaylandWindow, nanoseconds: UInt64, refreshNanoseconds: UInt32, sequence: UInt64) {
        presentations.append(nanoseconds)
        self.refreshNanoseconds = refreshNanoseconds
    }

    func windowFrameDone(_ window: WaylandWindow) { waitingForFrame = false }
    func windowPointerMoved(_ window: WaylandWindow, x: Double, y: Double) {}
    func windowPointerLeft(_ window: WaylandWindow) {}
    func windowPointerButton(_ window: WaylandWindow, button: UInt32, pressed: Bool) {}
    func windowScrolled(_ window: WaylandWindow, event: ScrollEvent) {}
    func windowKey(_ window: WaylandWindow, event: KeyEvent, pressed: Bool, repeats: Bool) {}
}

struct SpikeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

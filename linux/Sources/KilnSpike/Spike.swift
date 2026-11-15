import CKiln
import Foundation
import Kiln

/// P0 spike: an FP16 scRGB window on KWin, a Liquid Glass tab bar over a moving HDR scene, GPU and presentation timing,
/// the main actor driven by Kiln's loop, and readbacks written as PPM files for review.
@MainActor
final class Spike: WaylandWindowDelegate {
    let referenceWhite: Float = 2.5375
    let highlightNits: Float = 1000
    let frameLimit: Int
    let outputDirectory: String
    let loop = EventLoop()
    var window: WaylandWindow?
    var context: EGLWindowContext?
    var glass: LiquidGlassRenderer?
    var scene: ShaderProgram?
    var sceneTarget: RenderTarget?
    var finalTarget: RenderTarget?
    var timer: GPUTimer?
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
        report["scRGBDescribed"] = String(window.describeAsScRGB())
        guard let display = window.display, let surface = window.surface,
              let context = EGLWindowContext(wlDisplay: display, wlSurface: surface, width: width, height: height)
        else { throw SpikeError("EGL context failed") }
        self.context = context
        report["eglVendor"] = context.vendor
        report["glRenderer"] = context.renderer
        report["surfaceFormat"] = "\(context.format)"
        report["size"] = "\(width)x\(height)"
        glass = try LiquidGlassRenderer(width: width, height: height)
        scene = try ShaderProgram(vertex: ShaderSources.fullscreenVertex, fragment: SpikeScene.fragment)
        sceneTarget = try RenderTarget(width: width, height: height)
        finalTarget = try RenderTarget(width: width, height: height)
        timer = GPUTimer()
        scheduleMainActorTick()
        let started = Date()
        loop.run { [unowned self] in
            if !self.waitingForFrame && self.frame < self.frameLimit { self.renderFrame() }
            return self.finished || (self.frame >= self.frameLimit && self.presentations.count >= self.frameLimit - 2) || Date().timeIntervalSince(started) > 60
        }
        report["frames"] = String(frame)
        report["seconds"] = String(format: "%.2f", Date().timeIntervalSince(started))
        report["mainActorTicks"] = String(mainActorTicks)
        summarizeTimings()
        window.close()
    }

    func scheduleMainActorTick() {
        Task { @MainActor in
            self.mainActorTicks += 1
            if !self.finished && self.frame < self.frameLimit { self.scheduleMainActorTick() }
        }
    }

    func renderFrame() {
        guard let context, let glass, let scene, let sceneTarget, let finalTarget, let timer, let window else { return }
        let time = Float(frame) / 144 + 4.65
        timer.begin()
        sceneTarget.bindForDrawing()
        scene.use()
        scene.set("size", Float(width), Float(height))
        scene.set("time", time)
        scene.set("referenceWhite", referenceWhite)
        scene.set("highlightNits", highlightNits)
        glass.drawFullscreen()
        glass.blur(sceneTarget)
        glass.composite(scene: sceneTarget, into: finalTarget, element: tabBar(at: time), referenceWhite: referenceWhite)
        glass.present(finalTarget, width: width, height: height)
        timer.end()
        if let milliseconds = timer.lastMilliseconds { gpuTimes.append(milliseconds) }
        if frame == 90 || frame == frameLimit - 1 { capture(finalTarget, name: "frame-\(frame)") }
        window.requestFrame()
        waitingForFrame = true
        context.swap()
        window.flush()
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
        let barY = h * 0.91
        var element = LiquidGlass(
            primary: .init(centerX: barX, centerY: barY, halfWidth: barHalfWidth, halfHeight: barHalfHeight, radius: barHalfHeight),
            lightX: barX + cos(time * 1.4) * barHalfWidth * 1.2,
            lightY: barY + sin(time * 1.4) * barHalfHeight * 3
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
        element.shadowOffsetY = -h * 0.008
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

    /// Writes the target as an 8-bit PPM (white at `referenceWhite`, highlights clipped) and records the HDR value
    /// read back at the sun's centre.
    func capture(_ target: RenderTarget, name: String) {
        let pixels = target.readPixels()
        let sunX = Int(Float(target.width) * 0.64)
        let sunY = Int(Float(target.height) * 0.53)
        let sunIndex = (sunY * target.width + sunX) * 4
        report["\(name).sunScRGB"] = String(format: "%.3f,%.3f,%.3f", pixels[sunIndex], pixels[sunIndex + 1], pixels[sunIndex + 2])
        var bytes = [UInt8]()
        bytes.reserveCapacity(target.width * target.height * 3)
        for row in stride(from: target.height - 1, through: 0, by: -1) {
            for column in 0..<target.width {
                let index = (row * target.width + column) * 4
                for channel in 0..<3 {
                    bytes.append(Self.encode(pixels[index + channel] / referenceWhite))
                }
            }
        }
        var data = Data("P6\n\(target.width) \(target.height)\n255\n".utf8)
        data.append(contentsOf: bytes)
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
        context?.resize(width: width, height: height)
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
    func windowScrolled(_ window: WaylandWindow, axis: UInt32, value: Double, value120: Int32) {}
    func windowKey(_ window: WaylandWindow, key: UInt32, pressed: Bool) {}
}

struct SpikeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

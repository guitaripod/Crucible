import CKiln
import CMPV
import Foundation
import Kiln

/// P0 video spike: each clip is rendered by libmpv's OpenGL render API into a half-float Kiln target as PQ BT.2020,
/// sampled at known points, timed while playing, and written as a preview PPM.
@MainActor
func runVideoSpike() -> [String] {
    var lines: [String] = []
    guard let gpu = EGLHeadlessContext() else { return ["error=no headless EGL context: \(EGLHeadlessContext.failure)"] }
    lines.append("renderer=\(gpu.renderer)")
    let arguments = CommandLine.arguments.dropFirst()
    let outputDirectory = ProcessInfo.processInfo.environment["SPIKE_OUT"] ?? FileManager.default.currentDirectoryPath
    for path in arguments {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        do {
            lines.append(contentsOf: try probe(path: path, name: name, outputDirectory: outputDirectory))
        } catch {
            lines.append("\(name).error=\(error)")
        }
    }
    return lines
}

@MainActor
func probe(path: String, name: String, outputDirectory: String) throws -> [String] {
    var lines: [String] = []
    let width = 3840
    let height = 2160
    let target = try RenderTarget(width: width, height: height)
    let player = try MPVTexture(options: [
        "vo": "libmpv",
        "hwdec": ProcessInfo.processInfo.environment["HWDEC"] ?? "nvdec",
        "target-trc": "pq",
        "target-prim": "bt.2020",
        "target-peak": "10000",
        "tone-mapping": "clip",
        "gamut-mapping-mode": "clip",
        "hdr-compute-peak": "no",
        "dither": "no",
        "audio": "no",
        "pause": "yes",
        "keep-open": "yes",
        "terminal": "no",
    ])
    defer { player.close() }
    try player.command(["loadfile", path])
    guard player.wait(for: MPV_EVENT_PLAYBACK_RESTART, seconds: 15) else { throw SpikeFailure("no first frame") }
    for _ in 0..<4 {
        player.render(into: target)
        glFinish()
    }
    lines.append("\(name).hwdec=\(player.property("hwdec-current") ?? "?")")
    lines.append("\(name).params=\(player.property("video-params/colormatrix") ?? "?")/\(player.property("video-params/primaries") ?? "?")/\(player.property("video-params/gamma") ?? "?") peak \(player.property("video-params/sig-peak") ?? "?")")
    let pixels = target.readPixels()
    for (label, fx) in [("left", 1.0 / 6), ("middle", 0.5), ("right", 5.0 / 6)] {
        let x = Int(Double(width) * fx)
        let y = height / 2
        let index = (y * width + x) * 4
        let pq = (pixels[index], pixels[index + 1], pixels[index + 2])
        lines.append(String(format: "\(name).\(label).pq=%.4f,%.4f,%.4f nits=%.1f", pq.0, pq.1, pq.2, nits(fromPQ: pq.1)))
    }
    writePreview(pixels: pixels, width: width, height: height, path: "\(outputDirectory)/\(name).ppm")
    let timer = GPUTimer()
    try player.command(["set", "pause", "no"])
    var renders = 0
    var gpuTimes: [Double] = []
    let started = Date()
    while Date().timeIntervalSince(started) < 4 {
        guard let event = mpv_wait_event(player.handle, 0.001) else { continue }
        _ = event
        timer.begin()
        player.render(into: target)
        timer.end()
        if let milliseconds = timer.lastMilliseconds { gpuTimes.append(milliseconds) }
        renders += 1
    }
    let sorted = gpuTimes.sorted()
    if !sorted.isEmpty {
        lines.append(String(format: "\(name).renderMsMedian=%.3f renderMsP99=%.3f", sorted[sorted.count / 2], sorted[min(sorted.count - 1, sorted.count * 99 / 100)]))
    }
    lines.append("\(name).droppedFrames=\(player.property("frame-drop-count") ?? "?") decoderDrops=\(player.property("decoder-frame-drop-count") ?? "?")")
    return lines
}

func nits(fromPQ value: Float) -> Double {
    let m1 = 2610.0 / 16384
    let m2 = 2523.0 / 4096 * 128
    let c1 = 3424.0 / 4096
    let c2 = 2413.0 / 4096 * 32
    let c3 = 2392.0 / 4096 * 32
    let e = pow(max(Double(value), 0), 1 / m2)
    return 10000 * pow(max(e - c1, 0) / (c2 - c3 * e), 1 / m1)
}

/// Writes the frame for a person to look at: PQ decoded to luminance, 203 cd/m2 as white, BT.2020 shown as is.
func writePreview(pixels: [Float], width: Int, height: Int, path: String) {
    var data = Data("P6\n\(width / 2) \(height / 2)\n255\n".utf8)
    for row in stride(from: height - 2, through: 0, by: -2) {
        for column in stride(from: 0, to: width, by: 2) {
            let index = (row * width + column) * 4
            for channel in 0..<3 {
                let linear = min(nits(fromPQ: pixels[index + channel]) / 203, 1)
                let encoded = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
                data.append(UInt8((encoded * 255).rounded()))
            }
        }
    }
    try? data.write(to: URL(fileURLWithPath: path))
}

let report = MainActor.assumeIsolated { runVideoSpike() }
report.forEach { print($0) }

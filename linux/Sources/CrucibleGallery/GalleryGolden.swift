import Foundation
import Kiln

/// Golden images for the gallery's captures: each capture is reduced to a quarter of its size in linear light and compared
/// with the committed thumbnail of the same name, so a layout, colour or state that moves shows up while a spinner's angle
/// or a glyph's antialiasing does not. `--update-golden` writes the thumbnails instead.
enum GalleryGolden {
    struct Verdict {
        let passed: Bool
        let line: String
    }

    static let factor = 4
    /// A pixel counts as changed when a channel moves more than this many 8-bit steps.
    static let changedStep = 24
    /// The share of changed pixels a capture may have and still match.
    static let changedLimit = 0.005
    /// The largest mean difference, in 8-bit steps, a capture may have and still match.
    static let meanLimit = 2.0

    /// The capture at a quarter of its size, averaged in linear light, as PNG bytes.
    static func thumbnail(_ capture: (width: Int, height: Int, pixels: [Float])) -> (data: Data, width: Int, height: Int)? {
        let width = capture.width / factor
        let height = capture.height / factor
        guard width > 0, height > 0 else { return nil }
        var reduced = [Float](repeating: 0, count: width * height * 4)
        let weight = 1 / Float(factor * factor)
        for y in 0..<height {
            for x in 0..<width {
                for dy in 0..<factor {
                    let row = (y * factor + dy) * capture.width
                    for dx in 0..<factor {
                        let source = (row + x * factor + dx) * 4
                        let target = (y * width + x) * 4
                        for channel in 0..<4 { reduced[target + channel] += capture.pixels[source + channel] * weight }
                    }
                }
            }
        }
        return PNGWriter.encode(linear: reduced, width: width, height: height).map { ($0, width, height) }
    }

    /// Compares `capture` with `golden/name.png`, writing `name-golden-diff.png` beside the capture when they differ.
    static func check(_ capture: (width: Int, height: Int, pixels: [Float]), name: String, golden: String, captureDirectory: String) -> Verdict {
        guard let current = thumbnail(capture), let mine = try? ImageDecoder.decode(current.data) else {
            return Verdict(passed: false, line: "golden FAILED \(name): the capture could not be reduced")
        }
        let path = "\(golden)/\(name).png"
        guard let data = FileManager.default.contents(atPath: path), let expected = try? ImageDecoder.decode(data) else {
            return Verdict(passed: false, line: "golden MISSING \(name): no \(path); run with --update-golden")
        }
        guard expected.width == mine.width, expected.height == mine.height else {
            return Verdict(passed: false, line: "golden MISMATCH \(name): \(mine.width)x\(mine.height), golden \(expected.width)x\(expected.height)")
        }
        var changed = 0
        var total = 0
        var diff = [Float](repeating: 0, count: mine.width * mine.height * 4)
        for pixel in 0..<(mine.width * mine.height) {
            var largest = 0
            for channel in 0..<3 {
                largest = max(largest, abs(Int(mine.pixels[pixel * 4 + channel]) - Int(expected.pixels[pixel * 4 + channel])))
            }
            total += largest
            if largest > changedStep { changed += 1 }
            let shown = min(Float(largest) / 64, 1)
            diff[pixel * 4] = shown
            diff[pixel * 4 + 1] = shown * 0.2
            diff[pixel * 4 + 3] = 1
        }
        let count = Double(mine.width * mine.height)
        let share = Double(changed) / count
        let mean = Double(total) / count
        let passed = share <= changedLimit && mean <= meanLimit
        if !passed {
            _ = PNGWriter.write(linear: diff, width: mine.width, height: mine.height, to: "\(captureDirectory)/\(name)-golden-diff.png")
        }
        let summary = String(format: "mean %.2f, changed %.2f%%", mean, share * 100)
        return Verdict(passed: passed, line: "golden \(passed ? "ok" : "MISMATCH") \(name): \(summary)")
    }

    /// Writes the capture's thumbnail as the golden for `name`.
    static func update(_ capture: (width: Int, height: Int, pixels: [Float]), name: String, golden: String) -> Verdict {
        guard let current = thumbnail(capture) else { return Verdict(passed: false, line: "golden FAILED \(name)") }
        do {
            try FileManager.default.createDirectory(atPath: golden, withIntermediateDirectories: true)
            try current.data.write(to: URL(fileURLWithPath: "\(golden)/\(name).png"))
            return Verdict(passed: true, line: "golden wrote \(name) \(current.width)x\(current.height)")
        } catch {
            return Verdict(passed: false, line: "golden FAILED \(name): \(error)")
        }
    }
}

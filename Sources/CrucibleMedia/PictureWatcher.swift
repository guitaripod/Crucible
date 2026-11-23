import AVFoundation
import CrucibleCore
import Foundation
import MidgarCore

/// Watches what a converted stream actually shows. A server-side decoder that cannot handle the file's codec paints every
/// frame one flat colour, most often green, and reports nothing: the player is happy, the sound plays and the picture is
/// gone. This samples the frames the player draws on a sparse grid, which costs almost nothing next to decoding, and calls
/// the picture dead once `PictureWatchdog` has seen the same impossible colour for long enough to be certain.
@MainActor
final class PictureWatcher {
    /// How many columns and rows of pixels are read from each plane, which is enough to tell a flat frame from any.
    private static let columns = 32
    private static let rows = 18

    private let output: AVPlayerItemVideoOutput
    private var watchdog = PictureWatchdog()
    private var task: Task<Void, Never>?
    /// The item the output was added to, so watching the same item again after a launch takes the old output off it first
    /// instead of stacking a second tap on the same frames.
    private weak var item: AVPlayerItem?

    init(item: AVPlayerItem) {
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        self.item = item
        item.add(output)
    }

    /// Samples the player's picture until it finds it dead, reports that once and stops watching. Frames that are not new,
    /// or a player that is paused, are skipped: only the frames the viewer would see are judged.
    func start(player: AVPlayer, interval: Duration, report: @escaping @MainActor @Sendable () -> Void) {
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled, player.rate > 0, let sample = self.sample(player: player) else { continue }
                if self.watchdog.observe(sample) {
                    report()
                    return
                }
            }
        }
    }

    func invalidate() {
        task?.cancel()
        task = nil
        item?.remove(output)
        item = nil
    }

    /// The frame the player shows now, measured; nil when it has not drawn a new one since the last look.
    private func sample(player: AVPlayer) -> PictureSample? {
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return nil }
        return PictureSample(measuring: buffer, columns: Self.columns, rows: Self.rows)
    }
}

extension PictureSample {
    /// Measures a frame of the player's own 8-bit 4:2:0 planes: the mean and the spread of its luma, and the mean and
    /// spread of its two chroma, read on a grid so a 1080p or 4K frame costs the same.
    init?(measuring buffer: CVPixelBuffer, columns: Int, rows: Int) {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              CVPixelBufferIsPlanar(buffer), CVPixelBufferGetPlaneCount(buffer) >= 2,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let lumaPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let luma = Self.measure(
            lumaPlane,
            width: CVPixelBufferGetWidthOfPlane(buffer, 0),
            height: CVPixelBufferGetHeightOfPlane(buffer, 0),
            bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
            columns: columns,
            rows: rows
        )
        let chroma = Self.measureChroma(
            chromaPlane,
            width: CVPixelBufferGetWidthOfPlane(buffer, 1),
            height: CVPixelBufferGetHeightOfPlane(buffer, 1),
            bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1),
            columns: columns,
            rows: rows
        )
        guard let luma, let chroma else { return nil }
        self.init(
            luma: luma.mean,
            blue: chroma.blue,
            red: chroma.red,
            lumaSpread: luma.spread,
            chromaSpread: chroma.spread
        )
    }

    /// The mean and spread of one single-channel plane, read on a grid of its pixels.
    private static func measure(
        _ plane: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        columns: Int,
        rows: Int
    ) -> (mean: Double, spread: Double)? {
        guard width > 0, height > 0, columns > 0, rows > 0 else { return nil }
        var total = 0.0
        var low = 255.0
        var high = 0.0
        var count = 0.0
        for row in 0..<rows {
            let line = plane.advanced(by: Self.coordinate(row, of: height, steps: rows) * bytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            for column in 0..<columns {
                let value = Double(line[Self.coordinate(column, of: width, steps: columns)])
                total += value
                low = min(low, value)
                high = max(high, value)
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return (total / count, high - low)
    }

    /// The means of a plane's two interleaved chroma and the larger of their spreads.
    private static func measureChroma(
        _ plane: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        columns: Int,
        rows: Int
    ) -> (blue: Double, red: Double, spread: Double)? {
        guard width > 1, height > 0, columns > 0, rows > 0 else { return nil }
        var blue = 0.0
        var red = 0.0
        var blueLow = 255.0
        var blueHigh = 0.0
        var redLow = 255.0
        var redHigh = 0.0
        var count = 0.0
        for row in 0..<rows {
            let line = plane.advanced(by: Self.coordinate(row, of: height, steps: rows) * bytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            for column in 0..<columns {
                let pair = Self.coordinate(column, of: width / 2, steps: columns) * 2
                let cb = Double(line[pair])
                let cr = Double(line[pair + 1])
                blue += cb
                red += cr
                blueLow = min(blueLow, cb)
                blueHigh = max(blueHigh, cb)
                redLow = min(redLow, cr)
                redHigh = max(redHigh, cr)
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return (blue / count, red / count, max(blueHigh - blueLow, redHigh - redLow))
    }

    /// The middle of the cell a grid step covers, kept inside the plane.
    private static func coordinate(_ step: Int, of length: Int, steps: Int) -> Int {
        let cell = length / steps
        return min(length - 1, step * cell + cell / 2)
    }
}

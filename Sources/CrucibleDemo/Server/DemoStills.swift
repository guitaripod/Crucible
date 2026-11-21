import CrucibleCore
import Foundation

/// The preview stills of a demo title, as a server that makes video preview thumbnails serves them (`BIFIndex`). Every
/// title plays the same short clip, so its index is the clip's stills over and over for as long as the title says it
/// runs. The file is never built whole unless it is asked for whole: the table is written out and the stills are cut
/// from the one cycle the bundle holds.
struct DemoStillIndex: Sendable {
    private let table: Data
    private let cycle: Data

    let length: Int

    /// The index of a title `durationMs` long, from the clip's own index; nil when that is not a BIF file.
    init?(clip: Data, durationMs: Int) {
        guard let index = BIFIndex(clip), let first = index.frames.first else { return nil }
        let cycle = Data(clip[first.bytes.lowerBound..<index.length])
        let starts = index.frames.map { $0.bytes.lowerBound - first.bytes.lowerBound }
        let unit = max(Int((index.interval * 1000).rounded()), 1)
        let count = max(index.frames.count, (durationMs + unit - 1) / unit)
        var table = Data([0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A])
        func word(_ value: Int) {
            let value = UInt32(truncatingIfNeeded: value)
            table.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)])
        }
        word(0)
        word(count)
        word(unit)
        table.append(Data(count: BIFIndex.headerSize - table.count))
        let tableLength = BIFIndex.headerSize + (count + 1) * 8
        func offset(of frame: Int) -> Int {
            tableLength + frame / starts.count * cycle.count + starts[frame % starts.count]
        }
        for frame in 0..<count {
            word(frame)
            word(offset(of: frame))
        }
        word(0xFFFF_FFFF)
        word(offset(of: count))
        self.table = table
        self.cycle = cycle
        length = offset(of: count)
    }

    /// The bytes of the file in `range`, which lies inside it.
    func bytes(_ range: Range<Int>) -> Data {
        var bytes = Data(capacity: range.count)
        if range.lowerBound < table.count {
            bytes.append(table.subdata(in: range.lowerBound..<min(range.upperBound, table.count)))
        }
        var position = max(range.lowerBound, table.count) - table.count
        let end = range.upperBound - table.count
        while position < end {
            let start = position % cycle.count
            let taken = min(cycle.count - start, end - position)
            bytes.append(cycle.subdata(in: start..<start + taken))
            position += taken
        }
        return bytes
    }
}

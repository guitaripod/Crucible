import Foundation

/// The preview stills a Plex server keeps for a file once video preview thumbnails are on: one every few seconds, served
/// one at a time as the still nearest an offset (`/library/parts/{id}/indexes/sd/{ms}`, a 404 when there are none).
package enum ScrubStills {
    /// The part whose stills a scrubber shows, when the server has made them for it.
    package static func part(of media: PlexMedia?) -> PlexPart? {
        guard let part = media?.Part?.first, part.indexes == "sd" else { return nil }
        return part
    }

    /// The whole second a still is asked for at, so a scrubber moving within one second asks once.
    package static func second(_ seconds: Double) -> Int {
        seconds.isFinite ? Int(max(seconds, 0).rounded()) : 0
    }

    package static func path(partID: Int, second: Int) -> String {
        "/library/parts/\(partID)/indexes/sd/\(second * 1000)"
    }

    /// The part's whole preview index in one file (`BIFIndex`).
    package static func indexPath(partID: Int) -> String {
        "/library/parts/\(partID)/indexes/sd"
    }

    /// How far the nearest held still may be from where the scrubber points and still stand in for it while the right
    /// one loads.
    package static let standInReach = 30
}

/// Which still to ask the server for next: one request at a time, always for where the scrubber points now, so a held
/// scrub asks for no stale positions. A file whose first request fails before any still arrived has none, and is asked
/// nothing more.
package struct ScrubStillQueue: Equatable, Sendable {
    package private(set) var inFlight: Int?
    package private(set) var isUnavailable = false
    private var wanted: Int?
    private var hasLanded = false

    package init() {}

    /// The scrubber points at `second`; `held` when that still is already in hand. Returns the second to ask for now.
    package mutating func want(_ second: Int, held: Bool) -> Int? {
        guard !isUnavailable else { return nil }
        wanted = held ? nil : second
        guard !held, inFlight == nil else { return nil }
        inFlight = second
        return second
    }

    /// The request in flight came back, with a still or without. Returns the second to ask for next.
    package mutating func landed(_ succeeded: Bool) -> Int? {
        let finished = inFlight
        inFlight = nil
        if succeeded {
            hasLanded = true
        } else if !hasLanded {
            isUnavailable = true
            wanted = nil
            return nil
        }
        guard let next = wanted, next != finished else {
            wanted = nil
            return nil
        }
        inFlight = next
        return next
    }

    /// The nearest of `held` to `second` within `reach` (`ScrubStills.standInReach` by default), shown until the right still
    /// arrives.
    package static func standIn(for second: Int, among held: some Sequence<Int>, reach: Int = ScrubStills.standInReach) -> Int? {
        held.filter { abs($0 - second) <= reach }.min { abs($0 - second) < abs($1 - second) }
    }
}

/// A part's whole preview index in Roku's BIF format, as `ScrubStills.indexPath` serves it: a 64-byte header (the magic,
/// a version, the number of stills and the milliseconds one timestamp unit stands for), then a table of timestamp and
/// byte offset pairs closed by a 0xFFFFFFFF entry, then the JPEG stills back to back. One download gives a scrubber every
/// still at once instead of asking the server for each second it passes, and the header and table alone say which bytes of
/// the file hold which still, so a scrubber can also ask for just the stills it shows.
package struct BIFIndex: Sendable, Equatable {
    package struct Frame: Sendable, Equatable {
        /// Where the still is taken, in seconds into the part.
        package let seconds: Double
        /// The still's JPEG bytes within the file.
        package let bytes: Range<Int>
    }

    /// A run of stills that sit back to back in the file, and the bytes that hold them.
    package struct Span: Sendable, Equatable {
        package let frames: Range<Int>
        package let bytes: Range<Int>
    }

    package let frames: [Frame]

    /// The size of the header, which says how long the table after it is (`tableLength`).
    package static let headerSize = 64
    private static let magic: [UInt8] = [0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]

    /// How many bytes the whole file is: where its last still ends.
    package var length: Int { frames.last?.bytes.upperBound ?? 0 }

    /// How many bytes from the start of the file hold the header and the whole table, read off the header; nil when
    /// `header` is not the start of a BIF file.
    package static func tableLength(header: Data) -> Int? {
        let bytes = [UInt8](header.prefix(headerSize))
        guard bytes.count == headerSize, Array(bytes[0..<8]) == magic, let count = word(12, of: bytes), count > 0 else { return nil }
        return headerSize + (Int(count) + 1) * 8
    }

    /// Reads the index of a whole file; nil when it is not a BIF file or its table points outside it.
    package init?(_ data: Data) {
        guard let index = BIFIndex(table: data), index.length <= data.count else { return nil }
        self = index
    }

    /// Reads the index off the start of a file, which has to reach at least to the end of the table (`tableLength`); nil
    /// when it is not a BIF file or its stills are out of order.
    package init?(table data: Data) {
        guard let length = Self.tableLength(header: data), data.count >= length else { return nil }
        let bytes = [UInt8](data.prefix(length))
        guard let unit = Self.word(16, of: bytes) else { return nil }
        let milliseconds = Double(unit == 0 ? 1000 : unit)
        let count = (length - Self.headerSize) / 8 - 1
        var frames: [Frame] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            let entry = Self.headerSize + index * 8
            guard let stamp = Self.word(entry, of: bytes), let start = Self.word(entry + 4, of: bytes),
                  let end = Self.word(entry + 12, of: bytes), Int(start) >= length, Int(start) < Int(end),
                  Int(start) >= frames.last?.bytes.upperBound ?? 0 else { return nil }
            frames.append(Frame(seconds: Double(stamp) * milliseconds / 1000, bytes: Int(start)..<Int(end)))
        }
        self.frames = frames
    }

    private static func word(_ offset: Int, of bytes: [UInt8]) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    /// The still that shows `seconds`: the last one taken at or before it, else the first.
    package func frame(at seconds: Double) -> Int? {
        guard !frames.isEmpty else { return nil }
        var low = 0
        var high = frames.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if frames[middle].seconds <= seconds { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// How many seconds lie between one still and the next.
    package var interval: Double {
        frames.count > 1 ? max((frames[frames.count - 1].seconds - frames[0].seconds) / Double(frames.count - 1), 0.001) : 1
    }

    /// How many spans of `size` stills the file divides into.
    package func spanCount(size: Int) -> Int {
        size > 0 ? (frames.count + size - 1) / size : 0
    }

    /// The `number`th run of `size` stills, the unit a scrubber fetches: one request brings a still and its neighbours.
    package func span(_ number: Int, size: Int) -> Span? {
        guard size > 0, number >= 0, number * size < frames.count else { return nil }
        let range = number * size..<min((number + 1) * size, frames.count)
        return Span(frames: range, bytes: frames[range.lowerBound].bytes.lowerBound..<frames[range.upperBound - 1].bytes.upperBound)
    }

    /// The spans of `size` stills in the order worth fetching them around `frame`: its own first, then the nearest on
    /// either side, the one ahead before the one behind.
    package func spansOutward(from frame: Int, size: Int) -> [Int] {
        let count = spanCount(size: size)
        guard count > 0 else { return [] }
        let home = min(max(frame, 0) / size, count - 1)
        var order = [home]
        var step = 1
        while order.count < count {
            if home + step < count { order.append(home + step) }
            if home - step >= 0 { order.append(home - step) }
            step += 1
        }
        return order
    }
}

/// Which stills a player makes itself for a file the server has none for, and in what order (`LocalStillMaker` on Linux).
/// The title is divided into slots with one still each. Where the scrubber points is always made first; while it rests
/// there its neighbours follow, so a small move shows its still at once; and from the first time the scrubber is pointed at,
/// an overview of the whole title fills in between those, spread evenly at every stage, so a jump anywhere shows a still
/// from nearby at once while its own is made.
package struct LocalStillPlan: Sendable, Equatable {
    /// How many seconds of the title one still stands for.
    package let interval: Double
    /// How many slots the title has.
    package let count: Int
    /// The overview's slots, in the order they are made.
    package let overview: [Int]

    /// The most slots a title is divided into, which is more than a pointer can tell apart along a bar.
    package static let mostSlots = 1000
    /// The shortest stretch of a title one still stands for, in seconds: keyframes rarely sit closer.
    package static let shortestInterval = 2.0
    /// How many stills the overview has.
    package static let overviewSize = 48
    /// How many slots either side of where the scrubber rests are made ahead of the overview.
    package static let neighbourhood = 3

    package init(duration: Double) {
        let length = duration.isFinite ? max(duration, 0) : 0
        interval = max(length / Double(Self.mostSlots), Self.shortestInterval)
        count = max(Int((length / interval).rounded(.up)), 1)
        overview = Self.spread(Self.overviewSize, over: count)
    }

    /// The slot `seconds` into the title falls in.
    package func slot(at seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        return min(max(Int(seconds / interval), 0), count - 1)
    }

    /// The moment a slot's still is taken at: its middle.
    package func moment(of slot: Int) -> Double {
        (Double(slot) + 0.5) * interval
    }

    /// How many slots away a held still may be and still stand in for one being made: as far as the overview's stills lie
    /// apart, and no less than `ScrubStills.standInReach` seconds.
    package var standInReach: Int {
        max((count + overview.count - 1) / max(overview.count, 1), Int(Double(ScrubStills.standInReach) / interval), 1)
    }

    /// The slot to make next, or nil when there is nothing left to make. `pointer` is the slot the scrubber points at
    /// now, when it points at one; `isSettled` says whether a slot's still is held or was found impossible to make.
    package func next(pointer: Int?, isSettled: (Int) -> Bool) -> Int? {
        if let pointer, (0..<count).contains(pointer) {
            if !isSettled(pointer) { return pointer }
            for distance in 1...Self.neighbourhood {
                for neighbour in [pointer + distance, pointer - distance] where (0..<count).contains(neighbour) && !isSettled(neighbour) {
                    return neighbour
                }
            }
        }
        return overview.first { !isSettled($0) }
    }

    /// `size` slots spread evenly over `count`, ordered so that every leading run of them is itself spread evenly: the
    /// middles of `size` equal stretches, taken in bit-reversed order.
    private static func spread(_ size: Int, over count: Int) -> [Int] {
        let wanted = min(size, count)
        var bits = 0
        while 1 << bits < wanted { bits += 1 }
        var slots: [Int] = []
        for index in 0..<(1 << bits) {
            var reversed = 0
            for bit in 0..<bits where index & (1 << bit) != 0 { reversed |= 1 << (bits - 1 - bit) }
            guard reversed < wanted else { continue }
            let slot = min(Int((Double(reversed) + 0.5) * Double(count) / Double(wanted)), count - 1)
            if !slots.contains(slot) { slots.append(slot) }
        }
        return slots
    }
}

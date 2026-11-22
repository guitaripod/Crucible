import Foundation

/// Unpacks gzip (RFC 1952) and raw DEFLATE (RFC 1951) data in plain Swift, so a compressed XMLTV guide reads the same on
/// every platform, Linux included, without a system library.
package enum Gunzip {
    package enum Failure: Error, Equatable {
        case truncated
        case badHeader
        case badBlock
        case badCode
        case badDistance
        case tooLarge
    }

    /// Whether `data` starts with gzip's magic bytes.
    package static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    /// The unpacked bytes of every member of a gzip file, refusing to grow past `limit` bytes.
    package static func unpack(_ data: Data, limit: Int = 1 << 30) throws -> Data {
        Data(try unpackBytes(data, limit: limit))
    }

    /// The unpacked bytes as an array, for a reader that scans them without another copy. On Apple platforms a single-member
    /// file goes through the system's zlib, which is far faster than the portable inflate; anything else takes the portable path.
    package static func unpackBytes(_ data: Data, limit: Int = 1 << 30) throws -> [UInt8] {
        let bytes = [UInt8](data)
        #if canImport(Darwin)
        if bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, let start = try? skipHeader(bytes, from: 0) {
            let size = Int(bytes[bytes.count - 4]) | Int(bytes[bytes.count - 3]) << 8 | Int(bytes[bytes.count - 2]) << 16 | Int(bytes[bytes.count - 1]) << 24
            if let inflated = try? (Data(bytes[start..<(bytes.count - 8)]) as NSData).decompressed(using: .zlib) as Data,
               UInt32(truncatingIfNeeded: inflated.count) == UInt32(truncatingIfNeeded: size) {
                guard inflated.count <= limit else { throw Failure.tooLarge }
                return [UInt8](inflated)
            }
        }
        #endif
        var output: [UInt8] = []
        output.reserveCapacity(min(bytes.count * 6, limit))
        var offset = 0
        while offset + 18 <= bytes.count, bytes[offset] == 0x1F, bytes[offset + 1] == 0x8B {
            offset = try skipHeader(bytes, from: offset)
            var inflater = Inflater(bytes: bytes, position: offset, limit: limit)
            try inflater.run(into: &output)
            offset = inflater.bytePosition + 8
        }
        guard !output.isEmpty || bytes.isEmpty else { throw Failure.badHeader }
        return output
    }

    /// The unpacked bytes of a raw DEFLATE stream.
    package static func inflate(_ data: Data, limit: Int = 1 << 30) throws -> Data {
        var output: [UInt8] = []
        var inflater = Inflater(bytes: [UInt8](data), position: 0, limit: limit)
        try inflater.run(into: &output)
        return Data(output)
    }

    private static func skipHeader(_ bytes: [UInt8], from start: Int) throws -> Int {
        guard bytes[start + 2] == 8 else { throw Failure.badHeader }
        let flags = bytes[start + 3]
        var offset = start + 10
        if flags & 0x04 != 0 {
            guard offset + 2 <= bytes.count else { throw Failure.truncated }
            offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8
        }
        if flags & 0x08 != 0 { offset = try skipString(bytes, from: offset) }
        if flags & 0x10 != 0 { offset = try skipString(bytes, from: offset) }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset <= bytes.count else { throw Failure.truncated }
        return offset
    }

    private static func skipString(_ bytes: [UInt8], from start: Int) throws -> Int {
        var offset = start
        while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
        guard offset < bytes.count else { throw Failure.truncated }
        return offset + 1
    }
}

/// A canonical Huffman code as DEFLATE builds it: how many codes of each length, and the symbols in code order.
private struct Huffman {
    var counts = [UInt16](repeating: 0, count: 16)
    var symbols: [UInt16]

    init(lengths: ArraySlice<UInt8>) {
        symbols = [UInt16](repeating: 0, count: lengths.count)
        for length in lengths { counts[Int(length)] += 1 }
        counts[0] = 0
        var offsets = [UInt16](repeating: 0, count: 16)
        for length in 1..<16 { offsets[length] = offsets[length - 1] + counts[length - 1] }
        for (symbol, length) in lengths.enumerated() where length != 0 {
            symbols[Int(offsets[Int(length)])] = UInt16(symbol)
            offsets[Int(length)] += 1
        }
    }
}

private struct Inflater {
    let bytes: [UInt8]
    var bytePosition: Int
    let limit: Int
    private var bitBuffer: UInt32 = 0
    private var bitCount: UInt32 = 0

    private static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra: [UInt32] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                                              4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtra: [UInt32] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private static let fixed: (Huffman, Huffman) = {
        var lengths = [UInt8](repeating: 8, count: 288)
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        return (Huffman(lengths: lengths[...]), Huffman(lengths: [UInt8](repeating: 5, count: 30)[...]))
    }()

    init(bytes: [UInt8], position: Int, limit: Int) {
        self.bytes = bytes
        self.bytePosition = position
        self.limit = limit
    }

    mutating func run(into output: inout [UInt8]) throws {
        var last = false
        while !last {
            last = try bits(1) == 1
            switch try bits(2) {
            case 0: try stored(into: &output)
            case 1: try codes(Self.fixed.0, Self.fixed.1, into: &output)
            case 2:
                let (lengths, distances) = try dynamicTables()
                try codes(lengths, distances, into: &output)
            default: throw Gunzip.Failure.badBlock
            }
        }
        bitBuffer = 0
        bitCount = 0
    }

    private mutating func bits(_ need: UInt32) throws -> UInt32 {
        while bitCount < need {
            guard bytePosition < bytes.count else { throw Gunzip.Failure.truncated }
            bitBuffer |= UInt32(bytes[bytePosition]) << bitCount
            bytePosition += 1
            bitCount += 8
        }
        let value = bitBuffer & ((1 << need) - 1)
        bitBuffer >>= need
        bitCount -= need
        return value
    }

    private mutating func stored(into output: inout [UInt8]) throws {
        bitBuffer = 0
        bitCount = 0
        guard bytePosition + 4 <= bytes.count else { throw Gunzip.Failure.truncated }
        let length = Int(bytes[bytePosition]) | Int(bytes[bytePosition + 1]) << 8
        let check = Int(bytes[bytePosition + 2]) | Int(bytes[bytePosition + 3]) << 8
        guard length == ~check & 0xFFFF else { throw Gunzip.Failure.badBlock }
        bytePosition += 4
        guard bytePosition + length <= bytes.count else { throw Gunzip.Failure.truncated }
        guard output.count + length <= limit else { throw Gunzip.Failure.tooLarge }
        output.append(contentsOf: bytes[bytePosition..<(bytePosition + length)])
        bytePosition += length
    }

    private mutating func decode(_ huffman: Huffman) throws -> Int {
        var code = 0
        var first = 0
        var index = 0
        for length in 1..<16 {
            code |= Int(try bits(1))
            let count = Int(huffman.counts[length])
            if code - count < first { return Int(huffman.symbols[index + (code - first)]) }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw Gunzip.Failure.badCode
    }

    private mutating func codes(_ lengths: Huffman, _ distances: Huffman, into output: inout [UInt8]) throws {
        while true {
            let symbol = try decode(lengths)
            if symbol < 256 {
                guard output.count < limit else { throw Gunzip.Failure.tooLarge }
                output.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                let index = symbol - 257
                guard index < Self.lengthBase.count else { throw Gunzip.Failure.badCode }
                let length = Self.lengthBase[index] + Int(try bits(Self.lengthExtra[index]))
                let distanceSymbol = try decode(distances)
                guard distanceSymbol < Self.distanceBase.count else { throw Gunzip.Failure.badDistance }
                let distance = Self.distanceBase[distanceSymbol] + Int(try bits(Self.distanceExtra[distanceSymbol]))
                guard distance <= output.count else { throw Gunzip.Failure.badDistance }
                guard output.count + length <= limit else { throw Gunzip.Failure.tooLarge }
                let start = output.count - distance
                for offset in 0..<length { output.append(output[start + offset]) }
            }
        }
    }

    private mutating func dynamicTables() throws -> (Huffman, Huffman) {
        let literalCount = Int(try bits(5)) + 257
        let distanceCount = Int(try bits(5)) + 1
        let codeCount = Int(try bits(4)) + 4
        var codeLengths = [UInt8](repeating: 0, count: 19)
        for i in 0..<codeCount { codeLengths[Self.codeLengthOrder[i]] = UInt8(try bits(3)) }
        let codeHuffman = Huffman(lengths: codeLengths[...])
        var lengths = [UInt8](repeating: 0, count: literalCount + distanceCount)
        var index = 0
        while index < lengths.count {
            let symbol = try decode(codeHuffman)
            if symbol < 16 {
                lengths[index] = UInt8(symbol)
                index += 1
                continue
            }
            var repeated: UInt8 = 0
            var times: Int
            switch symbol {
            case 16:
                guard index > 0 else { throw Gunzip.Failure.badBlock }
                repeated = lengths[index - 1]
                times = 3 + Int(try bits(2))
            case 17: times = 3 + Int(try bits(3))
            default: times = 11 + Int(try bits(7))
            }
            guard index + times <= lengths.count else { throw Gunzip.Failure.badBlock }
            for _ in 0..<times {
                lengths[index] = repeated
                index += 1
            }
        }
        return (Huffman(lengths: lengths[0..<literalCount]), Huffman(lengths: lengths[literalCount...]))
    }
}

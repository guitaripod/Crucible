import Foundation

/// A small deterministic generator (SplitMix64) so the same date always produces the same viewing history.
struct DemoRandom: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    init(_ parts: UInt64...) {
        state = parts.reduce(0x9E37_79B9_7F4A_7C15) { Self.mix($0 ^ $1) }
    }

    static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        return Self.mix(state &- 0x9E37_79B9_7F4A_7C15)
    }

    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func chance(_ probability: Double) -> Bool {
        unit() < probability
    }

    mutating func weightedIndex(_ weights: [Int]) -> Int {
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        var roll = Int(next() % UInt64(total))
        for (index, weight) in weights.enumerated() {
            if roll < weight { return index }
            roll -= weight
        }
        return weights.count - 1
    }

    mutating func pick<T>(_ values: [T]) -> T {
        values[Int(next() % UInt64(values.count))]
    }
}

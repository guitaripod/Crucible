import Foundation

/// The placeholder portrait of a cast or crew member: initials over a gradient that never changes for a given name.
package enum CastAvatar {
    package struct Gradient: Equatable, Sendable {
        package let start: UInt32
        package let end: UInt32
    }

    private static let palettes: [Gradient] = [
        Gradient(start: 0x2B2455, end: 0xB0483F),
        Gradient(start: 0x0F3D3E, end: 0x1D7A73),
        Gradient(start: 0x3A1A52, end: 0x8B2F7A),
        Gradient(start: 0x101A33, end: 0x1F3F7A),
        Gradient(start: 0x26402C, end: 0x4F7A45),
        Gradient(start: 0x6B2A3A, end: 0x7E3346),
    ]

    /// Hex colours of the gradient for `name`, as `0xRRGGBB`.
    package static func gradient(for name: String) -> Gradient {
        palettes[stableIndex(name, count: palettes.count)]
    }

    /// Deterministic across launches (unlike `hashValue`), so a person keeps their colour.
    package static func stableIndex(_ name: String, count: Int) -> Int {
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
        return sum % count
    }
}

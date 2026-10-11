package enum GenrePalette {
    package static let pairs: [(start: UInt32, end: UInt32)] = [
        (0x7A2A1A, 0xE0643A),
        (0x7A5A14, 0xE7B53A),
        (0x2A2A66, 0x6A6AE0),
        (0x0E4A52, 0x2FB8C4),
        (0x2F4A1F, 0x8FC04A),
        (0x5A1F5A, 0xD05AB8),
        (0x1F3A5A, 0x4A90D9),
        (0x1A4A3A, 0x3AD08F),
    ]

    private static let knownSlots: [String: Int] = [
        "action": 0, "adventure": 1, "drama": 2, "sci-fi": 3, "science fiction": 3, "comedy": 4,
        "animation": 5, "thriller": 6, "mystery": 7, "documentary": 7, "horror": 0, "fantasy": 2,
        "romance": 5, "crime": 6, "family": 1, "western": 1, "war": 0, "music": 5,
    ]

    /// A stable palette slot for a genre name. `String.hashValue` is randomised per launch, so the
    /// slot is derived from the unicode scalars instead.
    package static func pair(for title: String) -> (start: UInt32, end: UInt32) {
        if let slot = knownSlots[title.lowercased()] { return pairs[slot] }
        let sum = title.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 9973 }
        return pairs[sum % pairs.count]
    }
}

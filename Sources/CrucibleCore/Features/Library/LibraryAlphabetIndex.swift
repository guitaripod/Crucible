import Foundation

struct LibraryFirstCharacterResponse: Decodable, Sendable {
    let MediaContainer: Container

    struct Container: Decodable, Sendable {
        let Directory: [Entry]?
    }

    struct Entry: Decodable, Sendable {
        let key: String?
        let title: String?
        let size: Int?
    }
}

/// Maps the section's `firstCharacter` counts onto item offsets in a title-ascending listing.
package struct LibraryAlphabetIndex: Sendable {
    package static let letters: [String] = (UnicodeScalar("A").value...UnicodeScalar("Z").value)
        .compactMap { UnicodeScalar($0).map { String(Character($0)) } } + ["#"]

    private var offsets: [String: Int] = [:]
    private var boundaries: [(offset: Int, letter: String)] = []

    init(entries: [LibraryFirstCharacterResponse.Entry]) {
        var running = 0
        for entry in entries {
            let count = max(entry.size ?? 0, 0)
            guard count > 0 else { continue }
            let letter = Self.normalized(entry.key ?? entry.title)
            if offsets[letter] == nil {
                offsets[letter] = running
                boundaries.append((running, letter))
            }
            running += count
        }
    }

    package var isUsable: Bool { offsets.count >= 2 }

    /// The letters that have items, in alphabet order.
    package var availableLetters: [String] {
        Self.letters.filter { offsets[$0] != nil }
    }

    /// The listing offset where `letter` starts, falling forward to the next letter that has items
    /// and back to the last one when nothing follows.
    package func offset(for letter: String) -> Int? {
        if let exact = offsets[letter] { return exact }
        guard letter != "#", let start = Self.letters.firstIndex(of: letter) else { return nil }
        for candidate in Self.letters[start...] where candidate != "#" {
            if let offset = offsets[candidate] { return offset }
        }
        return boundaries.filter { $0.letter != "#" }.last?.offset
    }

    package func letter(atOffset offset: Int) -> String? {
        boundaries.last { $0.offset <= offset }?.letter ?? boundaries.first?.letter
    }

    /// The letter a vertical position resolves to when the whole alphabet is spread over a strip,
    /// `fraction` being 0 at the top and 1 at the bottom.
    package static func letter(atFraction fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 0.9999)
        return letters[Int(clamped * Double(letters.count))]
    }

    /// The letter `delta` steps from `current`, stopping at either end. With no current letter either
    /// direction lands on the first letter.
    package static func letter(from current: String?, offsetBy delta: Int) -> String {
        let start = current.flatMap { letters.firstIndex(of: $0) } ?? -delta
        return letters[min(max(start + delta, 0), letters.count - 1)]
    }

    private static func normalized(_ raw: String?) -> String {
        guard let first = raw?.trimmingCharacters(in: .whitespaces).first else { return "#" }
        let folded = String(first).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).uppercased()
        return letters.contains(folded) && folded != "#" ? folded : "#"
    }
}

import Foundation

/// The search the tour types for the user: a word taken from a title in the library on screen, so the demo never depends on a fixed title.
package enum DemoPhoneSearchSample {
    package static let shortest = 3

    /// The first word, over the titles in order, that is long enough to be worth searching for.
    package static func query(fromTitles titles: [String]) -> String? {
        for title in titles {
            let words = title.split { !$0.isLetter }
            if let word = words.first(where: { $0.count >= shortest }) {
                return String(word)
            }
        }
        return nil
    }
}

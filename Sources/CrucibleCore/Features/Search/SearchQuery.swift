import Foundation

package enum SearchQuery {
    package static let minimumLength = 2

    /// The text the user typed, trimmed of surrounding whitespace and newlines.
    package static func normalized(_ raw: String?) -> String {
        (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a normalised query is long enough to hit the server.
    package static func isSearchable(_ query: String) -> Bool {
        query.count >= minimumLength
    }
}

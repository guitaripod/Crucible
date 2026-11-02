import Foundation

package enum SearchCopy {
    package static let placeholder = String(localized: "Movies, shows, episodes")
    package static let idleTitle = String(localized: "Search your library")
    package static let idleMessage = String(localized: "Find movies, shows and episodes.")
    package static let clearRecents = String(localized: "Clear")
    package static let removeRecent = String(localized: "Remove")
    package static let failureTitle = String(localized: "Search Failed")
    package static let retry = String(localized: "Try Again")

    package static func noResultsTitle(query: String) -> String {
        String(localized: "No results for \u{201C}\(query)\u{201D}")
    }

    package static func noResultsHint(scope: SearchScope) -> String {
        scope == .all ? String(localized: "Check the spelling or try a different search.") : String(localized: "Try the All scope.")
    }

    package static func genreEmptyTitle(_ genre: String) -> String {
        String(localized: "No \(genre) Titles")
    }

    package static let genreEmptyMessage = String(localized: "Nothing in your libraries is tagged with this genre.")

    package static func genreFailureTitle(_ genre: String) -> String {
        String(localized: "Couldn\u{2019}t Load \(genre)")
    }

    package static let topResultEyebrow = String(localized: "Top Result")

    /// The alert title when marking a title watched (`true`) or unwatched (`false`) failed.
    package static func watchedFailureTitle(watched: Bool) -> String {
        watched ? String(localized: "Couldn\u{2019}t Mark Watched") : String(localized: "Couldn\u{2019}t Mark Unwatched")
    }
}

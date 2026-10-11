package enum SearchCopy {
    package static let placeholder = "Movies, shows, episodes"
    package static let idleTitle = "Search your library"
    package static let idleMessage = "Find movies, shows and episodes."
    package static let clearRecents = "Clear"
    package static let removeRecent = "Remove"
    package static let failureTitle = "Search Failed"
    package static let retry = "Try Again"

    package static func noResultsTitle(query: String) -> String {
        "No results for \u{201C}\(query)\u{201D}"
    }

    package static func noResultsHint(scope: SearchScope) -> String {
        scope == .all ? "Check the spelling or try a different search." : "Try the All scope."
    }

    package static func genreEmptyTitle(_ genre: String) -> String {
        "No \(genre) Titles"
    }

    package static let genreEmptyMessage = "Nothing in your libraries is tagged with this genre."

    package static func genreFailureTitle(_ genre: String) -> String {
        "Couldn\u{2019}t Load \(genre)"
    }

    package static let topResultEyebrow = "Top Result"

    /// The alert title when marking a title watched (`true`) or unwatched (`false`) failed.
    package static func watchedFailureTitle(watched: Bool) -> String {
        watched ? "Couldn\u{2019}t Mark Watched" : "Couldn\u{2019}t Mark Unwatched"
    }
}

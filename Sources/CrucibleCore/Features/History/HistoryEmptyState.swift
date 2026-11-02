import Foundation

/// What the history screen shows instead of, or besides, the list. `.loading` has no copy: iPhone leaves
/// whatever is on screen until the load ends, tvOS shows a spinner.
package enum HistoryEmptyState: Equatable, Sendable {
    case populated
    case loading
    case noActivity
    case loadFailed
    case noMatches(HistoryFilter)

    package struct Content: Equatable, Sendable {
        package let symbolName: String
        package let title: String
        package let message: String?
    }

    package var content: Content? {
        switch self {
        case .populated, .loading:
            return nil
        case .noActivity:
            return Content(symbolName: "clock", title: String(localized: "No activity yet"), message: String(localized: "Movies and episodes you watch will show up here."))
        case .loadFailed:
            return Content(symbolName: "wifi.exclamationmark", title: String(localized: "Couldn't load history"), message: String(localized: "Check your connection and try again."))
        case .noMatches(let filter):
            let isMovies = filter == .movies
            return Content(symbolName: isMovies ? "film" : "tv", title: isMovies ? String(localized: "No movies watched yet") : String(localized: "No TV watched yet"), message: nil)
        }
    }
}

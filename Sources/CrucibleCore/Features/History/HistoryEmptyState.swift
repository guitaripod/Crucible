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
            return Content(symbolName: "clock", title: "No activity yet", message: "Movies and episodes you watch will show up here.")
        case .loadFailed:
            return Content(symbolName: "wifi.exclamationmark", title: "Couldn't load history", message: "Check your connection and try again.")
        case .noMatches(let filter):
            let isMovies = filter == .movies
            return Content(symbolName: isMovies ? "film" : "tv", title: isMovies ? "No movies watched yet" : "No TV watched yet", message: nil)
        }
    }
}

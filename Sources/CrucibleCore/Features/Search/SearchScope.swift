import Foundation

package enum SearchScope: Int, CaseIterable, Sendable {
    case all, movies, shows, episodes

    package var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .movies: return String(localized: "Movies")
        case .shows: return String(localized: "Shows")
        case .episodes: return String(localized: "Episodes")
        }
    }

    package func includes(_ mediaType: String) -> Bool {
        switch self {
        case .all: return true
        case .movies: return mediaType == "movie"
        case .shows: return mediaType == "show"
        case .episodes: return mediaType == "episode"
        }
    }
}

package enum SearchSection: Int, Hashable, Sendable {
    case recent, browse, recentlyAdded, topResult, movies, shows, episodes, elsewhere

    package var title: String? {
        switch self {
        case .recent: return String(localized: "Recent")
        case .browse: return String(localized: "Browse")
        case .recentlyAdded: return String(localized: "Recently Added")
        case .topResult: return nil
        case .movies: return String(localized: "Movies")
        case .shows: return String(localized: "Shows")
        case .episodes: return String(localized: "Episodes")
        case .elsewhere: return SeerrCopy.notConnectedTitle
        }
    }
}

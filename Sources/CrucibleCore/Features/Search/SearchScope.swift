package enum SearchScope: Int, CaseIterable, Sendable {
    case all, movies, shows, episodes

    package var title: String {
        switch self {
        case .all: return "All"
        case .movies: return "Movies"
        case .shows: return "Shows"
        case .episodes: return "Episodes"
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
    case recent, browse, recentlyAdded, topResult, movies, shows, episodes

    package var title: String? {
        switch self {
        case .recent: return "Recent"
        case .browse: return "Browse"
        case .recentlyAdded: return "Recently Added"
        case .topResult: return nil
        case .movies: return "Movies"
        case .shows: return "Shows"
        case .episodes: return "Episodes"
        }
    }
}

import CrucibleCore

enum TVSearchSection: Hashable {
    case scopes, recent, browse, recentlyAdded, topResult, movies, shows, episodes

    var title: String? {
        switch self {
        case .scopes, .topResult: return nil
        case .recent: return String(localized: "Recent Searches")
        case .browse: return String(localized: "Browse Genres")
        case .recentlyAdded: return String(localized: "Recently Added")
        case .movies: return String(localized: "Movies")
        case .shows: return String(localized: "Shows")
        case .episodes: return String(localized: "Episodes")
        }
    }
}

enum TVSearchItem: Hashable {
    case scope(SearchScope)
    case recent(String)
    case clearRecents
    case genre(SearchGenre)
    case recentlyAdded(PlexMetadata)
    case top(PlexMetadata)
    case movie(PlexMetadata)
    case show(PlexMetadata)
    case episode(PlexMetadata)

    var metadata: PlexMetadata? {
        switch self {
        case .scope, .recent, .clearRecents, .genre: return nil
        case .recentlyAdded(let item), .top(let item), .movie(let item), .show(let item), .episode(let item): return item
        }
    }

    var isSearchResult: Bool {
        switch self {
        case .top, .movie, .show, .episode: return true
        case .scope, .recent, .clearRecents, .genre, .recentlyAdded: return false
        }
    }
}

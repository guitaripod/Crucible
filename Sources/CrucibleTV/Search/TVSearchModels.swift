import CrucibleCore

enum TVSearchSection: Hashable {
    case scopes, recent, browse, recentlyAdded, topResult, movies, shows, episodes

    var title: String? {
        switch self {
        case .scopes, .topResult: return nil
        case .recent: return "Recent Searches"
        case .browse: return "Browse Genres"
        case .recentlyAdded: return "Recently Added"
        case .movies: return "Movies"
        case .shows: return "Shows"
        case .episodes: return "Episodes"
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

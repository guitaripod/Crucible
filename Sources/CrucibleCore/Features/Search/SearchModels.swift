import Foundation

package struct GenreSource: Hashable, Sendable {
    package let sectionId: String
    package let key: String

    package init(sectionId: String, key: String) {
        self.sectionId = sectionId
        self.key = key
    }
}

package struct SearchGenre: Hashable, Sendable {
    package let title: String
    package let sources: [GenreSource]

    package init(title: String, sources: [GenreSource]) {
        self.title = title
        self.sources = sources
    }
}

package enum SearchItem: Hashable, Sendable {
    case recent(String)
    case genre(SearchGenre)
    case recentlyAdded(PlexMetadata)
    case top(PlexMetadata)
    case movie(PlexMetadata)
    case show(PlexMetadata)
    case episode(PlexMetadata)
    /// A title only Seerr found, to request.
    case elsewhere(SeerrSearchHit)

    package var metadata: PlexMetadata? {
        switch self {
        case .recent, .genre, .elsewhere: return nil
        case .recentlyAdded(let m), .top(let m), .movie(let m), .show(let m), .episode(let m): return m
        }
    }

    package var isSearchResult: Bool {
        switch self {
        case .top, .movie, .show, .episode, .elsewhere: return true
        case .recent, .genre, .recentlyAdded: return false
        }
    }
}

package struct SearchResults: Sendable {
    package let ordered: [PlexMetadata]
    /// What Seerr found that the server does not have, when Seerr is connected.
    package var elsewhere: [SeerrSearchHit] = []

    package init(hubs: [PlexHub], excluding excluded: Set<Int> = []) {
        var seen = Set<String>()
        var flat = [PlexMetadata]()
        for hub in hubs {
            for item in LibraryVisibility.shown(hub.Metadata ?? [], excluding: excluded) where Self.supportedTypes.contains(item.mediaType) {
                if seen.insert(item.id).inserted { flat.append(item) }
            }
        }
        ordered = flat
    }

    private static let supportedTypes: Set<String> = ["movie", "show", "episode"]

    package struct Parts: Equatable, Sendable {
        package let top: PlexMetadata?
        package let movies: [PlexMetadata]
        package let shows: [PlexMetadata]
        package let episodes: [PlexMetadata]
        package var elsewhere: [SeerrSearchHit] = []

        package var isEmpty: Bool { top == nil && elsewhere.isEmpty }

        package static let empty = Parts(top: nil, movies: [], shows: [], episodes: [])
    }

    package func parts(for scope: SearchScope) -> Parts {
        let visible = ordered.filter { scope.includes($0.mediaType) }
        return Parts(
            top: visible.first,
            movies: visible.filter { $0.mediaType == "movie" },
            shows: visible.filter { $0.mediaType == "show" },
            episodes: visible.filter { $0.mediaType == "episode" },
            elsewhere: elsewhere.filter { hit in
                switch scope {
                case .all: return true
                case .movies: return hit.kind == .movie
                case .shows: return hit.kind == .tv
                case .episodes: return false
                }
            }
        )
    }
}

package struct SearchIdleContent: Equatable, Sendable {
    package let recents: [String]
    package let genres: [SearchGenre]
    package let recentlyAdded: [PlexMetadata]

    package var isEmpty: Bool { recents.isEmpty && genres.isEmpty && recentlyAdded.isEmpty }
}

package enum SearchState: Equatable, Sendable {
    case idle(SearchIdleContent)
    case loading
    case results(query: String, parts: SearchResults.Parts)
    case empty(query: String, scope: SearchScope)
    case failed(query: String, message: String)
}

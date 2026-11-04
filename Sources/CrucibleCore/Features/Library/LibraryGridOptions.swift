import Foundation

package enum LibraryGridKind: Sendable {
    case movie, show

    package init?(sectionType: String?) {
        switch sectionType {
        case "movie": self = .movie
        case "show": self = .show
        default: return nil
        }
    }

    package var defaultTitle: String {
        switch self {
        case .movie: return String(localized: "Movies", comment: "Media type: films, as a plural")
        case .show: return String(localized: "TV Shows")
        }
    }

    package var sortOptions: [LibrarySortOption] {
        switch self {
        case .movie:
            return [
                LibrarySortOption(key: LibraryGridOptions.titleAscending, title: String(localized: "Title", comment: "Sort option: by title")),
                LibrarySortOption(key: "year:desc", title: String(localized: "Year", comment: "Sort option: by release year")),
                LibrarySortOption(key: "addedAt:desc", title: String(localized: "Recently Added")),
                LibrarySortOption(key: "rating:desc", title: String(localized: "Rating", comment: "Sort option: by rating")),
                LibrarySortOption(key: "userRating:desc", title: UserRatingCopy.title),
                LibrarySortOption(key: "originallyAvailableAt:desc", title: String(localized: "Release Date", comment: "Sort option: by the date the title came out")),
                LibrarySortOption(key: "lastViewedAt:desc", title: String(localized: "Last Watched", comment: "Sort option: by when the viewer last watched it")),
                LibrarySortOption(key: "viewCount:desc", title: String(localized: "Most Watched", comment: "Sort option: by how often the viewer watched it")),
            ]
        case .show:
            return [
                LibrarySortOption(key: LibraryGridOptions.titleAscending, title: String(localized: "Name", comment: "Sort option: by name")),
                LibrarySortOption(key: "addedAt:desc", title: String(localized: "Recently Added")),
                LibrarySortOption(key: "rating:desc", title: String(localized: "Rating", comment: "Sort option: by rating")),
                LibrarySortOption(key: "userRating:desc", title: UserRatingCopy.title),
                LibrarySortOption(key: "originallyAvailableAt:desc", title: String(localized: "Release Date", comment: "Sort option: by the date the title came out")),
                LibrarySortOption(key: "lastViewedAt:desc", title: String(localized: "Last Watched", comment: "Sort option: by when the viewer last watched it")),
            ]
        }
    }

    package var placeholderIcon: String {
        switch self {
        case .movie: return "film"
        case .show: return "tv"
        }
    }

    package var emptyTitle: String {
        switch self {
        case .movie: return String(localized: "No Movies")
        case .show: return String(localized: "No Shows")
        }
    }

    package var logName: String {
        switch self {
        case .movie: return "MovieGrid"
        case .show: return "ShowGrid"
        }
    }

    /// A show library's history rail collapses to one card per series; a movie library's keys on the film.
    package var groupsHistoryByShow: Bool { self == .show }
}

package struct LibrarySortOption: Equatable, Sendable {
    package let key: String
    package let title: String

    package init(key: String, title: String) {
        self.key = key
        self.title = title
    }
}

package struct LibraryGenre: Equatable, Sendable {
    package let key: String
    package let title: String

    package init(key: String, title: String) {
        self.key = key
        self.title = title
    }
}

package enum LibraryWatchFilter: String, CaseIterable, Sendable {
    case all, unwatched, inProgress

    package var title: String {
        switch self {
        case .all: return String(localized: "All", comment: "Filter option that shows every item")
        case .unwatched: return String(localized: "Unwatched", comment: "Filter option that shows unwatched items")
        case .inProgress: return String(localized: "In Progress")
        }
    }

    package var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .unwatched: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        }
    }
}

/// The single source of truth for what a library grid shows; the chips row and the
/// navigation-bar options menu both read and write this value.
package struct LibraryGridOptions: Equatable, Sendable {
    package static let titleAscending = "titleSort:asc"

    package var sort = titleAscending
    package var genre: String?
    package var facets: [LibraryFacet: String] = [:]
    package var watch: LibraryWatchFilter = .all

    package init() {}

    package var isFiltering: Bool { genre != nil || !facets.isEmpty || watch != .all }

    /// The A–Z index counts every item in the section, so it only lines up with the grid when the
    /// grid is the whole section sorted by title.
    package var allowsAlphabetJump: Bool { sort == Self.titleAscending && !isFiltering }

    package func endpoint(sectionId: String, start: Int, size: Int) -> PlexEndpoint {
        .sectionItems(
            sectionId: sectionId,
            sort: sort,
            genre: genre,
            start: start,
            size: size,
            unwatched: watch == .unwatched,
            inProgress: watch == .inProgress,
            filters: Dictionary(uniqueKeysWithValues: facets.map { ($0.key.queryName, $0.value) })
        )
    }

    /// "All" clears every filter, so it is only lit when nothing narrows the grid; the other two
    /// toggle the server-side watch filter and leave a chosen genre in place.
    package func isChipSelected(_ filter: LibraryWatchFilter) -> Bool {
        filter == .all ? !isFiltering : watch == filter
    }

    package func selectingChip(_ filter: LibraryWatchFilter) -> LibraryGridOptions {
        var next = self
        next.watch = filter
        if filter == .all {
            next.genre = nil
            next.facets = [:]
        }
        return next
    }

    package func clearingFilters() -> LibraryGridOptions {
        var next = self
        next.genre = nil
        next.facets = [:]
        next.watch = .all
        return next
    }

    package func genreTitle(in genres: [LibraryGenre]) -> String {
        genres.first { $0.key == genre }?.title ?? String(localized: "Genre", comment: "Filter label for the genre menu")
    }

    /// The button label of a facet's menu: the chosen value, or the facet's own name while nothing is chosen.
    package func facetTitle(_ facet: LibraryFacet, in choices: [LibraryFacetChoice]) -> String {
        guard let key = facets[facet] else { return facet.title }
        return choices.first { $0.key == key }.map { facet.display($0.title) } ?? facet.title
    }

    package func sortTitle(for kind: LibraryGridKind) -> String {
        kind.sortOptions.first { $0.key == sort }?.title ?? String(localized: "Title", comment: "Sort option: by title")
    }
}

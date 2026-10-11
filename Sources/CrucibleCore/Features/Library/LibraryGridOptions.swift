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
        case .movie: return "Movies"
        case .show: return "TV Shows"
        }
    }

    package var sortOptions: [LibrarySortOption] {
        switch self {
        case .movie:
            return [
                LibrarySortOption(key: LibraryGridOptions.titleAscending, title: "Title"),
                LibrarySortOption(key: "year:desc", title: "Year"),
                LibrarySortOption(key: "addedAt:desc", title: "Recently Added"),
                LibrarySortOption(key: "rating:desc", title: "Rating"),
            ]
        case .show:
            return [
                LibrarySortOption(key: LibraryGridOptions.titleAscending, title: "Name"),
                LibrarySortOption(key: "addedAt:desc", title: "Recently Added"),
                LibrarySortOption(key: "rating:desc", title: "Rating"),
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
        case .movie: return "No Movies"
        case .show: return "No Shows"
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
        case .all: return "All"
        case .unwatched: return "Unwatched"
        case .inProgress: return "In Progress"
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
    package var watch: LibraryWatchFilter = .all

    package init() {}

    package var isFiltering: Bool { genre != nil || watch != .all }

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
            inProgress: watch == .inProgress
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
        if filter == .all { next.genre = nil }
        return next
    }

    package func clearingFilters() -> LibraryGridOptions {
        var next = self
        next.genre = nil
        next.watch = .all
        return next
    }

    package func genreTitle(in genres: [LibraryGenre]) -> String {
        genres.first { $0.key == genre }?.title ?? "Genre"
    }

    package func sortTitle(for kind: LibraryGridKind) -> String {
        kind.sortOptions.first { $0.key == sort }?.title ?? "Title"
    }
}

import Foundation
import Testing
@testable import CrucibleCore

struct LibraryGridOptionsTests {
    @Test func sortOptionsDifferPerKind() {
        #expect(LibraryGridKind.movie.sortOptions.map(\.title) == ["Title", "Year", "Recently Added", "Rating"])
        #expect(LibraryGridKind.show.sortOptions.map(\.title) == ["Name", "Recently Added", "Rating"])
        #expect(LibraryGridKind.movie.sortOptions.map(\.key) == ["titleSort:asc", "year:desc", "addedAt:desc", "rating:desc"])
        #expect(LibraryGridKind.show.sortOptions.map(\.key) == ["titleSort:asc", "addedAt:desc", "rating:desc"])
    }

    @Test func kindsReadSectionTypesAndNameThemselves() {
        #expect(LibraryGridKind(sectionType: "movie") == .movie)
        #expect(LibraryGridKind(sectionType: "show") == .show)
        #expect(LibraryGridKind(sectionType: "artist") == nil)
        #expect(LibraryGridKind(sectionType: nil) == nil)
        #expect(LibraryGridKind.movie.emptyTitle == "No Movies")
        #expect(LibraryGridKind.show.emptyTitle == "No Shows")
        #expect(LibraryGridKind.movie.defaultTitle == "Movies")
        #expect(LibraryGridKind.show.defaultTitle == "TV Shows")
        #expect(LibraryGridKind.movie.placeholderIcon == "film")
        #expect(LibraryGridKind.show.placeholderIcon == "tv")
        #expect(!LibraryGridKind.movie.groupsHistoryByShow)
        #expect(LibraryGridKind.show.groupsHistoryByShow)
    }

    @Test func watchFiltersNameThemselves() {
        #expect(LibraryWatchFilter.allCases.map(\.title) == ["All", "Unwatched", "In Progress"])
        #expect(LibraryWatchFilter.allCases.map(\.rawValue) == ["all", "unwatched", "inProgress"])
        #expect(LibraryWatchFilter.inProgress.symbol == "circle.lefthalf.filled")
    }

    @Test func defaultOptionsSortByTitleWithoutFilters() {
        let options = LibraryGridOptions()
        #expect(options.sort == "titleSort:asc")
        #expect(options.genre == nil)
        #expect(options.watch == .all)
        #expect(!options.isFiltering)
        #expect(options.allowsAlphabetJump)
    }

    @Test func filtersAndOtherSortsDisableTheAlphabetJump() {
        var byGenre = LibraryGridOptions()
        byGenre.genre = "12"
        #expect(byGenre.isFiltering)
        #expect(!byGenre.allowsAlphabetJump)

        var unwatched = LibraryGridOptions()
        unwatched.watch = .unwatched
        #expect(unwatched.isFiltering)
        #expect(!unwatched.allowsAlphabetJump)

        var byYear = LibraryGridOptions()
        byYear.sort = "year:desc"
        #expect(!byYear.isFiltering)
        #expect(!byYear.allowsAlphabetJump)
    }

    @Test func endpointCarriesSortGenreAndWatchFilters() {
        var options = LibraryGridOptions()
        options.sort = "year:desc"
        options.genre = "7"
        options.watch = .inProgress
        let endpoint = options.endpoint(sectionId: "3", start: 100, size: 50)
        let values = Dictionary(uniqueKeysWithValues: (endpoint.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(endpoint.path == "/library/sections/3/all")
        #expect(values["sort"] == "year:desc")
        #expect(values["genre"] == "7")
        #expect(values["X-Plex-Container-Start"] == "100")
        #expect(values["X-Plex-Container-Size"] == "50")
        #expect(values["inProgress"] == "1")
        #expect(values["unwatched"] == nil)
    }

    @Test func allChipIsLitOnlyWhenNothingFilters() {
        var options = LibraryGridOptions()
        #expect(options.isChipSelected(.all))
        #expect(!options.isChipSelected(.unwatched))

        options.genre = "7"
        #expect(!options.isChipSelected(.all))

        options.watch = .unwatched
        #expect(options.isChipSelected(.unwatched))
        #expect(!options.isChipSelected(.inProgress))
    }

    @Test func selectingAWatchChipKeepsTheGenreButAllClearsIt() {
        var options = LibraryGridOptions()
        options.genre = "7"
        let unwatched = options.selectingChip(.unwatched)
        #expect(unwatched.watch == .unwatched)
        #expect(unwatched.genre == "7")
        let all = unwatched.selectingChip(.all)
        #expect(all.watch == .all)
        #expect(all.genre == nil)
    }

    @Test func clearingFiltersKeepsTheSort() {
        var options = LibraryGridOptions()
        options.sort = "rating:desc"
        options.genre = "7"
        options.watch = .unwatched
        let cleared = options.clearingFilters()
        #expect(cleared.sort == "rating:desc")
        #expect(cleared.genre == nil)
        #expect(cleared.watch == .all)
        #expect(!cleared.isFiltering)
    }

    @Test func chipTitlesFollowTheChosenGenreAndSort() {
        let genres = [LibraryGenre(key: "7", title: "Drama"), LibraryGenre(key: "8", title: "Comedy")]
        var options = LibraryGridOptions()
        #expect(options.genreTitle(in: genres) == "Genre")
        options.genre = "8"
        #expect(options.genreTitle(in: genres) == "Comedy")
        options.genre = "99"
        #expect(options.genreTitle(in: genres) == "Genre")

        #expect(options.sortTitle(for: .movie) == "Title")
        options.sort = "year:desc"
        #expect(options.sortTitle(for: .movie) == "Year")
        #expect(options.sortTitle(for: .show) == "Title")
    }
}

import Foundation
import Testing
@testable import CrucibleCore

enum LibraryFixtures {
    static func container(_ json: String) throws -> PlexMediaContainer {
        try JSONDecoder().decode(PlexResponse.self, from: Data(json.utf8)).MediaContainer
    }

    static func items(_ json: String) throws -> [PlexMetadata] {
        try container(#"{"MediaContainer":{"Metadata":\#(json)}}"#).Metadata ?? []
    }

    static func item(_ json: String) throws -> PlexMetadata {
        try #require(items("[\(json)]").first)
    }

    static func history(_ json: String) throws -> [PlexHistoryEntry] {
        let response = try JSONDecoder().decode(PlexHistoryResponse.self, from: Data(#"{"MediaContainer":{"Metadata":\#(json)}}"#.utf8))
        return response.MediaContainer.Metadata ?? []
    }
}

struct LibraryItemsTests {
    @Test func moviePosterShowsProgressWhenPartWatched() throws {
        let item = try LibraryFixtures.item(#"{"ratingKey":"1","type":"movie","title":"Halcyon","year":2021,"thumb":"/t","viewOffset":300000,"duration":1200000,"viewCount":0}"#)
        let poster = LibraryPoster(grid: item, kind: .movie)
        #expect(poster.title == "Halcyon")
        #expect(poster.subtitle == "2021")
        #expect(poster.posterPath == "/t")
        #expect(poster.placeholderIcon == "film")
        #expect(poster.progress == 0.25)
        #expect(!poster.isUnwatched)
        #expect(poster.unwatchedCount == nil)
    }

    @Test func moviePosterIsUnwatchedOnlyWithoutViewsOrProgress() throws {
        let fresh = try LibraryFixtures.item(#"{"ratingKey":"1","type":"movie","title":"A"}"#)
        let seen = try LibraryFixtures.item(#"{"ratingKey":"2","type":"movie","title":"B","viewCount":2}"#)
        #expect(LibraryPoster(grid: fresh, kind: .movie).isUnwatched)
        #expect(LibraryPoster(grid: fresh, kind: .movie).progress == nil)
        #expect(!LibraryPoster(grid: seen, kind: .movie).isUnwatched)
    }

    @Test func showPosterCountsUnwatchedEpisodes() throws {
        let partly = try LibraryFixtures.item(#"{"ratingKey":"1","type":"show","title":"S","leafCount":10,"viewedLeafCount":4}"#)
        let done = try LibraryFixtures.item(#"{"ratingKey":"2","type":"show","title":"T","leafCount":10,"viewedLeafCount":10}"#)
        let poster = LibraryPoster(grid: partly, kind: .show)
        #expect(poster.unwatchedCount == 6)
        #expect(!poster.isUnwatched)
        #expect(poster.progress == nil)
        #expect(poster.placeholderIcon == "tv")
        #expect(LibraryPoster(grid: done, kind: .show).unwatchedCount == nil)
    }

    @Test func recentCardForAShowLibraryCarriesTheSeriesAndLastEpisode() throws {
        let item = try LibraryFixtures.item(#"{"ratingKey":"9","type":"episode","title":"Low Tide","grandparentTitle":"The Show","grandparentThumb":"/g","thumb":"/e","parentIndex":2,"index":4}"#)
        let poster = LibraryPoster(recent: item, kind: .show)
        #expect(poster.title == "The Show")
        #expect(poster.posterPath == "/g")
        #expect(poster.subtitle == "S02E04")
    }

    @Test func recentCardForAMovieLibraryUsesTheFilm() throws {
        let item = try LibraryFixtures.item(#"{"ratingKey":"9","type":"movie","title":"Halcyon","thumb":"/t","grandparentThumb":"/g"}"#)
        let poster = LibraryPoster(recent: item, kind: .movie)
        #expect(poster.title == "Halcyon")
        #expect(poster.posterPath == "/t")
        #expect(poster.subtitle == nil)
    }

    @Test func folderPosterUsesEpisodeCaptionsAndTheTvPlaceholder() throws {
        let episode = try LibraryFixtures.item(#"{"ratingKey":"9","type":"episode","title":"Low Tide","grandparentTitle":"The Show","parentIndex":2,"index":4}"#)
        let film = try LibraryFixtures.item(#"{"ratingKey":"8","type":"movie","title":"Halcyon","year":2021}"#)
        let bare = try LibraryFixtures.item(#"{"ratingKey":"7","type":"movie","title":"Bare"}"#)
        #expect(LibraryPoster(folderItem: episode).subtitle == "S02E04 · The Show")
        #expect(LibraryPoster(folderItem: episode).placeholderIcon == "tv")
        #expect(LibraryPoster(folderItem: film).subtitle == "2021")
        #expect(LibraryPoster(folderItem: film).placeholderIcon == "film")
        #expect(LibraryPoster(folderItem: bare).subtitle == nil)
    }

    @Test func movieMenuOffersResumeWhenPartWatchedAndToggleWatched() throws {
        let partly = try LibraryFixtures.item(#"{"ratingKey":"1","type":"movie","title":"A","viewOffset":60000,"duration":600000}"#)
        let actions = LibraryItemAction.grid(for: partly, kind: .movie)
        #expect(actions.map(\.title) == ["Resume", "Mark Watched", "View Details"])
        #expect(actions.map(\.kind) == [.play, .setWatched(true), .viewDetails])

        let watched = try LibraryFixtures.item(#"{"ratingKey":"2","type":"movie","title":"B","viewCount":1}"#)
        let again = LibraryItemAction.grid(for: watched, kind: .movie)
        #expect(again.map(\.title) == ["Play", "Mark Unwatched", "View Details"])
        #expect(again[1].kind == .setWatched(false))
        #expect(again[1].symbol == "eye.slash")
    }

    @Test func showMenuMarksTheWholeSeries() throws {
        let partly = try LibraryFixtures.item(#"{"ratingKey":"1","type":"show","title":"S","leafCount":8,"viewedLeafCount":3}"#)
        let done = try LibraryFixtures.item(#"{"ratingKey":"2","type":"show","title":"T","leafCount":8,"viewedLeafCount":8}"#)
        let empty = try LibraryFixtures.item(#"{"ratingKey":"3","type":"show","title":"U"}"#)
        #expect(LibraryItemAction.grid(for: partly, kind: .show).map(\.title) == ["Mark All Watched", "View Details"])
        #expect(LibraryItemAction.grid(for: done, kind: .show).first?.kind == .setWatched(false))
        #expect(LibraryItemAction.grid(for: done, kind: .show).first?.title == "Mark All Unwatched")
        #expect(LibraryItemAction.grid(for: empty, kind: .show).first?.kind == .setWatched(true))
    }

    @Test func recentMenuLeadsToTheShowOnlyForShowLibraries() throws {
        let episode = try LibraryFixtures.item(#"{"ratingKey":"9","type":"episode","title":"E","grandparentRatingKey":"5"}"#)
        let show = LibraryItemAction.recent(for: episode, kind: .show)
        #expect(show.map(\.title) == ["Go to Show", "Play Again", "Episode Details"])
        #expect(show[0].kind == .goToShow("5"))
        let movie = LibraryItemAction.recent(for: episode, kind: .movie)
        #expect(movie.map(\.title) == ["Play Again", "View Details"])
        let orphan = try LibraryFixtures.item(#"{"ratingKey":"9","type":"episode","title":"E"}"#)
        #expect(LibraryItemAction.recent(for: orphan, kind: .show).map(\.title) == ["Play Again", "Episode Details"])
    }

    @Test func destinationsFollowTheMediaType() throws {
        let show = try LibraryFixtures.item(#"{"ratingKey":"5","type":"show","title":"S"}"#)
        let film = try LibraryFixtures.item(#"{"ratingKey":"6","type":"movie","title":"M"}"#)
        let episode = try LibraryFixtures.item(#"{"ratingKey":"9","type":"episode","title":"E","grandparentRatingKey":"5"}"#)
        #expect(LibraryDestination(browsing: show) == .show(ratingKey: "5"))
        #expect(LibraryDestination(browsing: film) == .media(film))
        #expect(LibraryDestination(recent: episode, kind: .show) == .show(ratingKey: "5"))
        #expect(LibraryDestination(recent: film, kind: .movie) == .media(film))
        let orphan = try LibraryFixtures.item(#"{"ratingKey":"9","type":"episode","title":"E"}"#)
        #expect(LibraryDestination(recent: orphan, kind: .show) == .show(ratingKey: "9"))
    }

    @Test func browsingOpensSeasonsThroughTheirShowAndSkipsEntriesWithoutAScreen() throws {
        let season = try LibraryFixtures.item(#"{"ratingKey":"50","type":"season","title":"Season 1","parentRatingKey":"5"}"#)
        let orphanSeason = try LibraryFixtures.item(#"{"ratingKey":"51","type":"season","title":"Season 2"}"#)
        let episode = try LibraryFixtures.item(#"{"ratingKey":"52","type":"episode","title":"E"}"#)
        let collection = try LibraryFixtures.item(#"{"ratingKey":"53","type":"collection","title":"C"}"#)
        let untyped = try LibraryFixtures.item(#"{"ratingKey":"54","title":"U"}"#)
        #expect(LibraryDestination(browsing: season) == .show(ratingKey: "5"))
        #expect(LibraryDestination(browsing: orphanSeason) == .show(ratingKey: "51"))
        #expect(LibraryDestination(browsing: episode) == .media(episode))
        #expect(LibraryDestination(browsing: collection) == nil)
        #expect(LibraryDestination(browsing: untyped) == .media(untyped))
    }

    @Test func sectionsKeepOnlyMoviesAndShowsInServerOrder() throws {
        let json = #"""
        {"MediaContainer":{"Directory":[
          {"key":"1","type":"movie","title":"Films"},
          {"key":"2","type":"artist","title":"Music"},
          {"key":"3","type":"show"},
          {"type":"movie","title":"No key"},
          {"key":"4","type":"photo","title":"Photos"},
          {"key":"5","type":"movie"}
        ]}}
        """#
        let sections = LibrarySection.sections(in: try LibraryFixtures.container(json))
        #expect(sections == [
            LibrarySection(id: "1", title: "Films", kind: .movie),
            LibrarySection(id: "3", title: "TV Shows", kind: .show),
            LibrarySection(id: "5", title: "Movies", kind: .movie),
        ])
    }

    @Test func sectionsAreEmptyWithoutDirectories() throws {
        #expect(LibrarySection.sections(in: try LibraryFixtures.container(#"{"MediaContainer":{}}"#)).isEmpty)
    }

    @Test func folderListingSplitsFoldersFromMedia() throws {
        let json = #"""
        {"MediaContainer":{
          "Directory":[
            {"key":"/library/sections/1/folder?parent=a%2Fb","title":"Action"},
            {"key":"/library/sections/1/folder?parent=c/Comedy"},
            {"title":"Keyless"}
          ],
          "Metadata":[
            {"ratingKey":"10","type":"movie","title":"Playable"},
            {"key":"/library/sections/1/folder?parent=d","title":"Folder as metadata"},
            {"title":"Neither"}
          ]
        }}
        """#
        let listing = LibraryFolderListing(container: try LibraryFixtures.container(json))
        #expect(listing.folders.count == 3)
        #expect(listing.folders[0] == .init(key: "/library/sections/1/folder?parent=a%2Fb", title: "Action"))
        #expect(listing.folders[1].title == "Comedy")
        #expect(listing.folders[2] == .init(key: "/library/sections/1/folder?parent=d", title: "Folder as metadata"))
        #expect(listing.media.map(\.id) == ["10"])
        #expect(!listing.isEmpty)
    }

    @Test func emptyContainerMakesAnEmptyListing() throws {
        #expect(LibraryFolderListing(container: try LibraryFixtures.container(#"{"MediaContainer":{}}"#)).isEmpty)
    }
}

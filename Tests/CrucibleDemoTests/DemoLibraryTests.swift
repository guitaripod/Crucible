@testable import CrucibleCore
import Foundation
import Testing
@testable import CrucibleDemo

struct DemoLibraryTests {
    @Test func sectionsListTheThreeLibraries() async throws {
        try await withDemo { demo in
            let container = try await demo.api.requestContainer(.sections)
            let titles = (container.Directory ?? []).compactMap(\.title)
            #expect(titles == ["Movies", "TV Shows", "Documentaries"])
            #expect((container.Directory ?? []).compactMap(\.type) == ["movie", "show", "movie"])
        }
    }

    @Test func homeHubsCarryContinueOnDeckAndRecentlyAdded() async throws {
        try await withDemo { demo in
            let hubs = try await demo.api.requestContainer(.hubs()).Hub ?? []
            #expect(hubs.compactMap(\.hubIdentifier) == ["home.continue", "home.ondeck", "home.recentlyadded"])
            let continuing = try #require(hubs.first { $0.hubIdentifier == "home.continue" }?.Metadata)
            #expect(continuing.count >= 4)
            #expect(continuing.allSatisfy { ($0.viewOffset ?? 0) > 0 && !$0.isWatched })
            #expect(continuing.first?.grandparentTitle == "The Salt Road")
            let deck = try #require(hubs.first { $0.hubIdentifier == "home.ondeck" }?.Metadata)
            #expect(deck.count == 4)
            #expect(deck.allSatisfy { $0.type == "episode" })
            let recent = try #require(hubs.first { $0.hubIdentifier == "home.recentlyadded" }?.Metadata)
            #expect(recent.count >= 12)
            let week = Int(Date().timeIntervalSince1970) - 7 * 86400
            #expect(recent.filter { ($0.addedAt ?? 0) > week }.count >= 6)
            #expect(try await demo.api.requestContainer(.onDeck).Metadata?.count == 4)
            #expect(try await demo.api.requestContainer(.recentlyAdded(start: 0, size: 10)).Metadata?.count == 10)
        }
    }

    @Test func sectionHubsCarryTheLibrarysOwnRails() async throws {
        try await withDemo { demo in
            let movies = try await demo.api.requestContainer(.sectionHubs(sectionId: "1")).Hub ?? []
            #expect(movies.compactMap(\.hubIdentifier) == ["movie.inprogress", "movie.recentlyadded"])
            let shows = try await demo.api.requestContainer(.sectionHubs(sectionId: "2")).Hub ?? []
            #expect(shows.compactMap(\.hubIdentifier) == ["tv.inprogress", "tv.ondeck", "tv.recentlyadded"])
            #expect(LibraryContinue.select(from: shows) != nil)
        }
    }

    @Test func aMovieHasEverythingTheDetailScreenShows() async throws {
        try await withDemo { demo in
            let movie = try await demo.metadata("1001")
            #expect(movie.title == "Halcyon")
            #expect(movie.type == "movie")
            #expect(movie.genres == ["Thriller", "Sci-Fi", "Drama"])
            #expect(movie.cast.count == 4)
            #expect(movie.cast.first?.thumb == "/actors/maren-vale.jpg")
            #expect(movie.directors == ["Ana Reyes"])
            #expect(movie.writers.count == 2)
            #expect(movie.durationSecs == 8040)
            #expect(movie.videoHeight == 2160)
            #expect(movie.mediaContainer == "mp4")
            #expect(movie.audioStreams.count == 3)
            #expect(movie.subtitleStreams.count == 5)
            #expect(movie.subtitleStreams.first { $0.format == "srt" }?.key?.hasPrefix("/library/streams/") == true)
            #expect(movie.relatedHubs.first?.Metadata?.count == 6)
            #expect(movie.relatedHubs.first?.title == "Related Movies")
            let part = try #require(movie.Media?.first?.Part?.first)
            #expect(part.key.hasSuffix("/file.mp4"))
        }
    }

    @Test func markersSitInsideTheClipSoSkipIntroAndSkipCreditsAreReachable() async throws {
        try await withDemo { demo in
            let episode = try await demo.metadata("4001")
            let intro = try #require(episode.Marker?.first { $0.type == "intro" })
            let credits = try #require(episode.Marker?.first { $0.isCredits })
            #expect(intro.startSecs >= 2 && intro.endSecs <= 20)
            #expect(credits.startSecs >= 15 && credits.endSecs <= 30.5)
            #expect(credits.final == true)
            let movie = try await demo.metadata("1001")
            #expect(movie.Marker?.contains { $0.isCredits } == true)
            #expect(movie.Marker?.contains { $0.type == "intro" } == false)
        }
    }

    @Test func aShowHasSeasonsAndEpisodes() async throws {
        try await withDemo { demo in
            let show = try await demo.metadata("2001")
            #expect(show.title == "The Salt Road")
            #expect(show.type == "show")
            #expect(show.leafCount == 32)
            #expect(show.viewedLeafCount == 11)
            #expect(show.childCount == 4)
            #expect(show.cast.count == 6)
            let seasons = try await demo.api.requestContainer(.children(ratingKey: "2001")).Metadata ?? []
            #expect(seasons.map(\.title) == ["Season 1", "Season 2", "Season 3", "Season 4"])
            #expect(seasons.map(\.leafCount) == [8, 10, 8, 6])
            #expect(seasons[0].isWatched)
            let episodes = try await demo.api.requestContainer(.children(ratingKey: seasons[1].id)).Metadata ?? []
            #expect(episodes.count == 10)
            #expect(episodes.map(\.index) == Array(1...10))
            #expect(episodes[3].progressPercent > 0.5)
            let leaves = try await demo.api.requestContainer(.folderPath("/library/metadata/2001/allLeaves")).Metadata ?? []
            #expect(leaves.count == 32)
            let detail = try #require(try await ShowDetailLoader.load(
                api: demo.api, showRatingKey: "2001", initialSeasonKey: nil, selectedSeasonKey: { nil }, onShow: { _ in }
            ))
            #expect(detail.seasons.count == 4)
        }
    }

    @Test func anEpisodeCarriesItsShowAndSeason() async throws {
        try await withDemo { demo in
            let episode = try await demo.metadata("4012")
            #expect(episode.type == "episode")
            #expect(episode.grandparentTitle == "The Salt Road")
            #expect(episode.grandparentRatingKey == "2001")
            #expect(episode.parentIndex == 2)
            #expect(episode.index == 4)
            #expect(episode.cast.count == 4)
            #expect(episode.mediaContainer == "mkv")
            #expect(episode.viewOffset ?? 0 > 0)
        }
    }

    @Test func listingsPageFilterAndSort() async throws {
        try await withDemo { demo in
            let all = try await demo.api.requestContainer(.sectionItems(sectionId: "1", start: 0, size: 1000))
            let total = try #require(all.totalSize)
            #expect(total >= 25)
            let first = try await demo.api.requestContainer(.sectionItems(sectionId: "1", start: 0, size: 10))
            let second = try await demo.api.requestContainer(.sectionItems(sectionId: "1", start: 10, size: 10))
            #expect(first.totalSize == total && second.totalSize == total)
            #expect(first.Metadata?.count == 10 && second.offset == 10)
            #expect(Set((first.Metadata ?? []).map(\.id)).isDisjoint(with: (second.Metadata ?? []).map(\.id)))
            #expect(try await demo.api.requestContainer(.sectionItems(sectionId: "1", size: 0)).Metadata?.isEmpty == true)

            let unwatched = try await demo.api.requestContainer(.sectionItems(sectionId: "1", unwatched: true)).Metadata ?? []
            #expect(!unwatched.isEmpty && unwatched.count < total)
            #expect(unwatched.allSatisfy { !$0.isWatched && ($0.viewOffset ?? 0) == 0 })

            let progress = try await demo.api.requestContainer(.sectionItems(sectionId: "1", inProgress: true)).Metadata ?? []
            #expect(progress.map(\.title) == ["Deep Field"])
            let showProgress = try await demo.api.requestContainer(.sectionItems(sectionId: "2", inProgress: true)).Metadata ?? []
            #expect(!showProgress.isEmpty)

            let animated = try await demo.api.requestContainer(.sectionItems(sectionId: "1", genre: "3")).Metadata ?? []
            #expect(animated.map(\.title).sorted() == ["Halfmoon", "Lantern Hill"])
            #expect(animated.allSatisfy { $0.genres.contains("Animation") })

            let byYear = try await demo.api.requestContainer(.sectionItems(sectionId: "1", sort: "year:desc", size: 100)).Metadata ?? []
            let years = byYear.compactMap(\.year)
            #expect(years == years.sorted(by: >))
            let byRating = try await demo.api.requestContainer(.sectionItems(sectionId: "1", sort: "rating:desc", size: 100)).Metadata ?? []
            #expect(byRating.first?.title == "Halcyon")
            let byAdded = try await demo.api.requestContainer(.sectionItems(sectionId: "1", sort: "addedAt:desc", size: 100)).Metadata ?? []
            let added = byAdded.compactMap(\.addedAt)
            #expect(added == added.sorted(by: >))
            let byTitle = try await demo.api.requestContainer(.sectionItems(sectionId: "1", sort: "titleSort:asc", size: 100)).Metadata ?? []
            let titles = byTitle.map { $0.title.lowercased().replacingOccurrences(of: "^the ", with: "", options: .regularExpression) }
            #expect(titles == titles.sorted())
        }
    }

    @Test func genresAndTheAlphabetIndexDescribeTheListing() async throws {
        try await withDemo { demo in
            let genres = try await demo.api.requestContainer(.sectionGenres(sectionId: "1")).Directory ?? []
            #expect(genres.compactMap(\.title).contains("Sci-Fi"))
            #expect(genres.allSatisfy { $0.key != nil })

            let response: LibraryFirstCharacterResponse = try await demo.api.request(.sectionFirstCharacter(sectionId: "1"))
            let index = LibraryAlphabetIndex(entries: response.MediaContainer.Directory ?? [])
            #expect(index.isUsable)
            let listing = try await demo.api.requestContainer(.sectionItems(sectionId: "1", sort: "titleSort:asc", size: 1000)).Metadata ?? []
            for letter in index.availableLetters {
                let offset = try #require(index.offset(for: letter))
                let title = listing[offset].title.replacingOccurrences(of: "^The ", with: "", options: .regularExpression)
                #expect(title.uppercased().hasPrefix(letter))
            }
        }
    }

    @Test func foldersBrowseByLetterRange() async throws {
        try await withDemo { demo in
            let root = try await LibraryFolderListing.load(.section("1"), api: demo.api)
            #expect(root.folders.count >= 3)
            var found = 0
            for folder in root.folders {
                let listing = try await LibraryFolderListing.load(.folder(folder.key), api: demo.api)
                #expect(listing.folders.isEmpty && !listing.media.isEmpty)
                found += listing.media.count
            }
            let total = try await demo.api.requestContainer(.sectionItems(sectionId: "1", size: 0)).totalSize
            #expect(found == total)
        }
    }

    @Test func searchFindsTitlesAndGenreGridsFillFromTheListings() async throws {
        try await withDemo { demo in
            let loader = SearchLoader(api: demo.api)
            let hubs = try await demo.api.requestContainer(.search(query: "salt")).Hub ?? []
            #expect(hubs.contains { $0.type == "show" && $0.Metadata?.first?.title == "The Salt Road" })
            #expect(hubs.contains { $0.type == "movie" && $0.Metadata?.contains { $0.title == "Saltwater Kings" } == true })
            #expect(hubs.contains { $0.type == "episode" })
            #expect(try await loader.search(query: "salt").ordered.count >= 3)
            #expect(try await loader.search(query: "   ").ordered.isEmpty)
            let genres = await loader.genres()
            #expect(genres.count >= 5)
            let recent = await loader.recentlyAdded()
            #expect(recent.count >= 10)
            let grid = try await loader.items(genre: try #require(genres.first { $0.title == "Comedy" }))
            #expect(grid.count >= 5)
        }
    }
}

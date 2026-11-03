@testable import CrucibleCore
import Foundation
import Testing
@testable import CrucibleDemo

struct DemoCollectionsAndPlaylistsTests {
    @Test func theMoviesLibraryListsItsCollections() async throws {
        try await withDemo { demo in
            let collections = try await CollectionsFeed.collections(inSection: "1", api: demo.api)
            #expect(collections.map(\.title) == ["Salvage Stories", "After Dark"])
            #expect(collections.allSatisfy { $0.mediaType == "collection" && $0.thumb?.isEmpty == false && ($0.childCount ?? 0) > 0 })
            #expect(try await CollectionsFeed.collections(inSection: "3", api: demo.api).map(\.title) == ["Ice and Silence"])
            #expect(try await CollectionsFeed.collections(inSection: "2", api: demo.api).isEmpty)
        }
    }

    @Test func aCollectionHoldsItsMembersAndTheirsTagsPointBack() async throws {
        try await withDemo { demo in
            let collection = try #require(try await CollectionsFeed.collection(named: "salvage stories", inSection: "1", api: demo.api))
            let items = try await CollectionsFeed.items(inCollection: collection.id, api: demo.api)
            #expect(items.map(\.title) == ["Halcyon", "Deep Field", "Tidewater", "Saltwater Kings"])
            let halcyon = try await demo.metadata("1001")
            #expect(halcyon.collectionNames == ["Salvage Stories"])
            #expect(try await demo.metadata("1003").collectionNames.isEmpty)
        }
    }

    @Test func theDemoStartsWithPlaylistsTheViewerCanEdit() async throws {
        try await withDemo { demo in
            let playlists = try await PlaylistsFeed.playlists(api: demo.api)
            #expect(playlists.map(\.title) == ["Friday Night", "Sci-Fi Marathon"])
            #expect(playlists.allSatisfy { !$0.isSmart && $0.posterPath?.isEmpty == false })
            let entries = try await PlaylistsFeed.items(inPlaylist: playlists[0].id, api: demo.api)
            #expect(entries.map(\.title) == ["Cold Meridian", "Undertow", "Night Ferry"])
            #expect(entries.allSatisfy { $0.playlistItemID != nil })
        }
    }

    @Test func aPlaylistCanBeMadeAddedToTrimmedMovedAndDeleted() async throws {
        try await withDemo { demo in
            let made = try #require(try await PlaylistService.create(title: "Rainy Day", adding: ["1003"], api: demo.api))
            try await PlaylistService.add(["1005", "1027"], toPlaylist: made.id, api: demo.api)
            var entries = try await PlaylistsFeed.items(inPlaylist: made.id, api: demo.api)
            #expect(entries.map(\.title) == ["Low Tide", "Glass Harbour", "Moth Season"])

            let anchor = PlaylistService.anchor(movingFrom: 2, to: 0, in: entries)
            try await PlaylistService.move(playlistItemID: try #require(entries[2].playlistItemID), after: anchor, inPlaylist: made.id, api: demo.api)
            entries = try await PlaylistsFeed.items(inPlaylist: made.id, api: demo.api)
            #expect(entries.map(\.title) == ["Moth Season", "Low Tide", "Glass Harbour"])

            try await PlaylistService.remove(playlistItemID: try #require(entries[1].playlistItemID), fromPlaylist: made.id, api: demo.api)
            #expect(try await PlaylistsFeed.items(inPlaylist: made.id, api: demo.api).map(\.title) == ["Moth Season", "Glass Harbour"])

            try await PlaylistService.delete(playlist: made.id, api: demo.api)
            #expect(try await PlaylistsFeed.playlists(api: demo.api).map(\.title) == ["Friday Night", "Sci-Fi Marathon"])
        }
    }

    @Test func playlistsSurviveARestart() async throws {
        let file = DemoHarness.temporaryStateFile()
        let first = try await DemoHarness.start(stateFile: file)
        _ = try await PlaylistService.create(title: "Kept", adding: ["1003"], api: first.api)
        try await Task.sleep(for: .seconds(1.5))
        await first.stop()

        try await withDemo(stateFile: file) { demo in
            let titles = try await PlaylistsFeed.playlists(api: demo.api).map(\.title)
            #expect(titles == ["Friday Night", "Sci-Fi Marathon", "Kept"])
        }
    }

    @Test func ratingsAreKeptAndSortable() async throws {
        try await withDemo { demo in
            try await RatingService.setRating(UserRating(halfStars: 9), ratingKey: "1003", api: demo.api)
            try await RatingService.setRating(UserRating(halfStars: 4), ratingKey: "1005", api: demo.api)
            #expect(try await demo.metadata("1003").userRating == 9)
            let page = try await demo.api.requestContainer(.sectionItems(sectionId: "1", sort: "userRating:desc", size: 3))
            #expect((page.Metadata ?? []).prefix(2).map(\.id) == ["1003", "1005"])
            try await RatingService.setRating(nil, ratingKey: "1003", api: demo.api)
            #expect(try await demo.metadata("1003").userRating == nil)
        }
    }
}

struct DemoPeopleTests {
    @Test func aCastMembersTitlesComeFromTheActorFilter() async throws {
        try await withDemo { demo in
            let halcyon = try await demo.metadata("1001")
            let pilot = try #require(halcyon.cast.first)
            #expect(PersonFilmography.canOpen(pilot))
            let titles = try await PersonFilmography.titles(of: pilot, api: demo.api)
            #expect(titles.contains { $0.id == "1001" })
            #expect(titles.allSatisfy { ["movie", "show"].contains($0.mediaType) })
            let everyone = try await demo.api.requestContainer(.sectionItems(sectionId: "1", size: 100)).totalSize ?? 0
            #expect(titles.count < everyone)
        }
    }
}

struct DemoActivityTests {
    @Test func theDemoServerHasTwoPeopleWatching() async throws {
        try await withDemo { demo in
            let sessions = try await ServerActivity.sessions(api: demo.api)
            #expect(sessions.count == 2)
            #expect(sessions.compactMap { ServerActivity.subtitle($0) }.count == 2)
            #expect(sessions.contains { ServerActivity.isTranscoding($0) })
            #expect(sessions.allSatisfy { $0.progressPercent > 0 })
        }
    }
}

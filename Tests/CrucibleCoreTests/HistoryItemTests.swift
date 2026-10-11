import Foundation
import Testing
@testable import CrucibleCore

struct HistoryItemTests {
    @Test func viewedAtFallsBackToLastViewedThenAdded() {
        let viewed = HistoryItem(metadata: HistoryFixtures.metadata(HistoryFixtures.json(key: "1", viewedAt: 30, lastViewedAt: 20, addedAt: 10)), position: 0)
        let last = HistoryItem(metadata: HistoryFixtures.metadata(HistoryFixtures.json(key: "1", lastViewedAt: 20, addedAt: 10)), position: 0)
        let added = HistoryItem(metadata: HistoryFixtures.metadata(HistoryFixtures.json(key: "1", addedAt: 10)), position: 0)
        let none = HistoryItem(metadata: HistoryFixtures.metadata(HistoryFixtures.json(key: "1")), position: 0)
        #expect(viewed.viewedAt == 30)
        #expect(last.viewedAt == 20)
        #expect(added.viewedAt == 10)
        #expect(none.viewedAt == nil)
    }

    @Test func pageMappingKeepsServerOrderAndOffsetBasedIdentity() {
        let container = HistoryFixtures.container(total: 9, rows: [
            HistoryFixtures.json(key: "7", title: "A"),
            HistoryFixtures.json(key: "7", title: "A again"),
            HistoryFixtures.json(key: "8", title: "B")
        ])
        let items = HistoryItem.items(in: container, offset: 50)
        #expect(items.map(\.title) == ["A", "A again", "B"])
        #expect(items.map(\.uniqueId) == ["7-50", "7-51", "8-52"])
        #expect(Set(items.map(\.uniqueId)).count == 3)
    }

    @Test func missingMetadataMapsToNoItems() throws {
        let json = #"{"MediaContainer": {"totalSize": 4}}"#
        let container = try JSONDecoder().decode(PlexResponse.self, from: Data(json.utf8)).MediaContainer
        #expect(HistoryItem.items(in: container, offset: 0).isEmpty)
    }

    @Test func mappingCopiesEpisodeFields() {
        let row = HistoryFixtures.json(
            key: "5",
            type: "episode",
            title: "Low Tide",
            viewedAt: 99,
            duration: 2_700_000,
            thumb: "/t",
            extra: #""grandparentTitle": "The Show", "grandparentRatingKey": "4", "grandparentThumb": "/g", "parentRatingKey": "3", "parentIndex": 2, "index": 4"#
        )
        let item = HistoryItem(metadata: HistoryFixtures.metadata(row), position: 3)
        #expect(item.ratingKey == "5")
        #expect(item.grandparentTitle == "The Show")
        #expect(item.grandparentRatingKey == "4")
        #expect(item.grandparentThumb == "/g")
        #expect(item.parentRatingKey == "3")
        #expect(item.parentIndex == 2)
        #expect(item.index == 4)
        #expect(item.duration == 2_700_000)
        #expect(item.uniqueId == "5-3")
    }
}

struct HistoryRowTests {
    @Test func episodeRowReadsAsTheShowWithEpisodeLine() {
        let item = HistoryFixtures.item(
            type: "episode", title: "Low Tide", thumb: "/ep", grandparentThumb: "/show",
            grandparentTitle: "The Show", parentIndex: 2, index: 4
        )
        let row = item.row
        #expect(row.title == "The Show")
        #expect(row.subtitle == "S2 · E4 · Low Tide")
        #expect(row.posterPath == "/show")
    }

    @Test func episodeWithoutNumbersOrShowFallsBackToItself() {
        let item = HistoryFixtures.item(type: "episode", title: "Pilot", thumb: "/ep")
        let row = item.row
        #expect(row.title == "Pilot")
        #expect(row.subtitle == "Pilot")
        #expect(row.posterPath == "/ep")
    }

    @Test func episodeWithOnlyAnEpisodeNumberOmitsTheSeason() {
        let item = HistoryFixtures.item(type: "episode", title: "Pilot", parentIndex: nil, index: 1)
        #expect(item.row.subtitle == "E1 · Pilot")
    }

    @Test func showAndMovieRowsUseTheirOwnTitleAndPoster() {
        let show = HistoryFixtures.item(type: "show", title: "The Show", thumb: "/s")
        let movie = HistoryFixtures.item(type: "movie", title: "Heat", thumb: "/m", grandparentThumb: "/ignored", grandparentTitle: "Ignored")
        #expect(show.row.subtitle == "Show")
        #expect(show.row.title == "The Show")
        #expect(show.row.posterPath == "/s")
        #expect(movie.row.subtitle == "Movie")
        #expect(movie.row.title == "Heat")
        #expect(movie.row.posterPath == "/m")
    }

    @Test func unknownAndSeasonTypesReadAsMovie() {
        #expect(HistoryFixtures.item(type: nil).row.subtitle == "Movie")
        #expect(HistoryFixtures.item(type: "season").row.subtitle == "Movie")
    }

    @Test func timeTextIsPresentOnlyWithATimestamp() {
        #expect(HistoryFixtures.item(viewedAt: nil).row.timeText == nil)
        #expect(HistoryFixtures.item(viewedAt: HistoryFixtures.nowSeconds).row.timeText?.isEmpty == false)
    }

    @Test func tapRoutingFollowsTheType() {
        let episode = HistoryFixtures.item(key: "5", type: "episode", grandparentRatingKey: "4", parentRatingKey: "3")
        #expect(episode.destination == .episode(ratingKey: "5", showRatingKey: "4", seasonRatingKey: "3"))
        #expect(HistoryFixtures.item(key: "6", type: "show").destination == .show(ratingKey: "6"))
        #expect(HistoryFixtures.item(key: "7", type: "movie").destination == .movie(ratingKey: "7"))
        #expect(HistoryFixtures.item(key: "8", type: "season").destination == .movie(ratingKey: "8"))
        #expect(HistoryFixtures.item(key: "9", type: nil).destination == .movie(ratingKey: "9"))
    }
}

struct HistoryFilterTests {
    @Test func filtersIncludeTheirTypes() {
        let movie = HistoryFixtures.item(type: "movie")
        let episode = HistoryFixtures.item(type: "episode")
        let show = HistoryFixtures.item(type: "show")
        let season = HistoryFixtures.item(type: "season")
        let unknown = HistoryFixtures.item(type: nil)
        for item in [movie, episode, show, season, unknown] {
            #expect(HistoryFilter.all.includes(item))
        }
        #expect(HistoryFilter.movies.includes(movie))
        #expect([episode, show, season, unknown].allSatisfy { !HistoryFilter.movies.includes($0) })
        #expect([episode, show, season].allSatisfy { HistoryFilter.tv.includes($0) })
        #expect(!HistoryFilter.tv.includes(movie))
        #expect(!HistoryFilter.tv.includes(unknown))
    }

    @Test func titlesAndOrderMatchTheChipRow() {
        #expect(HistoryFilter.allCases == [.all, .movies, .tv])
        #expect(HistoryFilter.allCases.map(\.title) == ["All", "Movies", "TV"])
        #expect(HistoryFilter.allCases.map(\.rawValue) == ["all", "movies", "tv"])
    }
}

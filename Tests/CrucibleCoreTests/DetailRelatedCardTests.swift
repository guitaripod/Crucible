import Foundation
import Testing
@testable import CrucibleCore

struct DetailRelatedCardTests {
    @Test func relatedTitlesLeaveOutLibrariesLeftOut() {
        let item = DetailFixtures.item([
            "ratingKey": "1",
            "Related": ["Hub": [["Metadata": [
                ["ratingKey": "2", "type": "movie", "title": "Kept", "librarySectionID": 1],
                ["ratingKey": "3", "type": "movie", "title": "Left out", "librarySectionID": 2],
                ["ratingKey": "4", "type": "movie", "title": "Unknown library"],
            ]]]],
        ])
        #expect(DetailRelated.items(in: item, excluding: [2]).map(\.id) == ["2", "4"])
        #expect(DetailRelated.items(in: item, excluding: []).map(\.id) == ["2", "3", "4"])
    }

    @Test func movieShowsItsYearPosterAndUnwatchedDot() {
        let card = DetailRelatedCard(item: DetailFixtures.item(["ratingKey": "9", "title": "Heat", "year": 1995, "thumb": "/poster"]))
        #expect(card.id == "9")
        #expect(card.title == "Heat")
        #expect(card.subtitle == "1995")
        #expect(card.posterPath == "/poster")
        #expect(card.progress == nil)
        #expect(card.isUnwatched)
        #expect(!card.isShow)
    }

    @Test func showSaysHowManySeasonsAndHasNoUnwatchedDot() {
        let many = DetailRelatedCard(item: DetailFixtures.item(["type": "show", "childCount": 3, "year": 2019]))
        #expect(many.subtitle == "3 seasons")
        #expect(many.isShow)
        #expect(!many.isUnwatched)
        #expect(DetailRelatedCard(item: DetailFixtures.item(["type": "show", "childCount": 1])).subtitle == "1 season")
        #expect(DetailRelatedCard(item: DetailFixtures.item(["type": "show", "childCount": 0, "year": 2019])).subtitle == "2019")
        #expect(DetailRelatedCard(item: DetailFixtures.item(["type": "show", "year": 2019])).subtitle == "2019")
    }

    @Test func progressAndWatchedStateDecideTheDot() {
        let partway = DetailRelatedCard(item: DetailFixtures.item(["duration": 1000, "viewOffset": 250]))
        #expect(partway.progress == 0.25)
        #expect(!partway.isUnwatched)
        #expect(!DetailRelatedCard(item: DetailFixtures.item(["viewCount": 1])).isUnwatched)
    }

    @Test func episodesFallBackToTheShowPoster() {
        let card = DetailRelatedCard(item: DetailFixtures.item(["type": "episode", "grandparentThumb": "/show"]))
        #expect(card.posterPath == "/show")
        #expect(card.subtitle == nil)
    }

    @Test func anEpisodeNamesItsShowAndPlaceInIt() {
        let card = DetailRelatedCard(item: DetailFixtures.item([
            "type": "episode", "grandparentTitle": "The Salt Road", "parentIndex": 2, "index": 4, "thumb": "/still", "grandparentThumb": "/show",
        ]))
        #expect(card.posterPath == "/show")
        #expect(card.subtitle == "The Salt Road · S2 · E4")
    }
}

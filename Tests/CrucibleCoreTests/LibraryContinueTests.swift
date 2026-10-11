import Foundation
import Testing
@testable import CrucibleCore

struct LibraryContinueTests {
    private func item(_ json: String) throws -> PlexMetadata {
        try LibraryFixtures.item(json)
    }

    private func hubs(_ json: String) throws -> [PlexHub] {
        try LibraryFixtures.container(#"{"MediaContainer":{"Hub":\#(json)}}"#).Hub ?? []
    }

    @Test func timeLeftReadsInMinutesThenHours() throws {
        func left(offsetMs: Int, durationMs: Int) throws -> String? {
            try LibraryFormat.timeLeft(item(#"{"ratingKey":"1","title":"A","viewOffset":\#(offsetMs),"duration":\#(durationMs)}"#))
        }
        #expect(try left(offsetMs: 0, durationMs: 45 * 60_000) == "45 min left")
        #expect(try left(offsetMs: 30 * 60_000, durationMs: 90 * 60_000) == "1 h left")
        #expect(try left(offsetMs: 10 * 60_000, durationMs: 142 * 60_000) == "2 h 12 m left")
        #expect(try left(offsetMs: 0, durationMs: 20_000) == "Less than a minute left")
        #expect(try left(offsetMs: 600_000, durationMs: 600_000) == nil)
        #expect(try left(offsetMs: 700_000, durationMs: 600_000) == nil)
        #expect(try left(offsetMs: 100, durationMs: 0) == nil)
    }

    @Test func continueTitleNamesTheShowForEpisodes() throws {
        let episode = try item(#"{"ratingKey":"1","type":"episode","title":"Low Tide","grandparentTitle":"The Show"}"#)
        let film = try item(#"{"ratingKey":"2","type":"movie","title":"Halcyon","grandparentTitle":"Ignored"}"#)
        let orphan = try item(#"{"ratingKey":"3","type":"episode","title":"Lonely"}"#)
        #expect(LibraryFormat.continueTitle(episode) == "The Show")
        #expect(LibraryFormat.continueTitle(film) == "Halcyon")
        #expect(LibraryFormat.continueTitle(orphan) == "Lonely")
    }

    @Test func continueDetailJoinsTitleEpisodeCodeAndTimeLeft() throws {
        let episode = try item(#"{"ratingKey":"1","type":"episode","title":"Low Tide","grandparentTitle":"The Show","parentIndex":2,"index":4,"viewOffset":600000,"duration":2700000}"#)
        #expect(LibraryFormat.continueDetail(episode) == "The Show · S02E04 · 35 min left")
        let film = try item(#"{"ratingKey":"2","type":"movie","title":"Halcyon","viewOffset":3600000,"duration":7200000}"#)
        #expect(LibraryFormat.continueDetail(film) == "Halcyon · 1 h left")
        let bare = try item(#"{"ratingKey":"3","type":"movie","title":"Bare"}"#)
        #expect(LibraryFormat.continueDetail(bare) == "Bare")
    }

    @Test func bannerModelDescribesTheItem() throws {
        let episode = try item(#"{"ratingKey":"1","type":"episode","title":"Low Tide","grandparentTitle":"The Show","parentIndex":2,"index":4,"viewOffset":600000,"duration":2700000,"art":"/art","grandparentArt":"/gart","thumb":"/thumb"}"#)
        let banner = ContinueBannerModel(item: episode)
        #expect(banner.itemId == "1")
        #expect(banner.detail == "The Show · S02E04 · 35 min left")
        #expect(banner.artPath == "/art")
        #expect(banner.spokenLabel == "Continue The Show · S02E04 · 35 min left")

        let noArt = try item(#"{"ratingKey":"2","type":"episode","title":"E","grandparentArt":"/gart","thumb":"/thumb"}"#)
        #expect(ContinueBannerModel(item: noArt).artPath == "/gart")
        let thumbOnly = try item(#"{"ratingKey":"3","type":"movie","title":"M","thumb":"/thumb"}"#)
        #expect(ContinueBannerModel(item: thumbOnly).artPath == "/thumb")
    }

    @Test func selectionTakesTheFirstPartWatchedItemFromContinueLikeHubs() throws {
        let json = #"""
        [
          {"hubIdentifier":"movie.recentlyadded.1","Metadata":[{"ratingKey":"90","type":"movie","title":"New","viewOffset":5000}]},
          {"hubIdentifier":"movie.inprogress.1","Metadata":[
            {"ratingKey":"10","type":"movie","title":"Fresh"},
            {"ratingKey":"11","type":"movie","title":"Halfway","viewOffset":5000}
          ]},
          {"hubIdentifier":"home.continue","Metadata":[{"ratingKey":"12","type":"movie","title":"Later","viewOffset":9000}]}
        ]
        """#
        #expect(try LibraryContinue.select(from: hubs(json))?.id == "11")
    }

    @Test func selectionMatchesHubIdentifiersCaseInsensitively() throws {
        let json = #"[{"hubIdentifier":"Home.OnDeck","Metadata":[{"ratingKey":"5","type":"episode","title":"E","viewOffset":100}]}]"#
        #expect(try LibraryContinue.select(from: hubs(json))?.id == "5")
    }

    @Test func selectionSkipsWholeShowsAndUnstartedItems() throws {
        let json = #"[{"hubIdentifier":"home.continue","Metadata":[{"ratingKey":"1","type":"show","title":"S","viewOffset":100},{"ratingKey":"2","type":"movie","title":"M"}]}]"#
        #expect(try LibraryContinue.select(from: hubs(json)) == nil)
    }

    @Test func selectionIgnoresHubsWithoutAnIdentifierOrItems() throws {
        let json = #"[{"Metadata":[{"ratingKey":"1","type":"movie","title":"M","viewOffset":100}]},{"hubIdentifier":"home.continue"}]"#
        #expect(try LibraryContinue.select(from: hubs(json)) == nil)
        #expect(LibraryContinue.select(from: []) == nil)
    }

    @Test func aMovieIsFeaturedOnlyByItself() throws {
        let featured = try item(#"{"ratingKey":"1","type":"movie","title":"A"}"#)
        let other = try item(#"{"ratingKey":"2","type":"movie","title":"B"}"#)
        #expect(LibraryContinue.isFeatured(featured, by: featured, kind: .movie))
        #expect(!LibraryContinue.isFeatured(other, by: featured, kind: .movie))
        #expect(!LibraryContinue.isFeatured(featured, by: nil, kind: .movie))
    }

    @Test func aShowCardIsFeaturedByAnyEpisodeOfTheSeries() throws {
        let episode = try item(#"{"ratingKey":"21","type":"episode","title":"E2","grandparentRatingKey":"5","viewOffset":100}"#)
        let sameShowCard = try item(#"{"ratingKey":"20","type":"episode","title":"E1","grandparentRatingKey":"5"}"#)
        let otherShowCard = try item(#"{"ratingKey":"30","type":"episode","title":"X","grandparentRatingKey":"6"}"#)
        let showItself = try item(#"{"ratingKey":"5","type":"show","title":"S"}"#)
        #expect(LibraryContinue.isFeatured(sameShowCard, by: episode, kind: .show))
        #expect(!LibraryContinue.isFeatured(otherShowCard, by: episode, kind: .show))
        #expect(LibraryContinue.isFeatured(showItself, by: episode, kind: .show))
    }

    @Test func aChangedOffsetOrItemRedrawsTheBanner() throws {
        let a = try item(#"{"ratingKey":"1","type":"movie","title":"A","viewOffset":100}"#)
        let moved = try item(#"{"ratingKey":"1","type":"movie","title":"A","viewOffset":900}"#)
        let b = try item(#"{"ratingKey":"2","type":"movie","title":"B","viewOffset":100}"#)
        #expect(!LibraryContinue.differs(a, from: a))
        #expect(LibraryContinue.differs(moved, from: a))
        #expect(LibraryContinue.differs(b, from: a))
        #expect(LibraryContinue.differs(nil, from: a))
        #expect(LibraryContinue.differs(a, from: nil))
        #expect(!LibraryContinue.differs(nil, from: nil))
    }
}

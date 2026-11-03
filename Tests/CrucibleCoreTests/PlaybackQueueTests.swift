import Foundation
import Testing
@testable import CrucibleCore

struct PlaybackQueueTests {
    private func entry(_ key: String, type: String = "movie", itemID: Int? = nil, parent: String? = nil, show: String? = nil) -> PlexMetadata {
        var fields: [String: Any] = ["ratingKey": key, "type": type, "title": "Title \(key)"]
        if let itemID { fields["playlistItemID"] = itemID }
        if let parent { fields["parentRatingKey"] = parent }
        if let show { fields["grandparentRatingKey"] = show }
        return DetailFixtures.item(fields)
    }

    @Test func aQueueKeepsOnlyWhatCanPlayAndStartsWhereAsked() throws {
        let entries = [entry("1"), entry("2", type: "show"), entry("3", type: "episode"), entry("4")]
        let queue = try #require(PlaybackQueue.starting(in: entries))
        #expect(queue.entries.map(\.id) == ["1", "3", "4"])
        #expect(queue.current.id == "1")
        let later = try #require(PlaybackQueue.starting(at: entries[3], in: entries))
        #expect(later.current.id == "4")
        #expect(!later.hasNext)
    }

    @Test func aTitleTwiceInAPlaylistIsFoundByItsOwnEntry() throws {
        let entries = [entry("1", itemID: 10), entry("2", itemID: 11), entry("1", itemID: 12)]
        let queue = try #require(PlaybackQueue.starting(at: entries[2], in: entries))
        #expect(queue.position == 2)
    }

    @Test func anEmptyListMakesNoQueue() {
        #expect(PlaybackQueue.starting(in: []) == nil)
        #expect(PlaybackQueue.starting(in: [entry("1", type: "show")]) == nil)
        #expect(PlaybackQueue(entries: [entry("1")], position: 3) == nil)
    }

    @Test func advancingWalksTheEntriesAndStopsAtTheLast() throws {
        let queue = try #require(PlaybackQueue.starting(in: [entry("1"), entry("2"), entry("3")]))
        let second = try #require(queue.advanced())
        #expect(second.current.id == "2")
        let third = try #require(second.advanced())
        #expect(third.current.id == "3")
        #expect(third.advanced() == nil)
    }

    @Test func shufflingKeepsEveryPlayableEntryOnce() throws {
        var generator = SystemRandomNumberGenerator()
        let entries = (1...12).map { entry("\($0)") } + [entry("99", type: "show")]
        let queue = try #require(PlaybackQueue.shuffled(entries, using: &generator))
        #expect(queue.entries.count == 12)
        #expect(Set(queue.entries.map(\.id)) == Set((1...12).map(String.init)))
        #expect(queue.position == 0)
    }

    @Test func theQueueDecidesWhatFollows() async throws {
        let queue = try #require(PlaybackQueue.starting(in: [entry("1"), entry("2", type: "episode", parent: "20", show: "200"), entry("3")]))
        let resolver = UpNextResolver(ratingKey: "1", isEpisode: false, seasonRatingKey: nil, queue: queue, markers: [])
        #expect(resolver.canOfferNext)
        let offer = try #require(try await resolver.loadOffer(api: APIClient(baseURL: URL(string: "http://queue.invalid")!, token: "t"), reason: .playbackEnded))
        #expect(offer.episode.id == "2")
        #expect(offer.autoplays)
        #expect(offer.queue?.position == 1)

        let next = offer.nextRequest(showRatingKey: "ignored")
        #expect(next.ratingKey == "2")
        #expect(next.mediaType == "episode")
        #expect(next.showRatingKey == "200")
        #expect(next.seasonRatingKey == "20")
        #expect(next.queue?.position == 1)
    }

    @Test func theLastEntryOffersNothingMore() async throws {
        let queue = try #require(PlaybackQueue(entries: [entry("1"), entry("2")], position: 1))
        let resolver = UpNextResolver(ratingKey: "2", isEpisode: false, seasonRatingKey: nil, queue: queue, markers: [])
        #expect(!resolver.canOfferNext)
        #expect(try await resolver.loadOffer(api: APIClient(baseURL: URL(string: "http://queue.invalid")!, token: "t"), reason: .playbackEnded) == nil)
    }

    @Test func aFilmInAQueueReachesItsCreditsLikeAnEpisode() throws {
        let queue = try #require(PlaybackQueue.starting(in: [entry("1"), entry("2")]))
        var resolver = UpNextResolver(
            ratingKey: "1", isEpisode: false, seasonRatingKey: nil, queue: queue,
            markers: [PlexMarker(type: "credits", startTimeOffset: 100_000, endTimeOffset: 120_000, final: true)]
        )
        let early = resolver.creditsReached(at: 90)
        let atCredits = resolver.creditsReached(at: 101)
        #expect(!early)
        #expect(atCredits)
        var alone = UpNextResolver(
            ratingKey: "1", isEpisode: false, seasonRatingKey: nil,
            markers: [PlexMarker(type: "credits", startTimeOffset: 100_000, endTimeOffset: 120_000, final: true)]
        )
        let standalone = alone.creditsReached(at: 101)
        #expect(!standalone)
    }

    @Test func theRequestCarriesItsQueueThroughAResume() throws {
        let queue = try #require(PlaybackQueue.starting(in: [entry("1"), entry("2")]))
        let request = PlaybackRequest(item: queue.current, queue: queue)
        #expect(request.queue == queue)
        #expect(request.resuming(at: 30).queue == queue)
    }

    @Test func theCardNamesTheNextTitleWhenItIsNotAnEpisode() {
        #expect(UpNextText.secondary(code: nil, remaining: 5, counting: false, isEpisode: false) == "Next title")
        #expect(UpNextText.spokenSecondary(code: nil, remaining: 5, counting: false, isEpisode: false) == "Next title")
        #expect(UpNextText.announcement(code: nil, title: "Halcyon", seconds: 10, isEpisode: false) == "Next title in 10 seconds: Halcyon")
        #expect(UpNextText.secondary(code: nil, remaining: 5, counting: false) == "Next episode")
    }
}

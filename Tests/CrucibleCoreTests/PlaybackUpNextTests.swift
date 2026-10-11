import Foundation
import Testing
@testable import CrucibleCore

struct PlaybackUpNextTests {
    private static let credits = PlexMarker(type: "credits", startTimeOffset: 2_330_000, endTimeOffset: 2_400_000, final: true)
    private static let intro = PlexMarker(type: "intro", startTimeOffset: 12_000, endTimeOffset: 58_000, final: nil)

    private func episode(_ key: String, index: Int, title: String = "Episode") throws -> PlexMetadata {
        let json = """
        {"ratingKey":"\(key)","type":"episode","title":"\(title) \(index)","grandparentTitle":"The Show",
         "grandparentRatingKey":"100","grandparentThumb":"/show/thumb","parentRatingKey":"200","parentIndex":2,
         "index":\(index),"thumb":"/ep/\(key)/thumb","duration":2400000}
        """
        return try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
    }

    private func season() throws -> [PlexMetadata] {
        try [episode("301", index: 1), episode("302", index: 2), episode("303", index: 3)]
    }

    @Test func nextEpisodeIsTheFollowingEntryOfTheSeason() throws {
        let episodes = try season()
        #expect(UpNextResolver.nextEpisode(after: "301", in: episodes)?.id == "302")
        #expect(UpNextResolver.nextEpisode(after: "302", in: episodes)?.id == "303")
    }

    @Test func theLastEpisodeOfASeasonHasNoSuccessor() throws {
        #expect(UpNextResolver.nextEpisode(after: "303", in: try season()) == nil)
    }

    @Test func anEpisodeMissingFromTheSeasonHasNoSuccessor() throws {
        #expect(UpNextResolver.nextEpisode(after: "999", in: try season()) == nil)
        #expect(UpNextResolver.nextEpisode(after: "301", in: []) == nil)
    }

    @Test func creditsTriggerOnceWhenThePlayheadReachesThem() {
        var resolver = UpNextResolver(ratingKey: "301", isEpisode: true, seasonRatingKey: "200", markers: [Self.intro, Self.credits])
        let before = resolver.creditsReached(at: 2_329.9)
        let atStart = resolver.creditsReached(at: 2_330)
        let after = resolver.creditsReached(at: 2_331)
        let afterSeekBack = resolver.creditsReached(at: 100)
        #expect(!before)
        #expect(atStart)
        #expect(!after)
        #expect(!afterSeekBack)
    }

    @Test func creditsNeverTriggerForMoviesOrWithoutACreditsMarker() {
        var movie = UpNextResolver(ratingKey: "1", isEpisode: false, seasonRatingKey: nil, markers: [Self.credits])
        let movieTriggered = movie.creditsReached(at: 5_000)
        var withoutCredits = UpNextResolver(ratingKey: "301", isEpisode: true, seasonRatingKey: "200", markers: [Self.intro])
        let withoutTriggered = withoutCredits.creditsReached(at: 5_000)
        #expect(!movieTriggered)
        #expect(!withoutTriggered)
    }

    @Test func onlyEpisodesInAKnownSeasonCanOfferANextEpisode() {
        #expect(UpNextResolver(ratingKey: "301", isEpisode: true, seasonRatingKey: "200", markers: []).canOfferNext)
        #expect(!UpNextResolver(ratingKey: "301", isEpisode: true, seasonRatingKey: nil, markers: []).canOfferNext)
        #expect(!UpNextResolver(ratingKey: "1", isEpisode: false, seasonRatingKey: "200", markers: []).canOfferNext)
    }

    @Test func theOfferBuildsARequestThatStartsTheNextEpisodeFromTheBeginning() throws {
        let next = try episode("302", index: 2)
        let offer = UpNextOffer(episode: next, seasonRatingKey: "200", reason: .playbackEnded, autoplays: true)
        let request = offer.nextRequest(showRatingKey: "100")
        #expect(request.ratingKey == "302")
        #expect(request.mediaType == "episode")
        #expect(request.showRatingKey == "100")
        #expect(request.seasonRatingKey == "200")
        #expect(request.resumePosition == 0)
        #expect(request.metadata?.title == "Episode 2")
        #expect(request.metadata?.showName == "The Show")
        #expect(request.metadata?.seasonNumber == 2)
        #expect(request.metadata?.episodeNumber == 2)
        #expect(request.metadata?.posterPath == "/show/thumb")
        #expect(request.metadata?.duration == 2_400)
        #expect(request.offline == nil)
        #expect(offer.playbackEnded)
    }

    @Test func theOfferAttachesAnOfflineCopyWhenGiven() throws {
        let offer = UpNextOffer(episode: try episode("302", index: 2), seasonRatingKey: "200", reason: .credits, autoplays: false)
        let source = OfflinePlaybackSource(fileURL: URL(string: "http://127.0.0.1:1/a.m3u8")!, markers: [], durationSecs: 2_400)
        #expect(offer.nextRequest(showRatingKey: nil, offline: source).offline?.fileURL == source.fileURL)
        #expect(!offer.playbackEnded)
        #expect(UpNextOffer.countdownSeconds == 10)
    }
}

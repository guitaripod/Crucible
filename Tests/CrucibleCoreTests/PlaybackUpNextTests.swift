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

    @Test func autoplayCountsDownAtTheCreditsWhateverSkipCreditsSays() {
        #expect(AutoplayRule.autoplays(reason: .credits, isQueue: false, autoplayNext: true, skipCredits: .button))
        #expect(AutoplayRule.autoplays(reason: .credits, isQueue: false, autoplayNext: true, skipCredits: .automatic))
        #expect(AutoplayRule.autoplays(reason: .playbackEnded, isQueue: false, autoplayNext: true, skipCredits: .button))
        #expect(AutoplayRule.autoplays(reason: .playbackEnded, isQueue: false, autoplayNext: true, skipCredits: .off))
    }

    @Test func withAutoplayOffOnlySkipAutomaticallyMovesOnFromTheCredits() {
        #expect(!AutoplayRule.autoplays(reason: .credits, isQueue: false, autoplayNext: false, skipCredits: .button))
        #expect(AutoplayRule.autoplays(reason: .credits, isQueue: false, autoplayNext: false, skipCredits: .automatic))
        #expect(!AutoplayRule.autoplays(reason: .playbackEnded, isQueue: false, autoplayNext: false, skipCredits: .automatic))
    }

    @Test func aPlaylistPlaysOnAtTheEndOfEveryEntry() {
        #expect(AutoplayRule.autoplays(reason: .playbackEnded, isQueue: true, autoplayNext: false, skipCredits: .button))
        #expect(!AutoplayRule.autoplays(reason: .credits, isQueue: true, autoplayNext: false, skipCredits: .button))
        #expect(AutoplayRule.autoplays(reason: .requested, isQueue: false, autoplayNext: false, skipCredits: .off))
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

    /// South Park S1E3 on the owner's server: Plex marks credits at 21:12 and 21:52 over scenes that carry on, and the final
    /// credits at 23:02. Up Next waits for the final ones.
    @Test func upNextWaitsForTheFinalCreditsNotAnEarlierCreditsMarker() {
        let markers = [
            PlexMarker(type: "credits", startTimeOffset: 1_272_000, endTimeOffset: 1_296_000, final: nil),
            PlexMarker(type: "credits", startTimeOffset: 1_312_000, endTimeOffset: 1_334_000, final: nil),
            PlexMarker(type: "credits", startTimeOffset: 1_382_000, endTimeOffset: 1_410_000, final: true),
            PlexMarker(type: "intro", startTimeOffset: 90_000, endTimeOffset: 122_000, final: nil),
        ]
        var resolver = UpNextResolver(ratingKey: "301", isEpisode: true, seasonRatingKey: "200", markers: markers)
        #expect(resolver.creditsStartSecs == 1_382)
        let atFirstCredits = resolver.creditsReached(at: 1_272)
        let atSecondCredits = resolver.creditsReached(at: 1_312)
        let atFinalCredits = resolver.creditsReached(at: 1_382)
        #expect(!atFirstCredits)
        #expect(!atSecondCredits)
        #expect(atFinalCredits)
    }

    @Test func withoutAFinalFlagTheLastCreditsMarkerIsTheClosingOne() {
        let markers = [
            PlexMarker(type: "credits", startTimeOffset: 1_284_000, endTimeOffset: 1_318_000, final: nil),
            PlexMarker(type: "credits", startTimeOffset: 1_382_000, endTimeOffset: 1_420_000, final: nil),
        ]
        #expect(PlexMarker.closingCreditsStart(in: markers) == 1_382)
        #expect(PlexMarker.closingCreditsStart(in: [Self.intro]) == nil)
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

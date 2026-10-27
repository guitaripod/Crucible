import Foundation
import Testing
@testable import CrucibleCore

/// How the app goes from one episode to the next and how it keeps what is watched in step, the parts that
/// need more than one item: the order episodes play in, crossing a season, what the next request carries,
/// and where a watched item starts.
struct EpisodeFlowTests {
    private func episode(
        _ number: Int,
        season: Int = 1,
        watched: Bool = false,
        offsetMs: Int? = nil,
        lastViewedAt: Int? = nil
    ) -> PlexMetadata {
        var fields: [String: Any] = [
            "ratingKey": "e\(season)\(number)",
            "type": "episode",
            "title": "Episode \(number)",
            "index": number,
            "parentIndex": season,
            "duration": 2_400_000,
        ]
        if watched { fields["viewCount"] = 1 }
        if let offsetMs { fields["viewOffset"] = offsetMs }
        if let lastViewedAt { fields["lastViewedAt"] = lastViewedAt }
        return DetailFixtures.item(fields)
    }

    private func season(_ number: Int, watched: Int = 0, total: Int = 3) -> PlexMetadata {
        DetailFixtures.item([
            "ratingKey": "s\(number)",
            "type": "season",
            "title": "Season \(number)",
            "index": number,
            "leafCount": total,
            "viewedLeafCount": watched,
        ])
    }

    // MARK: - Order

    @Test func episodesPlayInEpisodeOrderNotInTheOrderTheServerSentThem() {
        let shuffled = [episode(1), episode(3), episode(2)]
        #expect(EpisodeOrder.next(after: "e11", in: shuffled)?.id == "e12")
        #expect(EpisodeOrder.sorted(shuffled).map(\.id) == ["e11", "e12", "e13"])
    }

    @Test func aSeasonIsOrderedBeforeTheNextOne() {
        let mixed = [episode(1, season: 2), episode(3, season: 1), episode(1, season: 1)]
        #expect(EpisodeOrder.sorted(mixed).map(\.id) == ["e11", "e13", "e21"])
    }

    // MARK: - Crossing a season

    @Test func theLastEpisodeOfASeasonIsFollowedByTheFirstOfTheNext() async throws {
        let server = DetailStubServer()
        server.reply(path: "/library/metadata/s1/children", items: [episode(1), episode(2), episode(3)])
        server.reply(path: "/library/metadata/100/children", items: [season(1, watched: 3), season(2)])
        server.reply(path: "/library/metadata/s2/children", items: [episode(1, season: 2), episode(2, season: 2)])
        let resolver = UpNextResolver(ratingKey: "e13", isEpisode: true, seasonRatingKey: "s1", showRatingKey: "100", markers: [])
        let offer = try await resolver.loadOffer(api: server.client, reason: .playbackEnded)
        #expect(offer?.episode.id == "e21")
        #expect(offer?.seasonRatingKey == "s2")
    }

    @Test func aSeasonBetweenWithoutEpisodesIsSkipped() async throws {
        let server = DetailStubServer()
        server.reply(path: "/library/metadata/s1/children", items: [episode(1)])
        server.reply(path: "/library/metadata/100/children", items: [season(1), season(2, total: 0), season(3)])
        server.reply(path: "/library/metadata/s2/children", items: [])
        server.reply(path: "/library/metadata/s3/children", items: [episode(1, season: 3)])
        let resolver = UpNextResolver(ratingKey: "e11", isEpisode: true, seasonRatingKey: "s1", showRatingKey: "100", markers: [])
        let offer = try await resolver.loadOffer(api: server.client, reason: .playbackEnded)
        #expect(offer?.seasonRatingKey == "s3")
        #expect(offer?.episode.id == "e31")
    }

    @Test func theLastEpisodeOfTheShowOffersNothing() async throws {
        let server = DetailStubServer()
        server.reply(path: "/library/metadata/s2/children", items: [episode(1, season: 2)])
        server.reply(path: "/library/metadata/100/children", items: [season(1), season(2)])
        let resolver = UpNextResolver(ratingKey: "e21", isEpisode: true, seasonRatingKey: "s2", showRatingKey: "100", markers: [])
        #expect(try await resolver.loadOffer(api: server.client, reason: .playbackEnded) == nil)
    }

    @Test func thePlayersNextEpisodeAgreesWithTheShowsContinueButton() async throws {
        let server = DetailStubServer()
        server.reply(path: "/library/metadata/s1/children", items: [episode(1, season: 1, watched: true), episode(2, season: 1, watched: true), episode(3, season: 1, watched: true)])
        server.reply(path: "/library/metadata/100/children", items: [season(1, watched: 3), season(2)])
        server.reply(path: "/library/metadata/s2/children", items: [episode(1, season: 2), episode(2, season: 2)])
        let resolver = UpNextResolver(ratingKey: "e13", isEpisode: true, seasonRatingKey: "s1", showRatingKey: "100", markers: [])
        let player = try await resolver.loadOffer(api: server.client, reason: .playbackEnded)
        let all = [episode(1, season: 1, watched: true), episode(2, season: 1, watched: true), episode(3, season: 1, watched: true), episode(1, season: 2), episode(2, season: 2)]
        let screen = ShowDetailModel(
            show: DetailFixtures.item(["ratingKey": "100", "type": "show", "title": "The Show", "leafCount": 5, "viewedLeafCount": 3]),
            seasons: [season(1, watched: 3), season(2)],
            selectedSeasonKey: "s2",
            episodes: [episode(1, season: 2), episode(2, season: 2)],
            allEpisodes: all
        )
        #expect(player?.episode.id == "e21")
        #expect(screen.upNext?.episode.id == player?.episode.id)
    }

    // MARK: - What the next episode carries

    @Test func theNextEpisodeKeepsTheStreamsTheViewerChose() {
        let offer = UpNextOffer(episode: episode(2), seasonRatingKey: "s1", reason: .credits, autoplays: true)
        let request = offer.nextRequest(showRatingKey: "100", selectedSubtitleId: 13, selectedAudioStreamId: 11)
        #expect(request.selectedSubtitleId == 13)
        #expect(request.selectedAudioStreamId == 11)
    }

    @Test func aDownloadedNextEpisodeResumesWhereTheDownloadWasLeft() {
        let source = OfflinePlaybackSource(
            fileURL: URL(string: "http://127.0.0.1:1/next.m3u8")!,
            markers: [],
            durationSecs: 2_400,
            resumeSecs: 640
        )
        let offer = UpNextOffer(episode: episode(2), seasonRatingKey: "s1", reason: .credits, autoplays: true)
        let request = offer.nextRequest(showRatingKey: "100", offline: source)
        #expect(request.resumePosition == 640)
        #expect(request.offline?.fileURL == source.fileURL)
    }

    // MARK: - Watched

    @Test func reachingTheCreditsFinishesAnEpisodeWhosePercentageIsLow() {
        #expect(WatchedRule.isFinished(positionSecs: 2_112, durationSecs: 2_400, creditsStartSecs: 2_100))
        #expect(WatchedRule.isFinished(positionSecs: 2_100, durationSecs: 2_400, creditsStartSecs: 2_100))
    }

    @Test func withoutCreditsThePercentageStillDecides() {
        #expect(!WatchedRule.isFinished(positionSecs: 2_100, durationSecs: 2_400, creditsStartSecs: nil))
        #expect(WatchedRule.isFinished(positionSecs: 2_300, durationSecs: 2_400, creditsStartSecs: nil))
    }

    @Test func anItemWithNoDurationAndNoCreditsIsNeverFinished() {
        #expect(!WatchedRule.isFinished(positionSecs: 600, durationSecs: 0, creditsStartSecs: nil))
    }

    @Test func aWatchedEpisodePlaysFromTheBeginning() {
        let watched = episode(1, watched: true, offsetMs: 2_112_000)
        #expect(MovieDetailModel(item: watched).resumePosition(offlineResumeSecs: nil) == 0)
        #expect(MovieDetailModel(item: watched).resumePosition(offlineResumeSecs: 600) == 0)
        #expect(MovieDetailModel(item: watched).playTitle == "Play")
        #expect(!MovieDetailModel(item: watched).hasProgress)
        #expect(watched.resumeSecs == 0)
        #expect(watched.progressFraction == 0)
    }

    @Test func aWatchedEpisodeRowOffersPlay() {
        let status = EpisodeStatus(episode: episode(1, watched: true, offsetMs: 2_112_000), isUpNext: false)
        #expect(status.marker == .watched)
        #expect(status.playTitle == "Play")
        #expect(!status.canPlayFromBeginning)
    }

    @Test func theShowFollowsTheMostRecentWatchNotTheOldestUnfinishedEpisode() {
        let episodes = [
            episode(1, watched: true, lastViewedAt: 1_000),
            episode(2, offsetMs: 600_000, lastViewedAt: 2_000),
            episode(3, watched: true, lastViewedAt: 9_000),
            episode(4),
        ]
        let next = ShowDetailModel.computeUpNext(in: episodes)
        #expect(next?.episode.id == "e14")
        #expect(next?.kind == .next)
    }

    @Test func anEpisodeLeftInProgressIsResumedWithoutTimestamps() {
        let episodes = [episode(1, watched: true), episode(2, offsetMs: 300_000), episode(3, offsetMs: 100_000)]
        let next = ShowDetailModel.computeUpNext(in: episodes)
        #expect(next?.episode.id == "e12")
        #expect(next?.kind == .resume)
    }
}

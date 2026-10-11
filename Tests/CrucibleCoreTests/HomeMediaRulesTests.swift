import Foundation
import Testing
@testable import CrucibleCore

struct HomeMediaRulesTests {
    private typealias F = HomeFixtures

    private func movie(offset: Int? = nil, views: Int? = nil) -> PlexMetadata {
        var fields: [String: Any] = ["duration": 6_000_000]
        if let offset { fields["viewOffset"] = offset }
        if let views { fields["viewCount"] = views }
        return F.item("1", fields: fields)
    }

    private func show(leaves: Int?, viewed: Int?, type: String = "show") -> PlexMetadata {
        var fields: [String: Any] = [:]
        if let leaves { fields["leafCount"] = leaves }
        if let viewed { fields["viewedLeafCount"] = viewed }
        return F.item("9", type: type, fields: fields)
    }

    @Test func playableTypesAreMovieEpisodeAndClip() {
        for type in ["movie", "episode", "clip"] {
            #expect(HomeMediaRules.isPlayable(F.item("1", type: type)))
        }
        for type in ["show", "season", "artist", "track"] {
            #expect(!HomeMediaRules.isPlayable(F.item("1", type: type)))
        }
    }

    @Test func movieIsUnwatchedUntilViewedOrStarted() {
        #expect(HomeMediaRules.isUnwatched(movie()))
        #expect(!HomeMediaRules.isUnwatched(movie(views: 1)))
        #expect(!HomeMediaRules.isUnwatched(movie(offset: 60_000)))
    }

    @Test func showAndSeasonAreUnwatchedWhileEpisodesRemain() {
        #expect(HomeMediaRules.isUnwatched(show(leaves: 10, viewed: nil)))
        #expect(HomeMediaRules.isUnwatched(show(leaves: 10, viewed: 9, type: "season")))
        #expect(!HomeMediaRules.isUnwatched(show(leaves: 10, viewed: 10)))
        #expect(!HomeMediaRules.isUnwatched(show(leaves: 0, viewed: 0)))
        #expect(!HomeMediaRules.isUnwatched(show(leaves: nil, viewed: nil)))
    }

    @Test func unwatchedCountIsEpisodesLeft() {
        #expect(HomeMediaRules.unwatchedCount(show(leaves: 10, viewed: 4)) == 6)
        #expect(HomeMediaRules.unwatchedCount(show(leaves: 10, viewed: nil)) == 10)
        #expect(HomeMediaRules.unwatchedCount(show(leaves: 10, viewed: 10)) == nil)
        #expect(HomeMediaRules.unwatchedCount(show(leaves: nil, viewed: nil)) == nil)
        #expect(HomeMediaRules.unwatchedCount(movie()) == nil)
    }

    @Test func watchedStateFollowsViewCountForPlayablesAndLeavesForSeries() {
        #expect(HomeMediaRules.isWatched(movie(views: 2)))
        #expect(!HomeMediaRules.isWatched(movie()))
        #expect(HomeMediaRules.isWatched(show(leaves: 3, viewed: 3)))
        #expect(!HomeMediaRules.isWatched(show(leaves: 3, viewed: 1)))
    }

    @Test func watchedToggleFlipsTheCurrentState() {
        let unwatched = HomeMediaRules.watchedToggle(for: movie())
        #expect(unwatched.title == "Mark Watched")
        #expect(unwatched.targetWatched)
        let watched = HomeMediaRules.watchedToggle(for: movie(views: 1))
        #expect(watched.title == "Mark Unwatched")
        #expect(!watched.targetWatched)
    }

    @Test func playTitleResumesOnceStarted() {
        #expect(HomeMediaRules.playTitle(for: movie()) == "Play")
        #expect(HomeMediaRules.playTitle(for: movie(offset: 1000)) == "Resume")
        #expect(HomeMediaRules.isResuming(movie(offset: 1000)))
    }

    @Test func downloadsAreOfferedForFilesOnly() {
        #expect(HomeMediaRules.isDownloadable(movie()))
        #expect(HomeMediaRules.isDownloadable(F.item("2", type: "episode")))
        #expect(!HomeMediaRules.isDownloadable(show(leaves: 1, viewed: 0)))
        #expect(!HomeMediaRules.isDownloadable(show(leaves: 1, viewed: 0, type: "season")))
    }

    @Test func goToShowResolvesFromEpisodesAndSeasons() {
        let episode = F.item("2", type: "episode", fields: ["grandparentRatingKey": "50", "parentRatingKey": "40"])
        let season = F.item("3", type: "season", fields: ["parentRatingKey": "50"])
        #expect(HomeMediaRules.showRatingKey(for: episode) == "50")
        #expect(HomeMediaRules.showRatingKey(for: season) == "50")
        #expect(HomeMediaRules.showRatingKey(for: movie()) == nil)
        #expect(HomeMediaRules.showRatingKey(for: F.item("4", type: "episode")) == nil)
    }

    @Test func detailRoutes() {
        #expect(HomeMediaRules.detailRoute(for: F.item("7", type: "show")) == .show(ratingKey: "7", initialSeasonKey: nil))
        #expect(
            HomeMediaRules.detailRoute(for: F.item("8", type: "season", fields: ["parentRatingKey": "7"]))
                == .show(ratingKey: "7", initialSeasonKey: "8")
        )
        #expect(
            HomeMediaRules.detailRoute(for: F.item("8", type: "season"))
                == .show(ratingKey: "8", initialSeasonKey: "8")
        )
        let episode = F.item("9", type: "episode", fields: ["grandparentRatingKey": "7", "parentRatingKey": "8"])
        #expect(
            HomeMediaRules.detailRoute(for: episode)
                == .media(ratingKey: "9", mediaType: "episode", showRatingKey: "7", seasonRatingKey: "8")
        )
        #expect(
            HomeMediaRules.detailRoute(for: movie())
                == .media(ratingKey: "1", mediaType: "movie", showRatingKey: nil, seasonRatingKey: nil)
        )
    }
}

struct HomeTapPolicyTests {
    private typealias F = HomeFixtures

    private let fresh = F.item("1")
    private let started = F.item("2", fields: ["viewOffset": 90_000, "duration": 6_000_000])
    private let series = F.item("3", type: "show")

    @Test func continueWatchingPlaysWhateverIsPlayable() {
        #expect(HomeTapPolicy.action(for: fresh, in: .continueWatching) == .play)
        #expect(HomeTapPolicy.action(for: started, in: .continueWatching) == .play)
        #expect(HomeTapPolicy.action(for: series, in: .continueWatching) == .openDetail)
    }

    @Test func upNextPlaysOnlyWhatIsPlayableAndStarted() {
        #expect(HomeTapPolicy.action(for: started, in: .upNext) == .play)
        #expect(HomeTapPolicy.action(for: fresh, in: .upNext) == .openDetail)
        #expect(HomeTapPolicy.action(for: series, in: .upNext) == .openDetail)
    }

    @Test func heroAndRecentlyAddedAlwaysOpenDetail() {
        for item in [fresh, started, series] {
            #expect(HomeTapPolicy.action(for: item, in: .hero) == .openDetail)
            #expect(HomeTapPolicy.action(for: item, in: .recentlyAdded) == .openDetail)
        }
    }

    @Test func playOrDetailFallsBackForUnplayables() {
        #expect(HomeTapPolicy.playOrDetail(for: fresh) == .play)
        #expect(HomeTapPolicy.playOrDetail(for: series) == .openDetail)
    }

    @Test func playPauseIgnoresUnplayables() {
        #expect(HomeTapPolicy.playPauseAction(for: fresh) == .play)
        #expect(HomeTapPolicy.playPauseAction(for: started) == .play)
        #expect(HomeTapPolicy.playPauseAction(for: series) == nil)
    }
}

import Foundation
import Testing
@testable import CrucibleCore

@MainActor
struct RateWatchedTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func defaults() -> UserDefaults {
        let name = "rate-watched-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    private func movie(_ key: String, hoursAgo: Double = 1) -> FinishedTitle {
        FinishedTitle(ratingKey: key, kind: .movie, title: "Movie \(key)", posterPath: "/m/\(key)", finishedAt: now.addingTimeInterval(-hoursAgo * 3_600))
    }

    private func episode(
        _ key: String,
        show: String = "100",
        season: Int = 1,
        hoursAgo: Double = 1,
        endedShow: Bool = false,
        endedSeason: Bool = false
    ) -> FinishedTitle {
        FinishedTitle(
            ratingKey: key,
            kind: .episode,
            title: "Episode \(key)",
            showTitle: "Show \(show)",
            showRatingKey: show,
            seasonNumber: season,
            episodeNumber: Int(key),
            posterPath: "/e/\(key)",
            showPosterPath: "/s/\(show)",
            finishedAt: now.addingTimeInterval(-hoursAgo * 3_600),
            endedShow: endedShow,
            endedSeason: endedSeason
        )
    }

    @Test func aFinishedMovieIsAskedAboutWithItsOwnPoster() {
        let asks = RatingAskRule.asks(from: [movie("7")], rated: [], dismissed: [:], now: now)
        #expect(asks.map(\.ratingKey) == ["7"])
        #expect(asks.first?.mediaType == "movie")
        #expect(asks.first?.reason == .finishedMovie)
        #expect(asks.first?.posterPath == "/m/7")
    }

    @Test func oneEpisodeOfAShowIsNotEnoughToAsk() {
        #expect(RatingAskRule.asks(from: [episode("1")], rated: [], dismissed: [:], now: now).isEmpty)
    }

    @Test func aRunOfEpisodesAsksAboutTheShowOnce() {
        let asks = RatingAskRule.asks(from: [episode("3"), episode("2"), episode("1")], rated: [], dismissed: [:], now: now)
        #expect(asks.count == 1)
        #expect(asks.first?.ratingKey == "100")
        #expect(asks.first?.mediaType == "show")
        #expect(asks.first?.title == "Show 100")
        #expect(asks.first?.posterPath == "/s/100")
        #expect(asks.first?.reason == .watchedEpisodes(3))
    }

    @Test func closingASeasonOrCatchingUpAsksAtOnce() {
        let season = RatingAskRule.asks(from: [episode("8", season: 2, endedSeason: true)], rated: [], dismissed: [:], now: now)
        #expect(season.first?.reason == .finishedSeason(2))
        let caughtUp = RatingAskRule.asks(
            from: [episode("9", endedShow: true), episode("8", season: 2, endedSeason: true)],
            rated: [],
            dismissed: [:],
            now: now
        )
        #expect(caughtUp.first?.reason == .caughtUp)
    }

    @Test func ratedTitlesAreNeverAskedAbout() {
        let asks = RatingAskRule.asks(from: [movie("7"), episode("1", endedShow: true)], rated: ["7", "100"], dismissed: [:], now: now)
        #expect(asks.isEmpty)
    }

    @Test func aDismissedTitleReturnsOnlyForALaterFinish() {
        let dismissedAt = now.addingTimeInterval(-2 * 3_600)
        let before = RatingAskRule.asks(from: [movie("7", hoursAgo: 3)], rated: [], dismissed: ["7": dismissedAt], now: now)
        #expect(before.isEmpty)
        let after = RatingAskRule.asks(from: [movie("7", hoursAgo: 1)], rated: [], dismissed: ["7": dismissedAt], now: now)
        #expect(after.map(\.ratingKey) == ["7"])
    }

    @Test func oldFinishesFallOutOfTheWindowAndNewestComeFirst() {
        let asks = RatingAskRule.asks(
            from: [movie("1", hoursAgo: 30), movie("2", hoursAgo: 2), movie("3", hoursAgo: 24 * 30)],
            rated: [],
            dismissed: [:],
            now: now
        )
        #expect(asks.map(\.ratingKey) == ["2", "1"])
    }

    @Test func reasonKeysTellAsksApart() {
        #expect(RatingAsk.Reason.finishedSeason(2).key != RatingAsk.Reason.finishedSeason(3).key)
        #expect(RatingAsk.Reason.watchedEpisodes(3).key == RatingAsk.Reason.watchedEpisodes(5).key)
    }

    @Test func theLedgerKeepsOneEntryPerTitleAndForgetsAnotherServer() {
        let ledger = FinishedTitlesLedger(defaults: defaults())
        ledger.record(movie("7", hoursAgo: 3), server: "a")
        ledger.record(movie("7", hoursAgo: 1), server: "a")
        #expect(ledger.titles.count == 1)
        #expect(ledger.asks(now: now, server: "a").count == 1)
        #expect(ledger.asks(now: now, server: "b").isEmpty)
        ledger.record(movie("8"), server: "b")
        #expect(ledger.titles.map(\.ratingKey) == ["8"])
    }

    @Test func theLedgerRemembersRatingsDismissalsAndChecksAcrossLaunches() {
        let store = defaults()
        let ledger = FinishedTitlesLedger(defaults: store)
        ledger.record(movie("7"), server: "a")
        ledger.record(movie("8"), server: "a")
        ledger.noteRated("7", isRated: true, at: now)
        ledger.dismiss("8", at: now)
        ledger.noteChecked("8", at: now)
        let reopened = FinishedTitlesLedger(defaults: store)
        #expect(reopened.asks(now: now, server: "a").isEmpty)
        #expect(!reopened.needsCheck("8", now: now.addingTimeInterval(3_600)))
        #expect(reopened.needsCheck("8", now: now.addingTimeInterval(13 * 3_600)))
    }

    @Test func clearingARatingDoesNotBringTheAskBackUntilAnotherFinish() {
        let ledger = FinishedTitlesLedger(defaults: defaults())
        ledger.record(movie("7"), server: "a")
        ledger.noteRated("7", isRated: true, at: now)
        ledger.noteRated("7", isRated: false, at: now)
        #expect(ledger.asks(now: now, server: "a").isEmpty)
    }

    @Test func followedShowsAreTheShowsOfRecentEpisodes() {
        let ledger = FinishedTitlesLedger(defaults: defaults())
        ledger.record(episode("1", show: "100", hoursAgo: 5), server: "a")
        ledger.record(episode("2", show: "100", hoursAgo: 4), server: "a")
        ledger.record(episode("5", show: "200", hoursAgo: 3), server: "a")
        ledger.record(movie("7"), server: "a")
        #expect(ledger.followedShows(since: now.addingTimeInterval(-86_400)).compactMap(\.showRatingKey) == ["200", "100"])
    }

    @Test func observersHearAboutChangesAndResetEmptiesTheLedger() {
        let ledger = FinishedTitlesLedger(defaults: defaults())
        var calls = 0
        let token = ledger.addObserver { calls += 1 }
        ledger.record(movie("7"), server: "a")
        ledger.dismiss("7")
        ledger.reset()
        #expect(calls == 3)
        #expect(ledger.titles.isEmpty)
        ledger.removeObserver(token)
        ledger.record(movie("8"), server: "a")
        #expect(calls == 3)
    }

    @Test func theFeedDropsTitlesTheServerAlreadyHasARatingFor() async {
        let ledger = FinishedTitlesLedger(defaults: defaults())
        ledger.record(movie("7"), server: "a")
        ledger.record(movie("8"), server: "a")
        let feed = RatingAsksFeed(ledger: ledger, server: { "a" }, fetchRating: { key in (key == "7" ? 8 : nil, "/library/metadata/\(key)/thumb/1") })
        let asks = await feed.load(now: now)
        #expect(asks.map(\.ratingKey) == ["8"])
        #expect(asks.first?.posterPath == "/library/metadata/8/thumb/1")
        #expect(!ledger.needsCheck("8", now: now))
    }

    @Test func aFailedCheckKeepsTheAskAndTriesAgainNextTime() async {
        struct Down: Error {}
        let ledger = FinishedTitlesLedger(defaults: defaults())
        ledger.record(movie("7"), server: "a")
        let feed = RatingAsksFeed(ledger: ledger, server: { "a" }, fetchRating: { _ in throw Down() })
        let asks = await feed.load(now: now)
        #expect(asks.map(\.ratingKey) == ["7"])
        #expect(ledger.needsCheck("7", now: now))
    }

    @Test func captionsSayWhyATitleIsAsked() {
        let ask = RatingAsk(ratingKey: "1", mediaType: "show", title: "Show", posterPath: nil, reason: .finishedSeason(2), finishedAt: now)
        #expect(ask.caption(now: now) == "Season 2 finished")
        let caughtUp = RatingAsk(ratingKey: "1", mediaType: "show", title: "Show", posterPath: nil, reason: .caughtUp, finishedAt: now)
        #expect(caughtUp.caption(now: now) == "All caught up")
        let movie = RatingAsk(ratingKey: "2", mediaType: "movie", title: "Movie", posterPath: nil, reason: .finishedMovie, finishedAt: now.addingTimeInterval(-86_400))
        #expect(movie.caption(now: now) == "Yesterday")
        #expect(RatingAskCopy.question(for: movie) == "How was Movie?")
    }
}

@MainActor
struct HomeLayoutTests {
    private func defaults() -> UserDefaults {
        let name = "home-layout-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    @Test func everyRowShowsInItsDefaultPlaceUntilChanged() {
        let store = defaults()
        #expect(HomeLayout.visibleRows(in: store) == HomeRow.allCases)
        #expect(HomeLayout.entries(in: store) == HomeLayout.defaultEntries)
    }

    @Test func rowsCanBeTurnedOffMovedAndReset() {
        let store = defaults()
        HomeLayout.setOn(.recentlyAdded, false, in: store)
        #expect(!HomeLayout.isOn(.recentlyAdded, in: store))
        #expect(!HomeLayout.visibleRows(in: store).contains(.recentlyAdded))
        HomeLayout.move(from: 4, to: 0, in: store)
        #expect(HomeLayout.entries(in: store).first?.row == .rateWatched)
        HomeLayout.reset(in: store)
        #expect(HomeLayout.entries(in: store) == HomeLayout.defaultEntries)
        #expect(store.data(forKey: HomeLayout.storageKey) == nil)
    }

    @Test func aSavedListMissingARowGetsItBackAndDuplicatesGo() throws {
        let store = defaults()
        let saved = [
            HomeLayout.Entry(row: .recentlyAdded, isOn: false),
            HomeLayout.Entry(row: .continueWatching, isOn: true),
            HomeLayout.Entry(row: .recentlyAdded, isOn: true),
        ]
        store.set(try JSONEncoder().encode(saved), forKey: HomeLayout.storageKey)
        let entries = HomeLayout.entries(in: store)
        #expect(Set(entries.map(\.row)) == Set(HomeRow.allCases))
        #expect(entries.count == HomeRow.allCases.count)
        #expect(entries.first == HomeLayout.Entry(row: .recentlyAdded, isOn: false))
    }

    @Test func hiddenRowsGiveNothingToTheArrangement() {
        let resumable = HomeFixtures.item("1", fields: ["duration": 2_400_000, "viewOffset": 60_000])
        let next = HomeFixtures.item("5", type: "episode")
        let recent = HomeFixtures.item("9")
        let buckets = HomeBuckets(continueWatching: [resumable], onDeck: [next], recent: [recent])
        let noContinue = HomeArrangement(buckets: buckets, rows: [.upNext, .recentlyAdded])
        #expect(noContinue.hero?.id == "5")
        #expect(!noContinue.heroIsContinue)
        #expect(noContinue.continueRail.isEmpty)
        let onlyRecent = HomeArrangement(buckets: buckets, rows: [.recentlyAdded])
        #expect(onlyRecent.hero == nil)
        #expect(onlyRecent.upNext.isEmpty)
        #expect(onlyRecent.recent.map(\.id) == ["9"])
        let nothing = HomeArrangement(buckets: buckets, rows: [.thisWeek])
        #expect(nothing.isEmpty)
    }

    @Test func removalIsOfferedOnlyInTheContinueWatchingRows() {
        let movie = HomeFixtures.item("1")
        #expect(ContinueWatchingRemoval.applies(to: movie, in: .continueWatching))
        #expect(ContinueWatchingRemoval.applies(to: movie, in: .upNext))
        #expect(ContinueWatchingRemoval.applies(to: movie, in: .hero))
        #expect(!ContinueWatchingRemoval.applies(to: movie, in: .recentlyAdded))
        #expect(!ContinueWatchingRemoval.applies(to: HomeFixtures.item("2", type: "clip"), in: .continueWatching))
    }

    @Test func removalIsAPutOnTheServerNotPlexTV() throws {
        let endpoint = PlexEndpoint.removeFromContinueWatching(ratingKey: "42")
        let request = try endpoint.urlRequest(baseURL: URL(string: "http://pms.test:32400")!, token: "t")
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.host == "pms.test")
        #expect(request.url?.path == "/actions/removeFromContinueWatching")
        #expect(request.url?.query?.contains("ratingKey=42") == true)
    }
}

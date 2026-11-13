import Foundation
import Testing
@testable import CrucibleCore

struct WatchCardTests {
    private typealias F = DetailFixtures

    private static let day: Int = 86_400
    private static let start = 1_793_000_000

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let locale = Locale(identifier: "en_US")

    private func facts(_ subject: WatchCardSubject) -> WatchCardFacts {
        WatchCardFacts(subject: subject, calendar: calendar, locale: locale)
    }

    private func movie(_ fields: [String: Any] = [:]) -> PlexMetadata {
        var base: [String: Any] = [
            "ratingKey": "1003", "type": "movie", "title": "Low Tide", "year": 2017, "duration": 6_480_000,
            "contentRating": "R", "thumb": "/m/thumb", "art": "/m/art",
            "Genre": [["tag": "Drama"], ["tag": "Mystery"], ["tag": "drama"], ["tag": "Thriller"], ["tag": "Crime"]],
            "Director": [["tag": "Ines Varga"], ["tag": "Tom Hale"], ["tag": "Third Person"]],
        ]
        base.merge(fields) { _, new in new }
        return F.item(base)
    }

    private func episode(_ number: Int, season: Int = 1, watchedDay: Int?, durationMs: Int = 2_700_000) -> PlexMetadata {
        var fields: [String: Any] = [
            "ratingKey": "e\(season)\(number)", "type": "episode", "title": "Episode \(number)", "index": number,
            "parentIndex": season, "duration": durationMs, "originallyAvailableAt": "\(2018 + season)-03-0\(min(number, 9))",
        ]
        if let watchedDay {
            fields["viewCount"] = 1
            fields["lastViewedAt"] = Self.start + watchedDay * Self.day + 3_600
        }
        return F.item(fields)
    }

    private var show: PlexMetadata {
        F.item([
            "ratingKey": "2001", "type": "show", "title": "The Salt Road", "year": 2019, "studio": "Gannet Films",
            "thumb": "/s/thumb", "art": "/s/art", "leafCount": 18, "viewedLeafCount": 11, "childCount": 2,
            "Genre": [["tag": "Drama"], ["tag": "Thriller"]], "contentRating": "TV-MA",
        ])
    }

    // MARK: - Movie

    @Test func movieCarriesItsFactsCreditAndGenres() {
        let result = facts(WatchCardSubject(scope: .movie, item: movie()))
        #expect(result.eyebrow == "MOVIE")
        #expect(result.title == "Low Tide")
        #expect(result.context == nil)
        #expect(result.facts == ["2017", "1 h 48 m", "R"])
        #expect(result.credit == "Directed by Ines Varga & Tom Hale")
        #expect(result.genres == ["Drama", "Mystery", "Thriller"])
        #expect(result.posterPath == "/m/thumb")
        #expect(result.backdropPath == "/m/art")
        #expect(result.placeholderSymbol == "film")
        #expect(result.shareTitle == "Low Tide")
        #expect(result.progress == nil)
    }

    @Test func movieSaysWhenItWasWatchedAndHowOften() {
        let watched = movie(["lastViewedAt": Self.start + 3_600, "viewCount": 3])
        let result = facts(WatchCardSubject(scope: .movie, item: watched))
        #expect(result.watched.count == 2)
        #expect(result.watched[0].hasPrefix("Watched "))
        #expect(result.watched[0].contains("2026"))
        #expect(result.watched[1] == "Seen 3 times")

        let once = facts(WatchCardSubject(scope: .movie, item: movie(["lastViewedAt": Self.start, "viewCount": 1])))
        #expect(once.watched.count == 1)
        #expect(facts(WatchCardSubject(scope: .movie, item: movie())).watched.isEmpty)
    }

    @Test func originalTitleShowsOnlyWhenItDiffers() {
        #expect(facts(WatchCardSubject(scope: .movie, item: movie(["originalTitle": "Marea Baja"]))).context == "Marea Baja")
        #expect(facts(WatchCardSubject(scope: .movie, item: movie(["originalTitle": "low tide"]))).context == nil)
        #expect(facts(WatchCardSubject(scope: .movie, item: movie(["originalTitle": "  "]))).context == nil)
    }

    @Test func scoresKeepOnlyNamedSourcesAndTheServedRating() {
        let named = movie([
            "audienceRating": 8.1, "audienceRatingImage": "imdb://image.rating",
            "rating": 9.2, "ratingImage": "rottentomatoes://image.rating.ripe", "userRating": 9,
        ])
        let result = facts(WatchCardSubject(scope: .movie, item: named))
        #expect(result.scores.map(\.scoreSource) == [.imdb, .rottenTomatoes])
        #expect(result.servedRating == UserRating(halfStars: 9))
        #expect(result.ratingKey == "1003")

        let unnamed = facts(WatchCardSubject(scope: .movie, item: movie(["audienceRating": 8.1, "rating": 7.0])))
        #expect(unnamed.scores.isEmpty)
    }

    @Test func traktScoresFillInUpToTheLimit() {
        let scores = [
            TraktScore(source: .trakt, value: 82, votes: nil, link: nil),
            TraktScore(source: .letterboxd, value: 3.9, votes: nil, link: nil),
            TraktScore(source: .metascore, value: 71, votes: nil, link: nil),
            TraktScore(source: .tmdb, value: 7.7, votes: nil, link: nil),
        ]
        let result = facts(WatchCardSubject(scope: .movie, item: movie(), scores: scores))
        #expect(result.scores.count == WatchCardFacts.scoreLimit)
        #expect(result.scores.first?.scoreSource == .trakt)
    }

    // MARK: - Episode

    @Test func episodeNamesItsShowAndUsesTheSeasonPoster() {
        let item = F.item([
            "ratingKey": "4001", "type": "episode", "title": "The Wreck at Gannet Point", "index": 1, "parentIndex": 1,
            "grandparentTitle": "The Salt Road", "thumb": "/e/still", "parentThumb": "/season/thumb",
            "grandparentThumb": "/s/thumb", "duration": 2_700_000, "originallyAvailableAt": "2019-03-01",
        ])
        let result = facts(WatchCardSubject(scope: .episode, item: item, show: show))
        #expect(result.eyebrow == "S1 · E1")
        #expect(result.title == "The Wreck at Gannet Point")
        #expect(result.context == "The Salt Road")
        #expect(result.posterPath == "/season/thumb")
        #expect(result.backdropPath == "/e/still")
        #expect(result.genres == ["Drama", "Thriller"])
        #expect(result.facts.contains("45 min"))
        #expect(result.facts.contains("TV-MA"))
        #expect(result.placeholderSymbol == "tv")
        #expect(result.shareTitle == "The Wreck at Gannet Point · The Salt Road")
    }

    // MARK: - Season

    @Test func finishedSeasonCountsEveryEpisodeAndTheDaysItTook() {
        let season = F.item([
            "ratingKey": "3001", "type": "season", "title": "Season 1", "index": 1, "parentTitle": "The Salt Road",
            "thumb": "/season/thumb", "leafCount": 4, "viewedLeafCount": 4, "parentRatingKey": "2001",
        ])
        let episodes = [episode(2, watchedDay: 1), episode(1, watchedDay: 0), episode(3, watchedDay: 2), episode(4, watchedDay: 3)]
        let result = facts(WatchCardSubject(scope: .season, item: season, show: show, episodes: episodes))
        #expect(result.eyebrow == "Season 1")
        #expect(result.title == "The Salt Road")
        #expect(result.facts == ["2019", "Gannet Films", "3 h"])
        #expect(result.progress?.segments == [1, 1, 1, 1])
        #expect(result.progress?.isComplete == true)
        #expect(result.progress?.label == "All 4 episodes")
        #expect(result.watched.count == 2)
        #expect(result.watched[0].hasPrefix("Watched "))
        #expect(result.watched[1] == "In 4 days")
        #expect(result.shareTitle == "The Salt Road · Season 1")
        #expect(result.posterPath == "/season/thumb")
    }

    @Test func seasonWatchedInOneDaySaysSo() {
        let season = F.item(["ratingKey": "3001", "type": "season", "title": "Season 1", "index": 1, "leafCount": 3, "viewedLeafCount": 3])
        let episodes = [episode(1, watchedDay: 5), episode(2, watchedDay: 5), episode(3, watchedDay: 5)]
        let result = facts(WatchCardSubject(scope: .season, item: season, show: show, episodes: episodes))
        #expect(result.watched.last == "In one day")
    }

    @Test func slowOrPartlyWatchedSeasonShowsWhereItStands() {
        let season = F.item(["ratingKey": "3002", "type": "season", "title": "", "index": 2, "leafCount": 4, "viewedLeafCount": 2])
        let partial = F.item([
            "ratingKey": "e23", "type": "episode", "title": "Episode 3", "index": 3, "parentIndex": 2,
            "duration": 2_000_000, "viewOffset": 1_000_000,
        ])
        let episodes = [episode(1, season: 2, watchedDay: 0), episode(2, season: 2, watchedDay: 40), partial, episode(4, season: 2, watchedDay: nil)]
        let result = facts(WatchCardSubject(scope: .season, item: season, show: show, episodes: episodes))
        #expect(result.eyebrow == "Season 2")
        #expect(result.progress?.segments == [1, 1, 0.5, 0])
        #expect(result.progress?.label == "2 of 4 episodes")
        #expect(result.progress?.isComplete == false)
        #expect(result.watched.count == 1)
    }

    @Test func rewatchedEpisodesDoNotStretchTheSpan() {
        let season = F.item(["ratingKey": "3001", "type": "season", "title": "Season 1", "index": 1, "leafCount": 4, "viewedLeafCount": 4])
        let rewatched = F.item([
            "ratingKey": "e14", "type": "episode", "title": "Episode 4", "index": 4, "parentIndex": 1, "duration": 2_700_000,
            "viewCount": 2, "lastViewedAt": Self.start + 200 * Self.day,
        ])
        let episodes = [episode(1, watchedDay: 0), episode(2, watchedDay: 1), episode(3, watchedDay: 2), rewatched]
        let result = facts(WatchCardSubject(scope: .season, item: season, show: show, episodes: episodes))
        #expect(result.watched.count == 2)
        #expect(result.watched[1] == "In 3 days")
        #expect(!result.watched[0].contains("2027"))

        let allRewatched = [rewatched]
        let fallback = facts(WatchCardSubject(scope: .season, item: season, show: show, episodes: allRewatched))
        #expect(fallback.watched.count == 1)
    }

    @Test func paceIsOnlyClaimedForAFinishedSeason() {
        let season = F.item(["ratingKey": "3001", "type": "season", "title": "Season 1", "index": 1, "leafCount": 10, "viewedLeafCount": 3])
        let episodes = [episode(1, watchedDay: 5), episode(2, watchedDay: 5), episode(3, watchedDay: 5)]
        let result = facts(WatchCardSubject(scope: .season, item: season, show: show, episodes: episodes))
        #expect(result.watched.count == 1)
        #expect(result.progress?.label == "3 of 10 episodes")
    }

    @Test func nothingWatchedYetShowsNoProgress() {
        let season = F.item(["ratingKey": "3001", "type": "season", "title": "Pilot", "index": 1, "leafCount": 1, "viewedLeafCount": 0])
        let result = facts(WatchCardSubject(scope: .season, item: season, show: show, episodes: [episode(1, watchedDay: nil)]))
        #expect(result.progress == nil)
        #expect(result.watched.isEmpty)
    }

    // MARK: - Show

    @Test func showSpansItsYearsAndCountsSeasons() {
        let seasons = [F.season(1, watched: 8, total: 8), F.season(2, watched: 3, total: 10)]
        let episodes = [episode(1, watchedDay: 0), episode(1, season: 4, watchedDay: 30)]
        let result = facts(WatchCardSubject(scope: .show, item: show, seasons: seasons, episodes: episodes))
        #expect(result.eyebrow == "TV SERIES")
        #expect(result.title == "The Salt Road")
        #expect(result.facts.first == "2019–2022")
        #expect(result.facts.contains("Gannet Films"))
        #expect(result.facts.contains("2 Seasons"))
        #expect(result.progress?.segments == [1, 0.3])
        #expect(result.progress?.label == "11 of 18 episodes")
    }

    @Test func specialsAreNotASeason() {
        let seasons = [F.season(0, watched: 0, total: 3, title: "Specials"), F.season(1, watched: 8, total: 8), F.season(2, watched: 3, total: 10)]
        let result = facts(WatchCardSubject(scope: .show, item: show, seasons: seasons))
        #expect(result.facts.contains("2 Seasons"))
        #expect(result.progress?.segments == [1, 0.3])
    }

    @Test func unnamedPlexScoresLeaveRoomForTrakt() {
        let scores = [
            TraktScore(source: .imdb, value: 7.6, votes: nil, link: nil),
            TraktScore(source: .metascore, value: 71, votes: nil, link: nil),
            TraktScore(source: .letterboxd, value: 3.9, votes: nil, link: nil),
            TraktScore(source: .tmdb, value: 7.7, votes: nil, link: nil),
        ]
        let result = facts(WatchCardSubject(scope: .movie, item: movie(["audienceRating": 8.1, "rating": 7.0]), scores: scores))
        #expect(result.scores.map(\.scoreSource) == [.imdb, .metascore, .letterboxd])
    }

    @Test func finishedShowIsTheCompleteSeries() {
        let done = F.item(["ratingKey": "2001", "type": "show", "title": "Dry Season", "year": 2022, "leafCount": 6, "viewedLeafCount": 6])
        let result = facts(WatchCardSubject(scope: .show, item: done, seasons: [F.season(1, watched: 6, total: 6)]))
        #expect(result.eyebrow == "COMPLETE SERIES")
        #expect(result.facts.first == "2022")
        #expect(result.progress?.isComplete == true)
        #expect(result.progress?.label == "All 6 episodes")
    }

    @Test func longShowsCountRuntimeInHours() {
        let episodes = (1...30).map { episode($0, watchedDay: nil, durationMs: 3_000_000) }
        let result = facts(WatchCardSubject(scope: .show, item: show, episodes: episodes))
        #expect(result.facts.contains("25 h"))
    }

    // MARK: - Origin

    @Test func originFollowsTheItemItStartsFrom() {
        let film = WatchCardOrigin(item: F.item(["ratingKey": "1", "type": "movie"]))
        #expect(film?.scopes == [.movie])
        #expect(film?.startingScope == .movie)

        let episode = WatchCardOrigin(item: F.item([
            "ratingKey": "4", "type": "episode", "parentRatingKey": "3", "parentIndex": 2, "grandparentRatingKey": "2",
        ]))
        #expect(episode?.scopes == [.episode, .season, .show])
        #expect(episode?.startingScope == .episode)

        let season = WatchCardOrigin(item: F.item(["ratingKey": "3", "type": "season", "index": 2, "parentRatingKey": "2"]))
        #expect(season?.scopes == [.season, .show])
        #expect(season?.title(for: .season) == "Season 2")

        #expect(WatchCardOrigin(item: F.item(["ratingKey": "2", "type": "show"]))?.scopes == [.show])
        #expect(WatchCardOrigin(item: F.item(["ratingKey": "9", "type": "clip"])) == nil)
    }

    @Test func originForAnAskOpensOnTheSeasonItClosed() {
        let finished = Date(timeIntervalSince1970: TimeInterval(Self.start))
        let season = WatchCardOrigin(ask: RatingAsk(ratingKey: "2001", mediaType: "show", title: "Show", posterPath: nil, reason: .finishedSeason(3), finishedAt: finished))
        #expect(season.startingScope == .season)
        #expect(season.seasonIndex == 3)
        #expect(season.scopes == [.season, .show])

        let caughtUp = WatchCardOrigin(ask: RatingAsk(ratingKey: "2001", mediaType: "show", title: "Show", posterPath: nil, reason: .caughtUp, finishedAt: finished))
        #expect(caughtUp.startingScope == .show)
        #expect(caughtUp.scopes == [.show])

        let film = WatchCardOrigin(ask: RatingAsk(ratingKey: "1003", mediaType: "movie", title: "Film", posterPath: nil, reason: .finishedMovie, finishedAt: finished))
        #expect(film.scopes == [.movie])
    }

    @Test func startingAtAScopeKeepsEveryOtherCard() {
        let finished = Date(timeIntervalSince1970: TimeInterval(Self.start))
        let ask = RatingAsk(ratingKey: "2001", mediaType: "show", title: "Show", posterPath: nil, reason: .finishedSeason(2), finishedAt: finished)
        let rated = WatchCardOrigin(ask: ask).starting(at: .show)
        #expect(rated.startingScope == .show)
        #expect(rated.scopes == [.season, .show])
        #expect(rated.seasonIndex == 2)
        #expect(WatchCardOrigin(ask: ask).starting(at: .movie).startingScope == .season)
    }

    @Test func showPageOpensOnAFinishedSeasonUntilTheShowIsDone() {
        let finishedSeason = F.season(1, watched: 8, total: 8)
        let openSeason = F.season(2, watched: 3, total: 10)
        #expect(WatchCardOrigin(show: show, selectedSeason: finishedSeason).startingScope == .season)
        #expect(WatchCardOrigin(show: show, selectedSeason: openSeason).startingScope == .show)
        #expect(WatchCardOrigin(show: show, selectedSeason: nil).scopes == [.show])
        let done = F.item(["ratingKey": "2001", "type": "show", "title": "Done", "leafCount": 8, "viewedLeafCount": 8])
        #expect(WatchCardOrigin(show: done, selectedSeason: finishedSeason).startingScope == .show)
    }

    @Test func finishedPlaybackOpensOnTheShowAfterAFinale() {
        let finale = PlaybackRequest(ratingKey: "4030", mediaType: "episode", showRatingKey: "2001", seasonRatingKey: "3004", resumePosition: 0)
        let origin = WatchCardOrigin(finished: finale)
        #expect(origin?.startingScope == .show)
        #expect(origin?.scopes == [.episode, .season, .show])

        let film = PlaybackRequest(ratingKey: "1003", mediaType: "movie", showRatingKey: nil, seasonRatingKey: nil, resumePosition: 0)
        #expect(WatchCardOrigin(finished: film)?.scopes == [.movie])

        let orphan = PlaybackRequest(ratingKey: "4030", mediaType: "episode", showRatingKey: nil, seasonRatingKey: nil, resumePosition: 0)
        #expect(WatchCardOrigin(finished: orphan)?.startingScope == .episode)
        #expect(WatchCardOrigin(finished: PlaybackRequest(ratingKey: "1", mediaType: "clip", showRatingKey: nil, seasonRatingKey: nil, resumePosition: 0)) == nil)
    }

    // MARK: - Options, words and dates

    @Test func optionsSurviveASaveAndFallBackWhenMissing() {
        let name = "watch-card-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(WatchCardOptions.saved(in: defaults) == WatchCardOptions())

        let chosen = WatchCardOptions(format: .story, style: .noir, showsRating: false, showsScores: false, showsWatched: true, showsDetails: false)
        chosen.save(in: defaults)
        #expect(WatchCardOptions.saved(in: defaults) == chosen)

        defaults.set(["format": "poster", "style": 3, "rating": "yes"], forKey: WatchCardOptions.storageKey)
        #expect(WatchCardOptions.saved(in: defaults) == WatchCardOptions())
    }

    @Test func wordsAreTrimmedOntoOneLineAndCapped() {
        #expect(WatchCardTake.clean(nil) == nil)
        #expect(WatchCardTake.clean("  \n ") == nil)
        #expect(WatchCardTake.clean("  Loved it.\nEvery minute. ") == "Loved it. Every minute.")
        let long = String(repeating: "a", count: 300)
        #expect(WatchCardTake.clean(long)?.count == WatchCardTake.limit)
    }

    @Test func daysSpannedCountsBothEnds() {
        let first = Date(timeIntervalSince1970: TimeInterval(Self.start))
        #expect(WatchCardDates.daysSpanned(from: first, to: first.addingTimeInterval(600), calendar: calendar) == 1)
        #expect(WatchCardDates.daysSpanned(from: first, to: first.addingTimeInterval(TimeInterval(Self.day * 3)), calendar: calendar) == 4)
        let span = WatchCardDates.span(from: first, to: first.addingTimeInterval(TimeInterval(Self.day * 3)), calendar: calendar, locale: locale)
        #expect(span != WatchCardDates.day(first, calendar: calendar, locale: locale))
        #expect(WatchCardDates.span(from: first, to: first.addingTimeInterval(60), calendar: calendar, locale: locale) == WatchCardDates.day(first, calendar: calendar, locale: locale))
    }

    @Test func formatsHaveTheSizesSocialAppsExpect() {
        let sizes = WatchCardFormat.allCases.map { "\($0.pixelSize.width)x\($0.pixelSize.height)" }
        #expect(sizes == ["1080x1350", "1080x1920", "1080x1080"])
    }

    @Test func spokenSummaryReadsTheCard() {
        let result = facts(WatchCardSubject(scope: .movie, item: movie(["lastViewedAt": Self.start])))
        let spoken = result.spokenSummary(rating: UserRating(halfStars: 9), take: " Great. ")
        #expect(spoken.hasPrefix("MOVIE, Low Tide, 2017"))
        #expect(spoken.contains("4.5 out of 5 stars"))
        #expect(spoken.contains("Great."))
    }
}

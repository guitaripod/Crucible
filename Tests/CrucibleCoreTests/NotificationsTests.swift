import Foundation
import Testing
@testable import CrucibleCore

struct ReminderScheduleTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Helsinki")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func anHourLaterLandsAnHourLaterOutsideQuietHours() {
        let reminder = ReminderSchedule.ratingReminder(finishedAt: date(3, 14), timing: .anHourLater, quietHours: true, calendar: calendar)
        #expect(reminder == date(3, 15))
    }

    @Test func aReminderThatWouldLandAtNightWaitsForNineInTheMorning() {
        let lateNight = ReminderSchedule.ratingReminder(finishedAt: date(3, 23, 30), timing: .anHourLater, quietHours: true, calendar: calendar)
        #expect(lateNight == date(4, 9))
        let earlyMorning = ReminderSchedule.ratingReminder(finishedAt: date(4, 2), timing: .anHourLater, quietHours: true, calendar: calendar)
        #expect(earlyMorning == date(4, 9))
        let unquiet = ReminderSchedule.ratingReminder(finishedAt: date(3, 23, 30), timing: .anHourLater, quietHours: false, calendar: calendar)
        #expect(unquiet == date(4, 0, 30))
    }

    @Test func eveningMeansSevenTodayOrTomorrowWhenItIsLate() {
        #expect(ReminderSchedule.ratingReminder(finishedAt: date(3, 13), timing: .thisEvening, quietHours: true, calendar: calendar) == date(3, 19))
        #expect(ReminderSchedule.ratingReminder(finishedAt: date(3, 18, 50), timing: .thisEvening, quietHours: true, calendar: calendar) == date(4, 19))
    }

    @Test func nextMorningIsNineTheNextDay() {
        #expect(ReminderSchedule.ratingReminder(finishedAt: date(3, 21), timing: .nextMorning, quietHours: true, calendar: calendar) == date(4, 9))
    }

    @Test func titlesFinishedOneAfterAnotherShareTheLastOnesReminder() {
        let asks = [date(3, 20), date(3, 22, 30), date(3, 21)].enumerated().map { index, finishedAt in
            RatingAsk(ratingKey: "\(index)", mediaType: "movie", title: "Film \(index)", posterPath: nil, reason: .finishedMovie, finishedAt: finishedAt)
        }
        let hourLater = ReminderSchedule.ratingReminder(for: asks, timing: .anHourLater, quietHours: false, calendar: calendar)
        #expect(hourLater == date(3, 23, 30))
        let quiet = ReminderSchedule.ratingReminder(for: asks, timing: .anHourLater, quietHours: true, calendar: calendar)
        #expect(quiet == date(4, 9))
        #expect(ReminderSchedule.ratingReminder(for: [], timing: .anHourLater, quietHours: true, calendar: calendar) == nil)
    }

    @Test func theRecapIsTheNextSundayEvening() {
        let wednesday = date(4, 12)
        #expect(ReminderSchedule.nextRecap(after: wednesday, calendar: calendar) == date(8, 18))
        #expect(ReminderSchedule.nextRecap(after: date(8, 19), calendar: calendar) == date(15, 18))
    }

    @Test func yearInReviewIsTheFirstOfDecemberUntilItPasses() {
        #expect(ReminderSchedule.yearInReview(after: date(3, 12), calendar: calendar) == date(1, 10, month: 12))
        #expect(ReminderSchedule.yearInReview(after: date(2, 12, month: 12), calendar: calendar) == nil)
    }
}

@MainActor
struct NotificationLedgerTests {
    private func defaults() -> UserDefaults {
        let name = "notification-ledger-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    private func ask(_ key: String, _ reason: RatingAsk.Reason) -> RatingAsk {
        RatingAsk(ratingKey: key, mediaType: "show", title: "Show", posterPath: nil, reason: reason, finishedAt: Date())
    }

    @Test func aReminderGoesOutOncePerReason() {
        let ledger = NotificationLedger(defaults: defaults())
        let first = ask("1", .watchedEpisodes(3))
        #expect(ledger.asksNeedingReminders([first], server: "a").count == 1)
        ledger.noteReminded(first)
        #expect(ledger.asksNeedingReminders([ask("1", .watchedEpisodes(4))], server: "a").isEmpty)
        #expect(ledger.asksNeedingReminders([ask("1", .finishedSeason(1))], server: "a").count == 1)
    }

    @Test func theFirstCheckStartsNowAndLaterChecksMoveForward() {
        let ledger = NotificationLedger(defaults: defaults())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ledger.checkWindowStart(server: "a", now: now) == 1_800_000_000)
        ledger.noteChecked(upTo: 1_800_000_500)
        ledger.noteChecked(upTo: 1_800_000_100)
        #expect(ledger.checkWindowStart(server: "a", now: now.addingTimeInterval(9_999)) == 1_800_000_500)
    }

    @Test func anotherServerStartsOverAndAnnouncementsPersist() {
        let store = defaults()
        let ledger = NotificationLedger(defaults: store)
        _ = ledger.checkWindowStart(server: "a", now: Date())
        ledger.noteAnnounced(["episode.5"])
        #expect(NotificationLedger(defaults: store).wasAnnounced("episode.5"))
        _ = ledger.checkWindowStart(server: "b", now: Date())
        #expect(!ledger.wasAnnounced("episode.5"))
    }
}

struct LibraryNewsTests {
    private func meta(_ json: [String: Any]) -> PlexMetadata {
        try! JSONDecoder().decode(PlexMetadata.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func episode(_ key: String, show: String = "100", season: Int = 1, index: Int, addedAt: Int, watched: Bool = false) -> PlexMetadata {
        var json: [String: Any] = [
            "ratingKey": key, "type": "episode", "title": "Episode \(index)", "grandparentRatingKey": show,
            "grandparentTitle": "Show \(show)", "grandparentThumb": "/s/\(show)", "parentIndex": season, "index": index,
            "addedAt": addedAt, "grandparentGuid": "plex://show/\(show)",
        ]
        if watched { json["viewCount"] = 1 }
        return meta(json)
    }

    private func check(recent: [PlexMetadata], children: [String: [PlexMetadata]] = [:], leaves: [String: [PlexMetadata]] = [:], watchlist: Set<String>? = nil) -> LibraryNewsCheck {
        LibraryNewsCheck(
            fetchRecent: { recent },
            fetchChildren: { children[$0] ?? [] },
            fetchLeaves: { leaves[$0] ?? [] },
            fetchWatchlistGuids: { watchlist }
        )
    }

    @Test func newEpisodesOfFollowedShowsAreFoundWhateverRecentlyAddedListed() async throws {
        let season = meta(["ratingKey": "300", "type": "season", "title": "Season 2", "parentRatingKey": "200", "addedAt": 110])
        let show = meta(["ratingKey": "400", "type": "show", "title": "Third", "addedAt": 120])
        let check = check(
            recent: [episode("1", index: 4, addedAt: 105), season, show, episode("9", show: "999", index: 1, addedAt: 130)],
            children: ["300": [episode("31", show: "200", season: 2, index: 1, addedAt: 110), episode("30", show: "200", season: 1, index: 9, addedAt: 50)]],
            leaves: ["400": [episode("41", show: "400", index: 2, addedAt: 120, watched: true), episode("42", show: "400", index: 3, addedAt: 121)]]
        )
        let news = try await check.run(followed: ["100", "200", "400"], since: 100, announced: [])
        #expect(news.shows.map(\.showRatingKey) == ["100", "200", "400"])
        #expect(news.shows.map { $0.episodes.map(\.id) } == [["1"], ["31"], ["42"]])
        #expect(news.newestAddedAt == 130)
        #expect(news.announcedKeys.contains("episode.31"))
    }

    @Test func oldAnnouncedAndUnfollowedEpisodesStayQuiet() async throws {
        let check = check(recent: [episode("1", index: 1, addedAt: 90), episode("2", index: 2, addedAt: 101), episode("3", show: "777", index: 1, addedAt: 102)])
        let news = try await check.run(followed: ["100"], since: 100, announced: ["episode.2"])
        #expect(news.shows.isEmpty)
        #expect(news.newestAddedAt == 102)
    }

    @Test func watchlistTitlesThatArriveAreAnnouncedOnceEach() async throws {
        let movie = meta(["ratingKey": "50", "type": "movie", "title": "Dune", "guid": "plex://movie/dune", "addedAt": 150, "thumb": "/m/50"])
        let check = check(
            recent: [movie, episode("61", show: "60", index: 1, addedAt: 151), episode("62", show: "60", index: 2, addedAt: 152)],
            watchlist: ["plex://movie/dune", "plex://show/60"]
        )
        let news = try await check.run(followed: [], since: 100, announced: [])
        #expect(news.arrivals.map(\.ratingKey) == ["50", "60"])
        #expect(news.arrivals.map(\.mediaType) == ["movie", "show"])
        let again = try await check.run(followed: [], since: 100, announced: Set(news.announcedKeys))
        #expect(again.arrivals.isEmpty)
    }

    @Test func aFollowedShowIsAnnouncedAsNewEpisodesNotAsAnArrival() async throws {
        let check = check(recent: [episode("61", show: "60", index: 1, addedAt: 151)], watchlist: ["plex://show/60"])
        let news = try await check.run(followed: ["60"], since: 100, announced: [])
        #expect(news.shows.count == 1)
        #expect(news.arrivals.isEmpty)
    }

    @Test func oneRatingReminderAsksAboutOneTitleOrNamesSeveral() {
        let titles = ["Dune", "Severance", "Andor", "Arcane", "Shogun"]
        let asks = titles.enumerated().map { index, title in
            RatingAsk(ratingKey: "\(index)", mediaType: "movie", title: title, posterPath: nil, reason: .finishedMovie, finishedAt: Date())
        }
        #expect(NotificationCopy.ratingTitle(for: Array(asks.prefix(1))) == "How was Dune?")
        #expect(NotificationCopy.ratingBody(for: Array(asks.prefix(1))) == NotificationCopy.ratingBody(for: asks[0]))
        #expect(NotificationCopy.ratingTitle(for: asks) == RatingAskCopy.rowTitle)
        let three = NotificationCopy.ratingBody(for: Array(asks.prefix(3)))
        #expect(["Dune", "Severance", "Andor"].allSatisfy(three.contains))
        let five = NotificationCopy.ratingBody(for: asks)
        #expect(five.contains("Dune") && five.contains("Severance") && five.contains("3 more"))
        #expect(!five.contains("Andor"))
    }

    @Test func notificationWordsNameTheShowAndTheEpisodes() {
        let one = ShowNews(showRatingKey: "1", showTitle: "Severance", posterPath: nil, episodes: [episode("1", season: 2, index: 5, addedAt: 1)])
        #expect(NotificationCopy.newEpisodesTitle(one) == "New Episode of Severance")
        #expect(NotificationCopy.newEpisodesBody(one).contains("Episode 5"))
        let many = ShowNews(showRatingKey: "1", showTitle: "Severance", posterPath: nil, episodes: (1...5).map { episode("\($0)", index: $0, addedAt: 1) })
        #expect(NotificationCopy.newEpisodesTitle(many) == "5 New Episodes of Severance")
        #expect(NotificationCopy.newEpisodesBody(many).hasSuffix("and 2 more"))
        #expect(NotificationCopy.recapBody(seconds: 3_600, deltaPercent: 30).contains("30%"))
        #expect(NotificationCopy.yearInReviewTitle(year: 2026) == "Your 2026 in Review")
    }
}

import Foundation
import Testing
@testable import CrucibleCore

struct ProPersonalDetailsTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let now = ProPersonalDetailsTests.utc.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!

    private func history(
        year: Int = 2026,
        plays: Int = 226,
        movies: Int = 14,
        episodes: Int = 212,
        hours: Int? = 180,
        allTime: Int? = 840,
        firstYear: Int? = 2019
    ) -> ProViewerFacts.History {
        ProViewerFacts.History(
            year: year, playsThisYear: plays, moviesThisYear: movies, episodesThisYear: episodes, hoursThisYear: hours,
            playsAllTime: allTime, firstYear: firstYear
        )
    }

    private func details(_ facts: ProViewerFacts) -> [ProFeature: String] {
        ProPersonalDetails.make(facts, now: now, calendar: Self.utc)
    }

    private func headline(_ facts: ProViewerFacts) -> String? {
        ProPersonalDetails.headline(facts, now: now, calendar: Self.utc)
    }

    @Test func aViewerNothingIsKnownAboutKeepsEveryGeneralLine() {
        let facts = ProViewerFacts()
        #expect(details(facts).isEmpty)
        #expect(headline(facts) == nil)
        for feature in ProFeature.allCases {
            #expect(feature.summary(in: details(facts)) == feature.summary)
        }
    }

    @Test func everyBenefitWithEnoughBehindItSpeaksOfTheViewer() {
        let facts = ProViewerFacts(history: history(), downloadedTitles: 6, titlesInProgress: 4)
        let lines = details(facts)
        #expect(lines[.unlimitedDownloads] == "6 titles are on this iPhone. Download whole seasons, queue as many as you like and keep the next episodes ready.")
        #expect(lines[.fullStatistics] == "Every range, the library filter, patterns, binges and taste across your 840 plays since 2019.")
        #expect(lines[.yearInReviewPoster] == "Your 2026 so far: 14 movies · 212 episodes. Preview and share it as a Story or Square poster.")
        #expect(lines[.topShelf] == "4 titles in progress on this Apple TV. Top Shelf puts Continue Watching and Up Next on the Home screen.")
        #expect(lines[.manageRequests] == nil)
        #expect(headline(facts) == "180 hours watched in 2026 so far")
    }

    @Test func downloadsSpeakFromTheSecondTitle() {
        #expect(details(ProViewerFacts(downloadedTitles: ProPersonalDetails.downloadedTitles - 1))[.unlimitedDownloads] == nil)
        #expect(details(ProViewerFacts(downloadedTitles: ProPersonalDetails.downloadedTitles))[.unlimitedDownloads]?.hasPrefix("2 titles") == true)
    }

    @Test func topShelfSpeaksFromTheSecondTitleInProgress() {
        #expect(details(ProViewerFacts(titlesInProgress: ProPersonalDetails.titlesInProgress - 1))[.topShelf] == nil)
        #expect(details(ProViewerFacts(titlesInProgress: ProPersonalDetails.titlesInProgress))[.topShelf]?.hasPrefix("2 titles") == true)
    }

    @Test func statisticsNeedTheWholeHistoryAndEnoughOfIt() {
        let thin = ProViewerFacts(history: history(allTime: ProPersonalDetails.historyPlays - 1))
        #expect(details(thin)[.fullStatistics] == nil)
        let enough = ProViewerFacts(history: history(allTime: ProPersonalDetails.historyPlays))
        #expect(details(enough)[.fullStatistics]?.contains("your 50 plays since 2019") == true)
        let stillMirroring = ProViewerFacts(history: history(allTime: nil, firstYear: nil))
        #expect(details(stillMirroring)[.fullStatistics] == nil)
        let noFirstYear = ProViewerFacts(history: history(allTime: 900, firstYear: nil))
        #expect(details(noFirstYear)[.fullStatistics] == nil)
    }

    @Test func statisticsNeedAHistoryThatBeganBeforeThisYear() {
        let beganThisYear = ProViewerFacts(history: history(allTime: 600, firstYear: 2026))
        #expect(details(beganThisYear)[.fullStatistics] == nil)
        let beganLastYear = ProViewerFacts(history: history(allTime: 600, firstYear: 2025))
        #expect(details(beganLastYear)[.fullStatistics]?.hasSuffix("across your 600 plays since 2025.") == true)
    }

    @Test func thePosterNeedsEnoughOfThisYear() {
        let thin = ProViewerFacts(history: history(plays: ProPersonalDetails.yearPlays - 1, movies: 2, episodes: 7))
        #expect(details(thin)[.yearInReviewPoster] == nil)
        let enough = ProViewerFacts(history: history(plays: ProPersonalDetails.yearPlays, movies: 1, episodes: 9))
        #expect(details(enough)[.yearInReviewPoster] == "Your 2026 so far: 1 movie · 9 episodes. Preview and share it as a Story or Square poster.")
    }

    @Test func thePosterNamesOnlyWhatWasWatched() {
        let moviesOnly = ProViewerFacts(history: history(plays: 12, movies: 12, episodes: 0))
        #expect(details(moviesOnly)[.yearInReviewPoster]?.hasPrefix("Your 2026 so far: 12 movies.") == true)
        let oneEpisode = ProViewerFacts(history: history(plays: 12, movies: 0, episodes: 1))
        #expect(details(oneEpisode)[.yearInReviewPoster]?.hasPrefix("Your 2026 so far: 1 episode.") == true)
        let neither = ProViewerFacts(history: history(plays: 12, movies: 0, episodes: 0))
        #expect(details(neither)[.yearInReviewPoster] == nil)
    }

    @Test func aHistoryReadLastYearSaysNothingAboutThisYear() {
        let stale = ProViewerFacts(history: history(year: 2025))
        #expect(details(stale)[.yearInReviewPoster] == nil)
        #expect(headline(stale) == nil)
        #expect(details(stale)[.fullStatistics] != nil)
    }

    @Test func theHeadlineNeedsKnownHoursAndEnoughOfThem() {
        #expect(headline(ProViewerFacts(history: history(hours: nil))) == nil)
        #expect(headline(ProViewerFacts(history: history(hours: ProPersonalDetails.yearHours - 1))) == nil)
        #expect(headline(ProViewerFacts(history: history(hours: ProPersonalDetails.yearHours))) == "10 hours watched in 2026 so far")
    }

    @Test func noLineNamesMoreThanCounts() {
        let facts = ProViewerFacts(history: history(), downloadedTitles: 6, titlesInProgress: 4)
        #expect(Set(details(facts).keys) == [.unlimitedDownloads, .fullStatistics, .yearInReviewPoster, .topShelf])
    }

    @Test func theAppleTVReasonFallsBackToTheViewersYearOnlyWhenNothingElseExplainsTheScreen() {
        let facts = ProViewerFacts(history: history())
        let plain = ProTVPresentation.reasonLine(for: PaywallRequest(), proWeekEndsAt: nil, facts: facts, now: now, calendar: Self.utc)
        #expect(plain == "180 hours watched in 2026 so far")
        let reached = ProTVPresentation.reasonLine(for: PaywallRequest(feature: .topShelf), proWeekEndsAt: nil, facts: facts, now: now, calendar: Self.utc)
        #expect(reached == "Top Shelf is part of Crucible Pro.")
        let afterWeek = ProTVPresentation.reasonLine(for: PaywallRequest(followsProWeek: true), proWeekEndsAt: nil, facts: facts, now: now, calendar: Self.utc)
        #expect(afterWeek == "Your Pro week has ended.")
        #expect(ProTVPresentation.reasonLine(for: PaywallRequest(), proWeekEndsAt: nil) == nil)
    }

    @Test func theDebugSwitchStagesAViewerOrNoneAndIsOffWithoutIt() throws {
        #expect(ProViewerFacts.staged([:]) == nil)
        #expect(ProViewerFacts.staged(["CRUCIBLE_PRO_FACTS": "live"]) == nil)
        #expect(ProViewerFacts.staged(["CRUCIBLE_PRO_FACTS": "none"]) == ProViewerFacts())
        let staged = try #require(ProViewerFacts.staged(["CRUCIBLE_PRO_FACTS": "staged"], now: now, calendar: Self.utc))
        #expect(staged.history?.year == 2026)
        #expect(Set(details(staged).keys) == [.unlimitedDownloads, .fullStatistics, .yearInReviewPoster, .topShelf])
        #expect(headline(staged) == "187 hours watched in 2026 so far")
    }
}

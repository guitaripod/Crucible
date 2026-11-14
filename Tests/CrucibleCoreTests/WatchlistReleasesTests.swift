import Foundation
import Testing
@testable import CrucibleCore

struct WatchlistReleaseCheckTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Helsinki")!
        return calendar
    }

    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 20))! }

    private func day(_ offset: Int) -> String {
        let date = calendar.date(byAdding: .day, value: -offset, to: now)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private func show(_ key: String, title: String? = nil) -> PlexMetadata {
        DetailFixtures.item(["ratingKey": key, "type": "show", "title": title ?? key.capitalized, "guid": "plex://show/\(key)", "thumb": "https://art/\(key).jpg", "year": 2020])
    }

    private func season(_ show: String, _ index: Int, premiered daysAgo: Int? = nil) -> PlexMetadata {
        var fields: [String: Any] = ["ratingKey": "\(show)-s\(index)", "type": "season", "title": "Season \(index)", "index": index]
        if let daysAgo { fields["originallyAvailableAt"] = day(daysAgo) }
        return DetailFixtures.item(fields)
    }

    private func episode(_ index: Int, aired daysAgo: Int?) -> PlexMetadata {
        var fields: [String: Any] = ["ratingKey": "e\(index)", "type": "episode", "title": "Episode \(index)", "index": index]
        if let daysAgo { fields["originallyAvailableAt"] = day(daysAgo) }
        return DetailFixtures.item(fields)
    }

    private func check(_ children: [String: [PlexMetadata]], onServer: Set<String> = [], failing: Set<String> = []) -> WatchlistReleaseCheck {
        WatchlistReleaseCheck(
            fetchChildren: { key in
                if failing.contains(key) { throw APIError.timedOut }
                return children[key] ?? []
            },
            isOnServer: { onServer.contains($0.guid ?? "") }
        )
    }

    @Test func aSeasonThatPremieredInTheLastTwoWeeksIsNews() async throws {
        let found = await check([
            "orchard": [season("orchard", 1), season("orchard", 2)],
            "orchard-s2": [episode(1, aired: 4), episode(2, aired: 4), episode(3, aired: -3)],
        ]).run(watchlist: [show("orchard")], now: now, calendar: calendar)
        #expect(found.count == 1)
        let release = try #require(found.first)
        #expect(release.season == 2)
        #expect(release.episode == 2)
        #expect(release.episodeCount == 2)
        #expect(release.premiered)
        #expect(release.news == .newSeason)
        #expect(release.airDate == day(4))
        #expect(release.posterPath == "https://art/orchard.jpg")
        #expect(release.asMetadata.guid == "plex://show/orchard")
        #expect(release.asMetadata.mediaType == "show")
    }

    @Test func anEpisodeMidSeasonIsANewEpisodeAndTheNewestOneLeads() async throws {
        let found = await check([
            "signal": [season("signal", 1), season("signal", 3), season("signal", 2)],
            "signal-s3": [episode(1, aired: 30), episode(2, aired: 23), episode(3, aired: 16), episode(4, aired: 9), episode(5, aired: 2), episode(6, aired: -5)],
        ]).run(watchlist: [show("signal")], now: now, calendar: calendar)
        let release = try #require(found.first)
        #expect(release.season == 3)
        #expect(release.episode == 5)
        #expect(release.episodeCount == 2)
        #expect(!release.premiered)
        #expect(release.news == .newEpisode)
    }

    @Test func aSeasonAnnouncedButNotAiredFallsBackToTheOneBefore() async {
        let found = await check([
            "choir": [season("choir", 1), season("choir", 2)],
            "choir-s2": [episode(1, aired: -20), episode(2, aired: nil)],
            "choir-s1": [episode(9, aired: 8), episode(10, aired: 1)],
        ]).run(watchlist: [show("choir")], now: now, calendar: calendar)
        #expect(found.map(\.season) == [1])
        #expect(found.first?.episode == 10)
    }

    @Test func seasonsDatedLongAgoOrStillToComeAreNotOpened() async {
        let opened = OpenedKeys()
        let children: [String: [PlexMetadata]] = [
            "ended": [season("ended", 1, premiered: 900), season("ended", 2, premiered: 500)],
            "returning": [season("returning", 4, premiered: -30), season("returning", 3, premiered: 60)],
            "returning-s3": [episode(9, aired: 3)],
            "returning-s4": [episode(1, aired: -30)],
        ]
        let check = WatchlistReleaseCheck(
            fetchChildren: { key in
                await opened.add(key)
                return children[key] ?? []
            },
            isOnServer: { _ in false }
        )
        let found = await check.run(watchlist: [show("ended"), show("returning")], now: now, calendar: calendar)
        #expect(found.map(\.discoverKey) == ["returning"])
        #expect(found.first?.season == 3)
        let keys = await opened.keys
        #expect(keys.count == 3)
        #expect(Set(keys) == ["ended", "returning", "returning-s3"])
    }

    @Test func aLookStopsAtTheNewestHundredShows() async {
        var children = [String: [PlexMetadata]]()
        let keys = (0..<(WatchlistReleaseCheck.maxShows + 5)).map { "show\($0)" }
        for key in keys {
            children[key] = [season(key, 1)]
            children["\(key)-s1"] = [episode(2, aired: 1)]
        }
        let found = await check(children).run(watchlist: keys.map { show($0) }, now: now, calendar: calendar)
        #expect(found.count == WatchlistReleaseCheck.maxShows)
        #expect(!found.contains { $0.discoverKey == keys.last })
    }

    @Test func oldSeasonsSpecialsMoviesAndShowsTheServerHasAreLeftOut() async {
        let found = await check([
            "old": [season("old", 1)],
            "old-s1": [episode(1, aired: 14), episode(2, aired: 40)],
            "specials": [season("specials", 0), season("specials", 1)],
            "specials-s0": [episode(1, aired: 1)],
            "specials-s1": [episode(1, aired: 300)],
            "owned": [season("owned", 1)],
            "owned-s1": [episode(1, aired: 1)],
        ], onServer: ["plex://show/owned"]).run(
            watchlist: [show("old"), show("specials"), show("owned"), DetailFixtures.item(["ratingKey": "m", "type": "movie", "title": "Film", "guid": "plex://movie/m"])],
            now: now, calendar: calendar
        )
        #expect(found.isEmpty)
    }

    @Test func aShowTheCatalogueCannotAnswerForIsSkippedAndTheRestStillCount() async {
        let found = await check([
            "fine": [season("fine", 1)],
            "fine-s1": [episode(1, aired: 0)],
        ], failing: ["broken"]).run(watchlist: [show("broken"), show("fine")], now: now, calendar: calendar)
        #expect(found.map(\.guid) == ["plex://show/fine"])
    }

    @Test func releasesComeNewestFirstThenInWatchlistOrder() async {
        let shows = ["a", "b", "c", "d", "e"]
        let aired = ["a": 6, "b": 1, "c": 6, "d": 0, "e": 13]
        var children = [String: [PlexMetadata]]()
        for key in shows {
            children[key] = [season(key, 1)]
            children["\(key)-s1"] = [episode(3, aired: aired[key])]
        }
        let found = await check(children).run(watchlist: shows.map { show($0) } + [show("a")], now: now, calendar: calendar)
        #expect(found.map(\.discoverKey) == ["d", "b", "a", "c", "e"])
    }

    @Test func airDatesAreGregorianDaysWhateverCalendarTheDeviceShows() {
        for identifier in [Calendar.Identifier.buddhist, .japanese, .islamicUmmAlQura, .hebrew] {
            var other = Calendar(identifier: identifier)
            other.timeZone = calendar.timeZone
            #expect(AirDate.daysAgo(day(3), now: now, calendar: other) == 3, "\(identifier)")
        }
        #expect(AirDate.isRecent(day(13), now: now, calendar: calendar))
        #expect(!AirDate.isRecent(day(14), now: now, calendar: calendar))
        #expect(!AirDate.isRecent("someday", now: now, calendar: calendar))
    }

    @Test func aFailedShowIsReportedAsUnanswered() async {
        let outcome = await check(["fine": [season("fine", 1)], "fine-s1": [episode(1, aired: 0)]], failing: ["broken"])
            .look(watchlist: [show("broken"), show("fine")], now: now, calendar: calendar)
        #expect(outcome.releases.map(\.discoverKey) == ["fine"])
        #expect(outcome.unknown == ["plex://show/broken"])
    }

    @Test func airDatesAreWholeDaysOnTheViewersCalendar() {
        #expect(AirDate.daysAgo(day(0), now: now, calendar: calendar) == 0)
        #expect(AirDate.daysAgo(day(13), now: now, calendar: calendar) == 13)
        #expect(AirDate.daysAgo(day(-2), now: now, calendar: calendar) == -2)
        #expect(AirDate.daysAgo("2026-11-15T00:00:00Z", now: now, calendar: calendar) == 0)
        #expect(AirDate.daysAgo("soon", now: now, calendar: calendar) == nil)
    }

    @Test func theCaptionNamesTheSeasonForAPremiereAndTheEpisodeOtherwise() {
        let premiere = WatchlistRelease(guid: "plex://show/x", discoverKey: "x", title: "X", year: nil, posterPath: nil, season: 3, episode: 2, episodeCount: 2, premiered: true, airDate: day(1))
        let episode = WatchlistRelease(guid: "plex://show/y", discoverKey: "y", title: "Y", year: nil, posterPath: nil, season: 2, episode: 5, episodeCount: 1, premiered: false, airDate: day(0))
        #expect(premiere.caption(now: now, calendar: calendar).hasPrefix("Season 3 · "))
        #expect(episode.caption(now: now, calendar: calendar).hasPrefix("S2 · E5 · "))
        #expect(premiere.caption(now: now, calendar: calendar) != episode.caption(now: now, calendar: calendar))
    }

    @Test func aWatchlistCardShowsTheReleaseUntilSeerrHasARequestUnderWay() {
        let release = WatchlistRelease(guid: "plex://show/x", discoverKey: "x", title: "X", year: nil, posterPath: nil, season: 3, episode: 1, episodeCount: 1, premiered: true, airDate: day(1))
        let caption = release.caption(now: now)
        #expect(WatchlistReleaseCopy.cardSubtitle(release: release, seerr: nil, seerrLabel: nil, fallback: "2020", now: now) == caption)
        #expect(WatchlistReleaseCopy.cardSubtitle(release: release, seerr: .notRequested, seerrLabel: "Not on your server", fallback: "2020", now: now) == caption)
        #expect(WatchlistReleaseCopy.cardSubtitle(release: release, seerr: .pending, seerrLabel: "Awaiting approval", fallback: "2020", now: now) == "Awaiting approval")
        #expect(WatchlistReleaseCopy.cardSubtitle(release: nil, seerr: nil, seerrLabel: nil, fallback: "2020", now: now) == "2020")
    }

    @Test func catalogueChildrenAreAskedForInPagesOfHeaders() throws {
        let request = try PlexEndpoint.catalogChildren(key: "5d9c").urlRequest(baseURL: URL(string: "http://pms:32400")!, token: "t")
        #expect(request.url?.path == "/library/metadata/5d9c/children")
        #expect(request.url?.host != "pms")
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "X-Plex-Container-Start") == "0")
        #expect(request.value(forHTTPHeaderField: "X-Plex-Container-Size") == "300")
        let next = try PlexEndpoint.catalogChildren(key: "5d9c", start: 300).urlRequest(baseURL: URL(string: "http://pms:32400")!, token: "t")
        #expect(next.value(forHTTPHeaderField: "X-Plex-Container-Start") == "300")
    }
}

@MainActor
struct WatchlistReleasesStoreTests {
    private func defaults() -> UserDefaults {
        let name = "watchlist-releases-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func check(airedDaysAgo: Int = 1, calls: ReleaseCallCounter? = nil) -> WatchlistReleaseCheck {
        WatchlistReleaseCheck(
            fetchChildren: { key in
                await calls?.increment()
                if key == "orchard" { return [DetailFixtures.item(["ratingKey": "orchard-s1", "type": "season", "title": "Season 1", "index": 1])] }
                var calendar = Calendar.current
                calendar.timeZone = .current
                let date = calendar.date(byAdding: .day, value: -airedDaysAgo, to: Date(timeIntervalSince1970: 1_800_000_000))!
                let parts = calendar.dateComponents([.year, .month, .day], from: date)
                return [DetailFixtures.item([
                    "ratingKey": "e1", "type": "episode", "title": "Pilot", "index": 1,
                    "originallyAvailableAt": String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!),
                ])]
            },
            isOnServer: { _ in false }
        )
    }

    private let watchlist = [DetailFixtures.item(["ratingKey": "orchard", "type": "show", "title": "Orchard", "guid": "plex://show/orchard"])]

    @Test func aLookIsKeptForItsOwnerAndAcrossLaunches() async {
        let store = defaults()
        let releases = WatchlistReleases(defaults: store, center: NotificationCenter(), owner: { "server|account" })
        await releases.refresh(owner: "server|account", check: check(), loadWatchlist: { [watchlist] in watchlist }, force: false, now: now)
        #expect(releases.releases(for: "server|account", now: now).map(\.title) == ["Orchard"])
        #expect(releases.releases(for: "server|kid", now: now).isEmpty)
        #expect(releases.release(guid: "plex://show/orchard", owner: "server|account", now: now)?.premiered == true)
        let relaunched = WatchlistReleases(defaults: store, center: NotificationCenter(), owner: { "server|account" })
        #expect(relaunched.releases(for: "server|account", now: now).count == 1)
    }

    @Test func aFreshLookIsReusedUntilForcedOrStale() async {
        let releases = WatchlistReleases(defaults: defaults(), center: NotificationCenter(), owner: { "o" })
        let calls = ReleaseCallCounter()
        let list = watchlist
        await releases.refresh(owner: "o", check: check(calls: calls), loadWatchlist: { list }, force: false, now: now)
        await releases.refresh(owner: "o", check: check(calls: calls), loadWatchlist: { list }, force: false, now: now.addingTimeInterval(3_600))
        #expect(await calls.value == 2)
        await releases.refresh(owner: "o", check: check(calls: calls), loadWatchlist: { list }, force: true, now: now.addingTimeInterval(3_600))
        #expect(await calls.value == 4)
        await releases.refresh(owner: "o", check: check(calls: calls), loadWatchlist: { list }, force: false, now: now.addingTimeInterval(WatchlistReleases.freshness + 3_601))
        #expect(await calls.value == 6)
    }

    @Test func observersHearChangesAndAFailedWatchlistKeepsWhatWasFound() async {
        let releases = WatchlistReleases(defaults: defaults(), center: NotificationCenter(), owner: { "o" })
        let heard = HeardCount()
        releases.addObserver { heard.value += 1 }
        let list = watchlist
        await releases.refresh(owner: "o", check: check(), loadWatchlist: { list }, force: false, now: now)
        #expect(heard.value == 1)
        await releases.refresh(owner: "o", check: check(), loadWatchlist: { throw APIError.timedOut }, force: true, now: now)
        #expect(releases.releases(for: "o", now: now).count == 1)
        #expect(heard.value == 1)
        await releases.refresh(owner: "o", check: check(airedDaysAgo: 30), loadWatchlist: { list }, force: true, now: now)
        #expect(releases.releases(for: "o", now: now).isEmpty)
        #expect(heard.value == 2)
        releases.reset()
        #expect(heard.value == 3)
    }

    @Test func aShowThatReachesTheServerLeavesAtOnce() async {
        let releases = WatchlistReleases(defaults: defaults(), center: NotificationCenter(), owner: { "o" })
        let list = watchlist
        await releases.refresh(owner: "o", check: check(), loadWatchlist: { list }, force: false, now: now)
        releases.noteOnServer([DetailFixtures.item(["ratingKey": "9", "type": "episode", "title": "Pilot", "grandparentGuid": "plex://show/other"])], owner: "o")
        #expect(releases.releases(for: "o", now: now).count == 1)
        releases.noteOnServer([DetailFixtures.item(["ratingKey": "10", "type": "episode", "title": "Pilot", "grandparentGuid": "plex://show/orchard"])], owner: "o")
        #expect(releases.releases(for: "o", now: now).isEmpty)
    }

    @Test func aReleaseOlderThanTwoWeeksIsDroppedWhenReadEvenWithoutANewLook() async {
        let releases = WatchlistReleases(defaults: defaults(), center: NotificationCenter(), owner: { "o" })
        let list = watchlist
        await releases.refresh(owner: "o", check: check(airedDaysAgo: 10), loadWatchlist: { list }, force: false, now: now)
        #expect(releases.releases(for: "o", now: now).count == 1)
        #expect(releases.releases(for: "o", now: now.addingTimeInterval(5 * 86_400)).isEmpty)
    }

    @Test func aShowTheCatalogueCannotAnswerForKeepsItsEarlierRelease() async {
        let releases = WatchlistReleases(defaults: defaults(), center: NotificationCenter(), owner: { "o" })
        let list = watchlist
        await releases.refresh(owner: "o", check: check(), loadWatchlist: { list }, force: false, now: now)
        let failing = WatchlistReleaseCheck(fetchChildren: { _ in throw APIError.timedOut }, isOnServer: { _ in false })
        await releases.refresh(owner: "o", check: failing, loadWatchlist: { list }, force: true, now: now)
        #expect(releases.releases(for: "o", now: now).map(\.title) == ["Orchard"])
    }

    @Test func aShowTakenOffTheWatchlistWhileALookRunsStaysOff() async {
        let center = NotificationCenter()
        let releases = WatchlistReleases(defaults: defaults(), center: center, owner: { "o" })
        let calls = ReleaseCallCounter()
        let list = watchlist
        await releases.refresh(owner: "o", check: check(calls: calls), loadWatchlist: {
            await MainActor.run {
                center.post(name: .watchlistChanged, object: nil, userInfo: [WatchlistService.changedGuidKey: "plex://show/orchard", WatchlistService.changedAddedKey: false])
            }
            return list
        }, force: false, now: now)
        #expect(releases.releases(for: "o", now: now).isEmpty)
        await releases.refresh(owner: "o", check: check(calls: calls), loadWatchlist: { list }, force: false, now: now)
        #expect(await calls.value == 4, "a change during the look leaves it stale")
    }

    @Test func anotherProfilesChangeLeavesTheseReleasesAlone() async {
        let center = NotificationCenter()
        let releases = WatchlistReleases(defaults: defaults(), center: center, owner: { "o|kid" })
        let list = watchlist
        await releases.refresh(owner: "o|account", check: check(), loadWatchlist: { list }, force: false, now: now)
        center.post(name: .watchlistChanged, object: nil, userInfo: [WatchlistService.changedGuidKey: "plex://show/orchard", WatchlistService.changedAddedKey: false])
        #expect(releases.releases(for: "o|account", now: now).count == 1)
    }

    @Test func takingAShowOffTheWatchlistDropsItsReleaseAtOnceAndMakesTheLookStale() async {
        let center = NotificationCenter()
        let releases = WatchlistReleases(defaults: defaults(), center: center, owner: { "o" })
        let calls = ReleaseCallCounter()
        let list = watchlist
        await releases.refresh(owner: "o", check: check(calls: calls), loadWatchlist: { list }, force: false, now: now)
        center.post(name: .watchlistChanged, object: nil, userInfo: [WatchlistService.changedGuidKey: "plex://show/orchard", WatchlistService.changedAddedKey: false])
        #expect(releases.releases(for: "o", now: now).isEmpty)
        await releases.refresh(owner: "o", check: check(calls: calls), loadWatchlist: { list }, force: false, now: now)
        #expect(await calls.value == 4)
    }
}

actor OpenedKeys {
    private(set) var keys: [String] = []

    func add(_ key: String) {
        keys.append(key)
    }
}

@MainActor
final class HeardCount {
    var value = 0
}

actor ReleaseCallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

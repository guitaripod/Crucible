import Foundation
import Testing
@testable import CrucibleCore

struct HomeRichCardTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let day = 86_400

    private func episode(season: Int = 2, index: Int = 5, offset: Int? = nil, viewCount: Int? = nil, addedDaysAgo: Int? = nil, aired: String? = nil) -> PlexMetadata {
        let parts = [
            offset.map { #""viewOffset": \#($0)"# },
            viewCount.map { #""viewCount": \#($0)"# },
            addedDaysAgo.map { #""addedAt": \#(1_700_000_000 - $0 * day)"# },
            aired.map { #""originallyAvailableAt": "\#($0)""# },
        ].compactMap { $0 }
        let extra = parts.isEmpty ? "" : ", " + parts.joined(separator: ", ")
        return AuthFixtures.metadata("""
        {"ratingKey": "7", "type": "episode", "title": "Gulls", "grandparentTitle": "The Show", "parentIndex": \(season), "index": \(index), "duration": 2700000\(extra)}
        """)
    }

    @Test func anEpisodeThatJustArrivedAndJustAiredIsNew() {
        #expect(HomeFormat.episodeNews(episode(addedDaysAgo: 2, aired: "2023-11-12"), now: now) == .newEpisode)
        #expect(HomeFormat.episodeNews(episode(addedDaysAgo: 2), now: now) == .newEpisode)
    }

    @Test func aBackCatalogueAddedTodayOrAnOldArrivalIsNotNews() {
        #expect(HomeFormat.episodeNews(episode(addedDaysAgo: 1, aired: "2019-04-02"), now: now) == nil)
        #expect(HomeFormat.episodeNews(episode(addedDaysAgo: 9, aired: "2023-11-10"), now: now) == nil)
        #expect(HomeFormat.episodeNews(episode(), now: now) == nil)
    }

    @Test func onlyAJustArrivedSeasonOpenerIsANewSeason() {
        #expect(HomeFormat.episodeNews(episode(season: 3, index: 1), now: now) == nil)
        #expect(HomeFormat.episodeNews(episode(season: 3, index: 1, addedDaysAgo: 1, aired: "2023-11-13"), now: now) == .newSeason)
        #expect(HomeFormat.episodeNews(episode(season: 1, index: 1), now: now) == nil)
    }

    @Test func somethingStartedOrWatchedIsNeverNews() {
        #expect(HomeFormat.episodeNews(episode(offset: 60_000, addedDaysAgo: 1), now: now) == nil)
        #expect(HomeFormat.episodeNews(episode(viewCount: 1, addedDaysAgo: 1), now: now) == nil)
    }

    @Test func endsAtCountsFromNowWithWhatIsLeft() throws {
        let resumed = try #require(HomeFormat.endsAt(episode(offset: 600_000), position: 600, now: now))
        let expected = now.addingTimeInterval(2100).formatted(date: .omitted, time: .shortened)
        #expect(resumed == "Ends at \(expected)")
        let fresh = try #require(HomeFormat.endsAt(episode(), now: now))
        #expect(fresh == "Ends at \(now.addingTimeInterval(2700).formatted(date: .omitted, time: .shortened))")
        let atTheEnd = AuthFixtures.metadata(#"{"ratingKey": "2", "type": "movie", "title": "M", "duration": 7200000, "viewOffset": 7200000}"#)
        #expect(HomeFormat.endsAt(atTheEnd, now: now) == nil)
        let show = AuthFixtures.metadata(#"{"ratingKey": "1", "type": "show", "title": "S", "duration": 100}"#)
        #expect(HomeFormat.endsAt(show, now: now) == nil)
    }

    @Test func anUpNextCardNamesTheEpisodeAndBadgesNews() {
        let card = HomeCardModel(item: episode(addedDaysAgo: 1), bucket: .upNext, layout: .landscape, now: now)
        #expect(card.subtitle == "S2 · E5 · Gulls")
        #expect(card.trailingText == "45 min")
        #expect(card.news == .newEpisode)
        #expect(card.news?.badge == "New")

        let poster = HomeCardModel(item: episode(season: 4, index: 1, addedDaysAgo: 2), bucket: .upNext, layout: .poster, now: now)
        #expect(poster.subtitle == "S4 · E1 · 45 min")
        #expect(poster.news?.badge == "New Season")
        #expect(HomeCardModel(item: episode(season: 4, index: 1), bucket: .upNext, layout: .poster, now: now).news == nil)

        #expect(HomeCardModel(item: episode(addedDaysAgo: 1), bucket: .recentlyAdded, layout: .poster, now: now).news == nil)
    }

    @Test func theHeroSaysWhyAndWhenItEnds() {
        let item = episode(season: 3, index: 1, addedDaysAgo: 1, aired: "2023-11-13")
        let hero = HomeHeroModel(item: item, eyebrow: "Up Next", now: now)
        #expect(hero.eyebrow == "New Season")
        #expect(hero.metaParts.last == "Ends at \(now.addingTimeInterval(2700).formatted(date: .omitted, time: .shortened))")

        let continuing = HomeHeroModel(item: episode(offset: 600_000), eyebrow: "Continue Watching", continuing: true, now: now)
        #expect(continuing.eyebrow == "Continue Watching")
        #expect(continuing.metaParts.contains("35 min left"))
    }

    @Test func aFourKFileEarnsAChipBesideTheRating() {
        let wide = AuthFixtures.metadata(#"{"ratingKey": "1", "type": "movie", "title": "M", "contentRating": "PG-13", "Media": [{"width": 3840, "height": 1600}]}"#)
        #expect(HomeHeroModel(item: wide, eyebrow: "Up Next", now: now).badges == ["4K", "PG-13"])
        let plain = AuthFixtures.metadata(#"{"ratingKey": "2", "type": "movie", "title": "M", "contentRating": "PG-13", "Media": [{"width": 1920, "height": 1080}]}"#)
        #expect(HomeHeroModel(item: plain, eyebrow: "Up Next", now: now).badges == ["PG-13"])
    }
}

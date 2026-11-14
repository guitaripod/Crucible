import Foundation
import Testing
@testable import CrucibleCore

enum GapFixtures {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Helsinki")!
        return calendar
    }

    static var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 20))! }

    static func day(_ offset: Int) -> String {
        let date = calendar.date(byAdding: .day, value: -offset, to: now)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func show(_ key: String = "show", guid: String? = "plex://show/cat") -> PlexMetadata {
        var fields: [String: Any] = ["ratingKey": key, "type": "show", "title": "Salt Road"]
        if let guid { fields["guid"] = guid }
        return DetailFixtures.item(fields)
    }

    static func catalogueSeason(_ index: Int, episodes: Int? = nil, premiered daysAgo: Int? = nil) -> PlexMetadata {
        var fields: [String: Any] = ["ratingKey": "cs\(index)", "type": "season", "title": "Season \(index)", "index": index]
        if let episodes { fields["leafCount"] = episodes }
        if let daysAgo { fields["originallyAvailableAt"] = day(daysAgo) }
        return DetailFixtures.item(fields)
    }

    static func catalogueEpisode(_ season: Int, _ number: Int, aired daysAgo: Int?) -> PlexMetadata {
        var fields: [String: Any] = ["ratingKey": "ce\(season)-\(number)", "type": "episode", "title": "Chapter \(number)", "index": number, "parentIndex": season]
        if let daysAgo { fields["originallyAvailableAt"] = day(daysAgo) }
        return DetailFixtures.item(fields)
    }

    static func serverEpisode(_ season: Int, _ number: Int, watched: Bool = false, show: String = "show") -> PlexMetadata {
        var fields: [String: Any] = [
            "ratingKey": "e\(season)-\(number)", "type": "episode", "title": "Episode \(number)", "index": number, "parentIndex": season,
            "parentRatingKey": "s\(season)", "grandparentRatingKey": show, "grandparentTitle": "Salt Road", "grandparentGuid": "plex://show/cat",
            "grandparentThumb": "/library/metadata/\(show)/thumb/1", "grandparentArt": "/library/metadata/\(show)/art/1",
        ]
        if watched { fields["viewCount"] = 1 }
        return DetailFixtures.item(fields)
    }

    static func check(_ children: [String: [PlexMetadata]], opened: OpenedCatalogueKeys? = nil, failing: Set<String> = []) -> ShowGapsCheck {
        ShowGapsCheck(fetchChildren: { key in
            await opened?.add(key)
            if failing.contains(key) { throw APIError.timedOut }
            return children[key] ?? []
        })
    }
}

actor OpenedCatalogueKeys {
    private(set) var keys: [String] = []

    func add(_ key: String) {
        keys.append(key)
    }
}

struct ShowGapsCheckTests {
    typealias F = GapFixtures

    @Test func aWholeSeasonAndAnEpisodeInsideASeasonAreFoundAndCompleteSeasonsAreNotOpened() async throws {
        let opened = OpenedCatalogueKeys()
        let check = F.check([
            "cat": [F.catalogueSeason(1, episodes: 3), F.catalogueSeason(2, episodes: 4), F.catalogueSeason(3, episodes: 6, premiered: 5), F.catalogueSeason(4, premiered: -40)],
            "cs2": [F.catalogueEpisode(2, 1, aired: 400), F.catalogueEpisode(2, 2, aired: 393), F.catalogueEpisode(2, 3, aired: 386), F.catalogueEpisode(2, 4, aired: 379)],
        ], opened: opened)
        let server = [F.serverEpisode(1, 1), F.serverEpisode(1, 2), F.serverEpisode(1, 3), F.serverEpisode(2, 1), F.serverEpisode(2, 2), F.serverEpisode(2, 4)]
        let gaps = try await check.run(show: F.show(), serverEpisodes: server, now: F.now, calendar: F.calendar)
        #expect(gaps.seasons.map(\.index) == [3])
        #expect(gaps.seasons.first?.catalogueKey == "cs3")
        #expect(gaps.missing(inSeason: 2).map(\.episode) == [3])
        #expect(gaps.missing(inSeason: 2).first?.title == "Chapter 3")
        #expect(gaps.missing(inSeason: 3).isEmpty, "a missing season's episodes wait until it is opened")
        #expect(await opened.keys == ["cat", "cs2"])
    }

    @Test func unairedEpisodesAndSeasonsAndSpecialsAreNotGaps() async throws {
        let check = F.check([
            "cat": [F.catalogueSeason(0, episodes: 9), F.catalogueSeason(1, episodes: 4), F.catalogueSeason(2)],
            "cs1": [F.catalogueEpisode(1, 1, aired: 20), F.catalogueEpisode(1, 2, aired: 13), F.catalogueEpisode(1, 3, aired: -1), F.catalogueEpisode(1, 4, aired: nil)],
            "cs2": [F.catalogueEpisode(2, 1, aired: -60)],
        ])
        let gaps = try await check.run(show: F.show(), serverEpisodes: [F.serverEpisode(1, 1), F.serverEpisode(1, 2)], now: F.now, calendar: F.calendar)
        #expect(gaps.isEmpty)
    }

    @Test func theNewestSeasonWithoutADateIsListedOnlyWhenItHasAiredSomething() async throws {
        let check = F.check([
            "cat": [F.catalogueSeason(1, episodes: 1), F.catalogueSeason(2)],
            "cs2": [F.catalogueEpisode(2, 1, aired: 2), F.catalogueEpisode(2, 2, aired: -5)],
        ])
        let gaps = try await check.run(show: F.show(), serverEpisodes: [F.serverEpisode(1, 1)], now: F.now, calendar: F.calendar)
        #expect(gaps.seasons.map(\.index) == [2])
        #expect(gaps.missing(inSeason: 2).map(\.episode) == [1])
    }

    @Test func aSeasonNumberedDifferentlyOnTheServerIsLeftAlone() async throws {
        let check = F.check([
            "cat": [F.catalogueSeason(1, episodes: 3)],
            "cs1": [F.catalogueEpisode(1, 1, aired: 30), F.catalogueEpisode(1, 2, aired: 20), F.catalogueEpisode(1, 3, aired: 10)],
        ])
        let server = [F.serverEpisode(1, 1), F.serverEpisode(1, 57)]
        let gaps = try await check.run(show: F.show(), serverEpisodes: server, now: F.now, calendar: F.calendar)
        #expect(gaps.isEmpty)
    }

    @Test func aShowWithoutAPlexGuidHasNoCatalogueToCompare() async throws {
        let opened = OpenedCatalogueKeys()
        let gaps = try await F.check([:], opened: opened).run(show: F.show(guid: "com.plexapp.agents.thetvdb://1"), serverEpisodes: [], now: F.now, calendar: F.calendar)
        #expect(gaps.isEmpty)
        #expect(await opened.keys.isEmpty)
    }

    @Test func openingAMissingSeasonListsWhatHasAired() async throws {
        let check = F.check(["cs3": [F.catalogueEpisode(3, 1, aired: 5), F.catalogueEpisode(3, 2, aired: 0), F.catalogueEpisode(3, 3, aired: -7)]])
        let season = MissingSeason(index: 3, title: "Season 3", catalogueKey: "cs3")
        #expect(try await check.episodes(of: season, now: F.now, calendar: F.calendar).map(\.episode) == [1, 2])
    }

    @MainActor
    @Test func theCenterKeepsAnAnswerUntilTheServerChangesAndFillsAMissingSeasonOnce() async throws {
        let opened = OpenedCatalogueKeys()
        let check = F.check([
            "cat": [F.catalogueSeason(1, episodes: 1), F.catalogueSeason(2, premiered: 3)],
            "cs2": [F.catalogueEpisode(2, 1, aired: 3)],
        ], opened: opened)
        let center = ShowGapsCenter()
        let server = [F.serverEpisode(1, 1)]
        let first = try #require(await center.gaps(show: F.show(), serverEpisodes: server, check: check, now: F.now))
        _ = await center.gaps(show: F.show(), serverEpisodes: server, check: check, now: F.now.addingTimeInterval(60))
        #expect(await opened.keys == ["cat"])
        let season = try #require(first.seasons.first)
        let filled = try #require(await center.opening(season, of: F.show(), in: first, check: check, now: F.now))
        #expect(filled.missing(inSeason: 2).map(\.episode) == [1])
        let again = try #require(await center.gaps(show: F.show(), serverEpisodes: server, check: check, now: F.now.addingTimeInterval(120)))
        #expect(again.missing(inSeason: 2).map(\.episode) == [1])
        _ = await center.gaps(show: F.show(), serverEpisodes: server + [F.serverEpisode(2, 1)], check: check, now: F.now.addingTimeInterval(180))
        #expect(await opened.keys == ["cat", "cs2", "cat", "cs2"], "an episode arriving makes the cached answer stale")
        #expect(await center.gaps(show: F.show(), serverEpisodes: [], check: F.check([:], failing: ["cat"]), now: F.now.addingTimeInterval(240)) == nil)
    }
}

struct ShowDetailGapsTests {
    typealias F = GapFixtures

    private func model(gaps: ShowGaps, selected: String = "s2") -> ShowDetailModel {
        let seasons = [DetailFixtures.season(1, watched: 3, total: 3), DetailFixtures.season(2, watched: 0, total: 2)]
        let episodes = [DetailFixtures.episode(1, season: 2), DetailFixtures.episode(4, season: 2)]
        return ShowDetailModel(show: F.show(), seasons: seasons, selectedSeasonKey: selected, episodes: episodes, allEpisodes: episodes, gaps: gaps)
    }

    private let gaps = ShowGaps(
        seasons: [MissingSeason(index: 3, title: "Season 3", catalogueKey: "cs3")],
        episodes: [
            2: [MissingEpisode(season: 2, episode: 2, title: "Two", airDate: "2026-01-02"), MissingEpisode(season: 2, episode: 3, title: "Three", airDate: "2026-01-09")],
            3: [MissingEpisode(season: 3, episode: 1, title: "Back", airDate: "2026-11-10")],
        ]
    )

    @Test func missingEpisodesSitBetweenTheServersByNumber() {
        let rows = model(gaps: gaps).episodeRows(showingSkipped: false)
        #expect(rows.map { row -> String in
            switch row {
            case .episode(let episode): "have \(episode.index ?? 0)"
            case .missing(let missing): "lack \(missing.episode)"
            }
        } == ["have 1", "lack 2", "lack 3", "have 4"])
        #expect(model(gaps: gaps).episodeRows(showingSkipped: false, highlights: []).isEmpty, "the highlights filter lists only what plays")
    }

    @Test func aMissingSeasonIsAChipInItsPlaceAndListsOnlyWhatAired() {
        let chips = model(gaps: gaps).seasonChips
        #expect(chips.map(\.title) == ["Season 1", "Season 2", "Season 3"])
        #expect(chips.map(\.isMissing) == [false, false, true])
        #expect(chips.last?.watchedText == ShowGapsCopy.notOnServer)
        let opened = model(gaps: gaps, selected: MissingSeason.id(3)).replacingEpisodes([])
        #expect(opened.selectedMissingSeason?.index == 3)
        #expect(opened.selectedSeasonTitle == "Season 3")
        #expect(opened.selectedSeasonWatchedText == ShowGapsCopy.notOnServer)
        #expect(opened.episodeRows(showingSkipped: false) == [.missing(MissingEpisode(season: 3, episode: 1, title: "Back", airDate: "2026-11-10"))])
        #expect(opened.watchedOptions.season.isEmpty)
    }

    @Test func gapsSurviveEveryChangeOfTheScreen() {
        let base = model(gaps: gaps)
        #expect(base.selectingSeason("s1").gaps == gaps)
        #expect(base.replacingEpisodes([]).gaps == gaps)
        #expect(base.loadingSeason("s1").gaps == gaps)
        #expect(base.failingEpisodes().gaps == gaps)
        #expect(base.replacingEssentials(nil).gaps == gaps)
        #expect(base.replacingShow(F.show()).gaps == gaps)
    }

    @Test func aMissingEpisodeReadsAsNotOnTheServerAndIsDimmedMost() {
        let missing = MissingEpisode(season: 2, episode: 5, title: "Gulls", airDate: "2026-11-07")
        let status = EpisodeStatus(missing: missing)
        #expect(status.isMissing)
        #expect(status.marker == .missing)
        #expect(status.title == "Gulls")
        #expect(status.eyebrow.hasPrefix("E5"))
        #expect(status.metaParts.count == 1)
        #expect(status.contentAlpha < EpisodeStatus(episode: DetailFixtures.episode(1, watched: true), isUpNext: false).contentAlpha)
        #expect(status.spokenText.contains(ShowGapsCopy.notOnServer))
        #expect(EpisodeStatus(missing: missing, shielded: true).title == "Episode 5")
        #expect(ShowGapsCopy.aired("not a date") == nil)
    }
}

struct ShowGapsFollowTests {
    typealias F = GapFixtures

    @Test func aMissingSeasonsIdCarriesItsNumber() {
        #expect(MissingSeason.index(ofID: MissingSeason.id(7)) == 7)
        #expect(MissingSeason.index(ofID: "s7") == nil)
        #expect(MissingSeason.index(ofID: nil) == nil)
    }

    @Test func aNewLookKeepsTheEpisodesFetchedForASeasonStillMissing() {
        let older = ShowGaps(seasons: [MissingSeason(index: 3, title: "Season 3", catalogueKey: "cs3"), MissingSeason(index: 4, title: "Season 4", catalogueKey: "cs4")],
                             episodes: [3: [MissingEpisode(season: 3, episode: 1, title: "A", airDate: "2026-01-01")], 4: [MissingEpisode(season: 4, episode: 1, title: "B", airDate: "2026-02-01")]])
        let newer = ShowGaps(seasons: [MissingSeason(index: 3, title: "Season 3", catalogueKey: "cs3")], episodes: [:])
        let kept = newer.keepingOpened(from: older)
        #expect(kept.missing(inSeason: 3).map(\.title) == ["A"])
        #expect(kept.missing(inSeason: 4).isEmpty, "a season no longer missing does not come back")
    }

    @Test func whatTheServerNowHasIsNeverListedAsMissing() {
        let gaps = ShowGaps(
            seasons: [MissingSeason(index: 2, title: "Season 2", catalogueKey: "cs2")],
            episodes: [1: [MissingEpisode(season: 1, episode: 2, title: "Two", airDate: "2026-01-02")]]
        )
        let seasons = [DetailFixtures.season(1, watched: 0, total: 2), DetailFixtures.season(2, watched: 0, total: 1)]
        let episodes = [DetailFixtures.episode(1, season: 1), DetailFixtures.episode(2, season: 1)]
        let model = ShowDetailModel(show: F.show(), seasons: seasons, selectedSeasonKey: "s1", episodes: episodes, allEpisodes: episodes, gaps: gaps)
        #expect(model.episodeRows(showingSkipped: false).count == 2)
        #expect(!model.seasonChips.contains { $0.isMissing })
        let stale = model.selectingSeason(MissingSeason.id(2))
        #expect(stale.leftMissingSeason)
        #expect(stale.arrivedSeason?.id == "s2")
        #expect(!stale.needsMissingEpisodes)
        let dropped = ShowDetailModel(show: F.show(), seasons: seasons, selectedSeasonKey: MissingSeason.id(5), gaps: .none)
        #expect(dropped.leftMissingSeason, "a season the catalogue no longer lists is left too")
        let open = ShowDetailModel(show: F.show(), seasons: [seasons[0]], selectedSeasonKey: MissingSeason.id(2), gaps: gaps)
        #expect(open.needsMissingEpisodes)
        #expect(!open.leftMissingSeason)
    }
}

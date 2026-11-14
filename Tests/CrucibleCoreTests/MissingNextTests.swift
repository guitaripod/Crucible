import Foundation
import Testing
@testable import CrucibleCore

struct MissingNextTests {
    typealias F = GapFixtures

    private func check(leaves: [String: [PlexMetadata]], children: [String: [PlexMetadata]], failing: Set<String> = []) -> MissingNextCheck {
        MissingNextCheck(
            fetchLeaves: { key in
                if failing.contains(key) { throw APIError.timedOut }
                return leaves[key] ?? []
            },
            fetchChildren: { children[$0] ?? [] }
        )
    }

    @Test func aCaughtUpShowGetsTheNextAiredEpisodeOfItsSeasonThenOfTheNext() async throws {
        let catalogue: [String: [PlexMetadata]] = [
            "cat": [F.catalogueSeason(1), F.catalogueSeason(2, premiered: 9)],
            "cs1": [F.catalogueEpisode(1, 1, aired: 60), F.catalogueEpisode(1, 2, aired: 53), F.catalogueEpisode(1, 3, aired: 46)],
            "cs2": [F.catalogueEpisode(2, 1, aired: 9), F.catalogueEpisode(2, 2, aired: 2)],
        ]
        let inSeason = await check(leaves: ["a": [F.serverEpisode(1, 1, watched: true, show: "a"), F.serverEpisode(1, 2, watched: true, show: "a")]], children: catalogue)
            .run(shows: ["a"], now: F.now, calendar: F.calendar)
        let next = try #require(inSeason.found.first)
        #expect(next.season == 1)
        #expect(next.episode == 3)
        #expect(next.seasonRatingKey == "s1")
        #expect(next.initialSeasonKey == "s1")
        #expect(next.showTitle == "Salt Road")
        #expect(next.posterPath == "/library/metadata/a/thumb/1")
        let nextSeason = await check(leaves: ["a": [F.serverEpisode(1, 2, watched: true, show: "a"), F.serverEpisode(1, 3, watched: true, show: "a")]], children: catalogue)
            .run(shows: ["a"], now: F.now, calendar: F.calendar)
        #expect(nextSeason.found.map { "S\($0.season)E\($0.episode)" } == ["S2E1"])
        #expect(nextSeason.found.first?.seasonRatingKey == nil)
        #expect(nextSeason.found.first?.initialSeasonKey == MissingSeason.id(2))
        #expect(nextSeason.found.first?.caption.hasSuffix(ShowGapsCopy.notOnServer) == true)
    }

    @Test func aShowNotCaughtUpOrWithNothingNewOrNumberedDifferentlyHasNoCard() async {
        let catalogue: [String: [PlexMetadata]] = [
            "cat": [F.catalogueSeason(1), F.catalogueSeason(2, premiered: -10)],
            "cs1": [F.catalogueEpisode(1, 1, aired: 60), F.catalogueEpisode(1, 2, aired: 53)],
        ]
        let behind = await check(leaves: ["a": [F.serverEpisode(1, 1, watched: true, show: "a"), F.serverEpisode(1, 2, show: "a")]], children: catalogue)
            .run(shows: ["a"], now: F.now, calendar: F.calendar)
        #expect(behind.found.isEmpty)
        let upcoming = await check(leaves: ["a": [F.serverEpisode(1, 1, watched: true, show: "a"), F.serverEpisode(1, 2, watched: true, show: "a")]], children: catalogue)
            .run(shows: ["a"], now: F.now, calendar: F.calendar)
        #expect(upcoming.found.isEmpty, "the next season has not premiered")
        let renumbered = await check(leaves: ["a": [F.serverEpisode(1, 90, watched: true, show: "a")]], children: catalogue)
            .run(shows: ["a"], now: F.now, calendar: F.calendar)
        #expect(renumbered.found.isEmpty)
        let failed = await check(leaves: [:], children: catalogue, failing: ["a"]).run(shows: ["a"], now: F.now, calendar: F.calendar)
        #expect(failed.unknown == ["a"])
    }

    @Test func candidatesAreFinishedShowsTheServerListsNothingNextFor() {
        let nextUp = [
            F.serverEpisode(1, 2, show: "onDeck"),
            DetailFixtures.item(["ratingKey": "s9", "type": "season", "title": "Season 1", "parentRatingKey": "season"]),
            DetailFixtures.item(["ratingKey": "m", "type": "movie", "title": "Film"]),
        ]
        #expect(UpNextGaps.candidates(followed: ["caughtUp", "onDeck", "season", "caughtUp", "other"], nextUp: nextUp) == ["caughtUp", "other"])
    }

    @MainActor
    @Test func eachShowIsLookedAtOnItsOwnClockAndLeavesOnceTheServerListsItsNextEpisode() async {
        let name = "up-next-gaps-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let store = UpNextGaps(defaults: defaults)
        let catalogue: [String: [PlexMetadata]] = [
            "cat": [F.catalogueSeason(1)],
            "cs1": [F.catalogueEpisode(1, 1, aired: 20), F.catalogueEpisode(1, 2, aired: 2)],
        ]
        let looked = OpenedCatalogueKeys()
        let counting = MissingNextCheck(
            fetchLeaves: { key in
                await looked.add(key)
                return [F.serverEpisode(1, 1, watched: true, show: key)]
            },
            fetchChildren: { catalogue[$0] ?? [] }
        )
        await store.refresh(owner: "o", check: counting, candidates: ["a"], force: false, now: F.now)
        #expect(store.entries(for: "o").map(\.showRatingKey) == ["a"])
        await store.refresh(owner: "o", check: counting, candidates: ["a"], force: false, now: F.now.addingTimeInterval(60))
        await store.refresh(owner: "o", check: counting, candidates: ["b", "a"], force: false, now: F.now.addingTimeInterval(120))
        #expect(await looked.keys == ["a", "b"], "only the newly finished show is looked at")
        #expect(store.entries(for: "o").map(\.showRatingKey) == ["b", "a"])
        #expect(store.entries(for: "o", nextUp: [F.serverEpisode(1, 2, show: "a")]).map(\.showRatingKey) == ["b"])
        #expect(store.entries(for: "someone else").isEmpty)
        await store.refresh(owner: "o", check: counting, candidates: ["b", "a"], force: false, now: F.now.addingTimeInterval(UpNextGaps.freshness + 60))
        #expect(await looked.keys.count == 3, "a's look went stale, b's did not")
        let failing = MissingNextCheck(fetchLeaves: { _ in throw APIError.timedOut }, fetchChildren: { _ in [] })
        await store.refresh(owner: "o", check: failing, candidates: ["b", "a"], force: true, now: F.now.addingTimeInterval(UpNextGaps.freshness + 120))
        #expect(store.entries(for: "o").count == 2, "a failed look keeps what was found")
        await store.refresh(owner: "o", check: counting, candidates: ["a"], force: false, now: F.now.addingTimeInterval(UpNextGaps.freshness + 180))
        #expect(store.entries(for: "o").map(\.showRatingKey) == ["a"], "a show no longer finished lately leaves")
        await store.refresh(owner: "o", check: counting, candidates: [], force: false, now: F.now.addingTimeInterval(UpNextGaps.freshness + 240))
        #expect(UpNextGaps(defaults: defaults).entries(for: "o").isEmpty)
    }
}

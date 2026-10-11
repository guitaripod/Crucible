import Foundation
import Testing
@testable import CrucibleCore

struct DetailRouteTests {
    @Test func relatedShowsOpenTheShowScreen() {
        let related = DetailFixtures.item(["ratingKey": "9", "type": "show"])
        #expect(DetailRoute.related(related) == .show(ratingKey: "9", initialSeasonKey: nil))
    }

    @Test func relatedMoviesAndEpisodesOpenTheItemScreenWithTheirParents() {
        let movie = DetailFixtures.item(["ratingKey": "9", "type": "movie"])
        #expect(DetailRoute.related(movie) == .item(ratingKey: "9", mediaType: "movie", showRatingKey: nil, seasonRatingKey: nil))
        let episode = DetailFixtures.item(["ratingKey": "9", "type": "episode", "grandparentRatingKey": "s", "parentRatingKey": "se"])
        #expect(DetailRoute.related(episode) == .item(ratingKey: "9", mediaType: "episode", showRatingKey: "s", seasonRatingKey: "se"))
    }

    @Test func episodesCarryTheShowAndSeasonTheyWerePickedFrom() {
        let episode = DetailFixtures.episode(2)
        #expect(DetailRoute.episode(episode, showRatingKey: "s", seasonRatingKey: "se")
            == .item(ratingKey: "e12", mediaType: "episode", showRatingKey: "s", seasonRatingKey: "se"))
    }
}

struct DetailCastAvatarTests {
    @Test func gradientIsStablePerName() {
        #expect(CastAvatar.gradient(for: "Keanu Reeves") == CastAvatar.gradient(for: "Keanu Reeves"))
    }

    @Test func stableIndexMatchesThePublishedHash() {
        #expect(CastAvatar.stableIndex("", count: 6) == 0)
        #expect(CastAvatar.stableIndex("A", count: 6) == 65 % 6)
        #expect(CastAvatar.stableIndex("AB", count: 6) == (65 * 31 + 66) % 6)
    }

    @Test func indexStaysInRangeForLongAndUnicodeNames() {
        let names = ["Zoë Saldaña", String(repeating: "Wolfeschlegelsteinhausenbergerdorff ", count: 40), "渡辺 謙", "🎬"]
        for name in names {
            let index = CastAvatar.stableIndex(name, count: 6)
            #expect((0 ..< 6).contains(index))
        }
    }

    @Test func differentNamesSpreadAcrossThePalette() {
        let names = (0 ..< 60).map { "Person \($0)" }
        let colours = Set(names.map { CastAvatar.gradient(for: $0).start })
        #expect(colours.count > 1)
    }
}

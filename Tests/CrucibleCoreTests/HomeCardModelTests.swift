import Foundation
import Testing
@testable import CrucibleCore

struct HomeCardModelTests {
    private typealias F = HomeFixtures

    private let episode = F.item("5", type: "episode", title: "Low Tide", fields: [
        "grandparentTitle": "The Show", "grandparentThumb": "/show/thumb", "grandparentArt": "/show/art",
        "parentIndex": 2, "index": 4, "thumb": "/ep/thumb", "art": "/ep/art",
        "duration": 2_640_000, "viewOffset": 660_000,
    ])
    private let movie = F.item("1", title: "Salt", fields: [
        "year": 2021, "duration": 7_500_000, "thumb": "/m/thumb", "art": "/m/art",
    ])
    private let show = F.item("9", type: "show", title: "Series", fields: [
        "year": 2019, "thumb": "/s/thumb", "leafCount": 12, "viewedLeafCount": 5,
    ])

    @Test func posterEpisodeUsesShowPosterTitleAndUpNextSubtitle() {
        let card = HomeCardModel(item: episode, bucket: .upNext, layout: .poster)
        #expect(card.id == "5")
        #expect(card.title == "The Show")
        #expect(card.imagePath == "/show/thumb")
        #expect(card.subtitle == "S2 · E4 · 44 min")
        #expect(card.usesSeriesPlaceholder)
        #expect(card.trailingText == nil)
        #expect(!card.showsPlayChip)
    }

    @Test func posterSubtitleDependsOnBucket() {
        #expect(HomeCardModel(item: episode, bucket: .recentlyAdded, layout: .poster).subtitle == "S2 · E4 · Low Tide")
        #expect(HomeCardModel(item: movie, bucket: .recentlyAdded, layout: .poster).subtitle == "2021")
        #expect(HomeCardModel(item: movie, bucket: .continueWatching, layout: .poster).subtitle == "2021 · 2 h 05 m")
        #expect(HomeCardModel(item: show, bucket: .recentlyAdded, layout: .poster).subtitle == "2019")
    }

    @Test func progressNeedsPositionAndDuration() {
        #expect(HomeCardModel(item: episode, bucket: .upNext, layout: .poster).progress == 0.25)
        #expect(HomeCardModel(item: movie, bucket: .upNext, layout: .poster).progress == nil)
        let noDuration = F.item("2", fields: ["viewOffset": 1000])
        #expect(HomeCardModel(item: noDuration, bucket: .upNext, layout: .poster).progress == nil)
    }

    @Test func unwatchedDotOnlyOnRecentlyAdded() {
        #expect(HomeCardModel(item: movie, bucket: .recentlyAdded, layout: .poster).isUnwatched)
        #expect(!HomeCardModel(item: movie, bucket: .upNext, layout: .poster).isUnwatched)
        #expect(HomeCardModel(item: show, bucket: .recentlyAdded, layout: .poster).isUnwatched)
        let watched = F.item("3", fields: ["viewCount": 1])
        #expect(!HomeCardModel(item: watched, bucket: .recentlyAdded, layout: .poster).isUnwatched)
    }

    @Test func seriesCardsCountUnwatchedEpisodesAndUseSeriesPlaceholders() {
        let card = HomeCardModel(item: show, bucket: .recentlyAdded, layout: .poster)
        #expect(card.unwatchedCount == 7)
        #expect(card.usesSeriesPlaceholder)
        #expect(card.imagePath == "/s/thumb")
        #expect(!HomeCardModel(item: movie, bucket: .recentlyAdded, layout: .poster).usesSeriesPlaceholder)
    }

    @Test func posterPathFallbacks() {
        let seasonNoThumb = F.item("4", type: "season", fields: ["parentThumb": "/parent", "grandparentThumb": "/grand"])
        #expect(HomeCardModel(item: seasonNoThumb, bucket: .recentlyAdded, layout: .poster).imagePath == "/parent")
        let episodeNoShowThumb = F.item("6", type: "episode", fields: ["thumb": "/own"])
        #expect(HomeCardModel(item: episodeNoShowThumb, bucket: .upNext, layout: .poster).imagePath == "/own")
        let movieViaShow = F.item("7", fields: ["grandparentThumb": "/grand"])
        #expect(HomeCardModel(item: movieViaShow, bucket: .upNext, layout: .poster).imagePath == "/grand")
    }

    @Test func landscapeEpisodeUsesStillAndRemainingTime() {
        let card = HomeCardModel(item: episode, bucket: .continueWatching, layout: .landscape)
        #expect(card.imagePath == "/ep/thumb")
        #expect(card.subtitle == "S2 · E4 · Low Tide")
        #expect(card.trailingText == "33 min left")
        #expect(card.usesSeriesPlaceholder)
        #expect(card.showsPlayChip)
        #expect(!card.isUnwatched)
    }

    @Test func landscapeMovieUsesBackdropAndRuntime() {
        let card = HomeCardModel(item: movie, bucket: .continueWatching, layout: .landscape)
        #expect(card.imagePath == "/m/art")
        #expect(card.subtitle == "Movie · 2 h 05 m")
        #expect(card.trailingText == "2 h 05 m")
        #expect(!card.usesSeriesPlaceholder)
    }

    @Test func landscapeShowHasNoPlayChip() {
        let card = HomeCardModel(item: show, bucket: .upNext, layout: .landscape)
        #expect(!card.showsPlayChip)
        #expect(card.subtitle == "2019")
    }

    @Test func flagsReflectPlayabilityAndWatchedState() {
        let watched = F.item("3", fields: ["viewCount": 1])
        let card = HomeCardModel(item: watched, bucket: .upNext, layout: .poster)
        #expect(card.isWatched)
        #expect(card.isPlayable)
        #expect(!HomeCardModel(item: show, bucket: .upNext, layout: .poster).isPlayable)
    }
}

struct HomeHeroModelTests {
    private typealias F = HomeFixtures

    private let resuming = F.item("5", type: "episode", title: "Low Tide", fields: [
        "grandparentTitle": "The Show", "parentIndex": 2, "index": 4,
        "duration": 2_640_000, "viewOffset": 660_000, "art": "/ep/art", "grandparentArt": "/show/art",
    ])

    @Test func resumingHeroShowsProgressAndRemainingTime() {
        let hero = HomeHeroModel(item: resuming, eyebrow: "Continue Watching")
        #expect(hero.eyebrow == "Continue Watching")
        #expect(hero.title == "The Show")
        #expect(hero.subtitle == "S2 · E4 · Low Tide")
        #expect(hero.actionTitle == "Resume")
        #expect(hero.progress == 0.25)
        #expect(hero.trailingText == "33 min left")
        #expect(hero.spokenLabel == "Resume The Show, season 2 episode 4, 33 minutes left")
    }

    @Test func freshMovieHeroPlaysFromTheStart() {
        let movie = F.item("1", title: "Salt", fields: ["year": 2021, "duration": 7_500_000])
        let hero = HomeHeroModel(item: movie, eyebrow: "Up Next")
        #expect(hero.actionTitle == "Play")
        #expect(hero.progress == nil)
        #expect(hero.subtitle == "2021 · 2 h 05 m")
        #expect(hero.trailingText == "2 h 05 m")
        #expect(hero.spokenLabel == "Play Salt, 2 hours, 5 minutes")
    }

    @Test func itemWithoutRuntimeHasNoTimePhrase() {
        let hero = HomeHeroModel(item: F.item("1", title: "Salt"), eyebrow: "Up Next")
        #expect(hero.spokenLabel == "Play Salt")
        #expect(hero.trailingText == nil)
    }

    @Test func backdropPrefersShowArtForEpisodes() {
        #expect(HomeHeroModel(item: resuming, eyebrow: "x").backdropPath == "/show/art")
        let movie = F.item("1", fields: ["art": "/m/art", "thumb": "/m/thumb"])
        #expect(HomeHeroModel(item: movie, eyebrow: "x").backdropPath == "/m/art")
    }

    @Test func backdropFallsBackToCachedArtThenThumb() {
        let bare = F.item("1", fields: ["thumb": "/m/thumb"])
        #expect(HomeHeroModel(item: bare, eyebrow: "x", cachedArt: ["1": "/cached"]).backdropPath == "/cached")
        #expect(HomeHeroModel(item: bare, eyebrow: "x").backdropPath == "/m/thumb")
        let bareEpisode = F.item("2", type: "episode", fields: ["thumb": "/e/thumb"])
        #expect(HomeHeroModel(item: bareEpisode, eyebrow: "x", cachedArt: ["2": "/cached"]).backdropPath == "/cached")
        #expect(HomeHeroModel(item: bareEpisode, eyebrow: "x").backdropPath == "/e/thumb")
        let viaShowPoster = F.item("3", fields: ["grandparentThumb": "/g/thumb"])
        #expect(HomeHeroModel(item: viaShowPoster, eyebrow: "x").backdropPath == "/g/thumb")
    }
}

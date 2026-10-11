import Foundation
import Testing
@testable import CrucibleCore

struct DetailShowModelTests {
    private let show = DetailFixtures.item([
        "ratingKey": "show",
        "type": "show",
        "title": "The Show",
        "year": 2019,
        "childCount": 3,
        "leafCount": 20,
        "viewedLeafCount": 8,
    ])

    private func model(
        show: PlexMetadata? = nil,
        seasons: [PlexMetadata] = [],
        selected: String? = nil,
        episodes: [PlexMetadata] = [],
        all: [PlexMetadata] = []
    ) -> ShowDetailModel {
        ShowDetailModel(show: show ?? self.show, seasons: seasons, selectedSeasonKey: selected, episodes: episodes, allEpisodes: all)
    }

    @Test func upNextIsNilWithoutEpisodes() {
        #expect(ShowDetailModel.computeUpNext(in: []) == nil)
    }

    @Test func upNextStartsAtTheFirstEpisodeWhenNothingIsWatched() {
        let episodes = (1 ... 3).map { DetailFixtures.episode($0) }
        let next = ShowDetailModel.computeUpNext(in: episodes)
        #expect(next?.episode.id == "e11")
        #expect(next?.kind == .start)
    }

    @Test func upNextResumesTheFirstInProgressEpisode() {
        let episodes = [
            DetailFixtures.episode(1, watched: true),
            DetailFixtures.episode(2, offsetMs: 300_000),
            DetailFixtures.episode(3, offsetMs: 100_000),
        ]
        let next = ShowDetailModel.computeUpNext(in: episodes)
        #expect(next?.episode.id == "e12")
        #expect(next?.kind == .resume)
    }

    @Test func aWatchedEpisodeWithAnOffsetIsNotInProgress() {
        let episodes = [DetailFixtures.episode(1, watched: true, offsetMs: 300_000), DetailFixtures.episode(2)]
        let next = ShowDetailModel.computeUpNext(in: episodes)
        #expect(next?.episode.id == "e12")
        #expect(next?.kind == .next)
    }

    @Test func upNextIsTheFirstUnwatchedAfterTheLastWatched() {
        let episodes = [
            DetailFixtures.episode(1, watched: true),
            DetailFixtures.episode(2),
            DetailFixtures.episode(3, watched: true),
            DetailFixtures.episode(4),
            DetailFixtures.episode(5),
        ]
        let next = ShowDetailModel.computeUpNext(in: episodes)
        #expect(next?.episode.id == "e14")
        #expect(next?.kind == .next)
    }

    @Test func upNextWrapsToAnEarlierGapWhenTheTailIsWatched() {
        let episodes = [DetailFixtures.episode(1), DetailFixtures.episode(2, watched: true), DetailFixtures.episode(3, watched: true)]
        let next = ShowDetailModel.computeUpNext(in: episodes)
        #expect(next?.episode.id == "e11")
        #expect(next?.kind == .next)
    }

    @Test func upNextRestartsWhenEverythingIsWatched() {
        let episodes = (1 ... 3).map { DetailFixtures.episode($0, watched: true) }
        let next = ShowDetailModel.computeUpNext(in: episodes)
        #expect(next?.episode.id == "e11")
        #expect(next?.kind == .start)
    }

    @Test func upNextUsesAllEpisodesWhenPresentAndTheSeasonOtherwise() {
        let season = [DetailFixtures.episode(1, season: 2)]
        let all = [DetailFixtures.episode(1, watched: true), DetailFixtures.episode(2)]
        #expect(model(episodes: season, all: all).upNext?.episode.id == "e12")
        #expect(model(episodes: season).upNext?.episode.id == "e21")
        #expect(model().upNext == nil)
    }

    @Test func initialSeasonPrefersTheCallersSeasonThenTheFirstUnwatchedThenTheFirst() {
        let seasons = [
            DetailFixtures.season(1, watched: 10, total: 10),
            DetailFixtures.season(2, watched: 3, total: 10),
            DetailFixtures.season(3, watched: 0, total: 10),
        ]
        #expect(ShowDetailModel.initialSeasonKey(seasons: seasons, preferred: "s3") == "s3")
        #expect(ShowDetailModel.initialSeasonKey(seasons: seasons, preferred: "missing") == "s2")
        #expect(ShowDetailModel.initialSeasonKey(seasons: seasons, preferred: nil) == "s2")

        let watched = [DetailFixtures.season(1, watched: 10, total: 10), DetailFixtures.season(2, watched: 4, total: 4)]
        #expect(ShowDetailModel.initialSeasonKey(seasons: watched, preferred: nil) == "s1")
        #expect(ShowDetailModel.initialSeasonKey(seasons: [], preferred: "s1") == nil)
    }

    @Test func emptySeasonsAreNeverUnwatched() {
        let seasons = [DetailFixtures.season(1, watched: 0, total: 0), DetailFixtures.season(2, watched: 1, total: 5)]
        #expect(ShowDetailModel.initialSeasonKey(seasons: seasons, preferred: nil) == "s2")
    }

    @Test func resolvedSeasonKeepsAValidSelection() {
        let seasons = [DetailFixtures.season(1, watched: 10, total: 10), DetailFixtures.season(2, watched: 3, total: 10)]
        #expect(ShowDetailModel.resolvedSeasonKey(current: "s1", seasons: seasons, preferred: "s2") == "s1")
        #expect(ShowDetailModel.resolvedSeasonKey(current: "gone", seasons: seasons, preferred: "s2") == "s2")
        #expect(ShowDetailModel.resolvedSeasonKey(current: nil, seasons: seasons, preferred: nil) == "s2")
        #expect(ShowDetailModel.resolvedSeasonKey(current: "s1", seasons: [], preferred: nil) == nil)
    }

    @Test func primaryButtonNamesTheUpNextEpisode() {
        let started = model(all: [DetailFixtures.episode(1, watched: true), DetailFixtures.episode(2, season: 1)])
        #expect(started.primaryTitle == "Continue S1 · E2")
        #expect(started.primaryAccessibilityLabel == "Continue The Show, season 1 episode 2")
        #expect(started.isPrimaryEnabled)

        let fresh = model(all: [DetailFixtures.episode(1)])
        #expect(fresh.primaryTitle == "Play S1 · E1")
        #expect(fresh.primaryAccessibilityLabel == "Play The Show, season 1 episode 1")

        let resuming = model(all: [DetailFixtures.episode(3, offsetMs: 600_000)])
        #expect(resuming.primaryTitle == "Continue S1 · E3")
        #expect(resuming.primaryAccessibilityLabel.hasPrefix("Resume The Show, season 1 episode 3, "))
        #expect(resuming.primaryAccessibilityLabel.hasSuffix(" left"))

        let empty = model()
        #expect(empty.primaryTitle == "Play")
        #expect(empty.primaryAccessibilityLabel == "Play")
        #expect(!empty.isPrimaryEnabled)
    }

    @Test func showWatchedNeedsEveryLeaf() {
        func watched(_ viewed: Int?, of total: Int?) -> Bool {
            var fields: [String: Any] = ["type": "show"]
            if let viewed { fields["viewedLeafCount"] = viewed }
            if let total { fields["leafCount"] = total }
            return model(show: DetailFixtures.item(fields)).isWatched
        }
        #expect(watched(10, of: 10))
        #expect(watched(12, of: 10))
        #expect(!watched(9, of: 10))
        #expect(!watched(nil, of: 10))
        #expect(!watched(0, of: 0))
        #expect(!watched(nil, of: nil))
        #expect(model(show: DetailFixtures.item(["leafCount": 4, "viewedLeafCount": 4])).watchedAccessibilityLabel == "Watched. Mark unwatched")
        #expect(model().watchedAccessibilityLabel == "Mark watched")
    }

    @Test func watchedOptionsOfferWhatChangesSomething() {
        let partial = model(seasons: [DetailFixtures.season(1, watched: 3, total: 10)], selected: "s1")
        let options = partial.watchedOptions
        #expect(options.show == [
            ShowDetailModel.WatchedOption(title: "Mark Show Watched", ratingKey: "show", watched: true),
            ShowDetailModel.WatchedOption(title: "Mark Show Unwatched", ratingKey: "show", watched: false),
        ])
        #expect(options.season == [
            ShowDetailModel.WatchedOption(title: "Mark Season 1 Watched", ratingKey: "s1", watched: true),
            ShowDetailModel.WatchedOption(title: "Mark Season 1 Unwatched", ratingKey: "s1", watched: false),
        ])

        let allWatched = DetailFixtures.item(["ratingKey": "show", "type": "show", "leafCount": 10, "viewedLeafCount": 10])
        let done = model(show: allWatched, seasons: [DetailFixtures.season(1, watched: 10, total: 10)], selected: "s1")
        #expect(done.watchedOptions.show.map(\.watched) == [false])
        #expect(done.watchedOptions.season.map(\.watched) == [false])

        let untouched = DetailFixtures.item(["ratingKey": "show", "type": "show", "leafCount": 10])
        let fresh = model(show: untouched, seasons: [DetailFixtures.season(2, watched: 0, total: 0)], selected: "s2")
        #expect(fresh.watchedOptions.show.map(\.watched) == [true])
        #expect(fresh.watchedOptions.season.map(\.watched) == [true])

        #expect(model().watchedOptions.season.isEmpty)
    }

    @Test func seasonChipsCarryTitleSelectionAndWatchedText() {
        let seasons = [
            DetailFixtures.season(1, watched: 8, total: 10),
            DetailFixtures.item(["ratingKey": "s2", "type": "season", "title": "", "index": 2]),
        ]
        let chips = model(seasons: seasons, selected: "s2").seasonChips
        #expect(chips == [
            ShowDetailModel.SeasonChip(id: "s1", title: "Season 1", watchedText: "8 of 10 watched", isSelected: false),
            ShowDetailModel.SeasonChip(id: "s2", title: "Season 2", watchedText: nil, isSelected: true),
        ])
    }

    @Test func seasonBarFallsBackToSeason() {
        let seasons = [DetailFixtures.season(1, watched: 8, total: 10, title: "Specials")]
        let selected = model(seasons: seasons, selected: "s1")
        #expect(selected.selectedSeasonTitle == "Specials")
        #expect(selected.selectedSeasonWatchedText == "8 of 10 watched")
        let none = model(seasons: seasons)
        #expect(none.selectedSeasonTitle == "Season")
        #expect(none.selectedSeasonWatchedText == nil)
    }

    @Test func seasonTitleFallsBackToItsNumber() {
        let unnamed = DetailFixtures.item(["type": "season", "title": "", "index": 3])
        #expect(ShowDetailModel.seasonTitle(unnamed) == "Season 3")
        let unnumbered = DetailFixtures.item(["type": "season", "title": ""])
        #expect(ShowDetailModel.seasonTitle(unnumbered) == "Season 0")
    }

    @Test func heroCountsSeasonsFromTheListThenTheShow() {
        let fromShow = model().heroInfo
        #expect(fromShow.eyebrow == "TV SHOW")
        #expect(fromShow.meta.leading == ["2019", "3 Seasons"])

        let one = model(seasons: [DetailFixtures.season(1, watched: 0, total: 1)]).heroInfo
        #expect(one.meta.leading == ["2019", "1 Season"])

        let bare = model(show: DetailFixtures.item(["type": "show", "title": "Bare"])).heroInfo
        #expect(bare.meta.isEmpty)
        #expect(bare.accessibilityText == "Bare, TV show")
    }

    @Test func heroBadgesComeFromTheUpNextEpisode() {
        let withMedia = DetailFixtures.item([
            "ratingKey": "e11", "type": "episode", "title": "One", "index": 1, "parentIndex": 1, "Media": DetailFixtures.richMedia,
        ])
        let rated = DetailFixtures.item(["type": "show", "title": "Rated", "contentRating": "TV-MA"])
        let hero = model(show: rated, all: [withMedia]).heroInfo
        #expect(hero.badges == ["4K", "HDR10", "TV-MA"])
        #expect(model(show: rated).heroInfo.badges == ["TV-MA"])
    }

    @Test func heroArtworkPrefersBackdrop() {
        let art = DetailFixtures.item(["type": "show", "art": "/art", "thumb": "/thumb"])
        #expect(model(show: art).heroArtwork == DetailArtwork(path: "/art", isBackdrop: true))
        let poster = DetailFixtures.item(["type": "show", "thumb": "/thumb"])
        #expect(model(show: poster).heroArtwork == DetailArtwork(path: "/thumb", isBackdrop: false))
    }

    @Test func statusMarksTheUpNextEpisode() {
        let episodes = [DetailFixtures.episode(1, watched: true), DetailFixtures.episode(2), DetailFixtures.episode(3)]
        let model = model(episodes: episodes, all: episodes)
        #expect(model.status(for: episodes[0]).marker == .watched)
        #expect(model.status(for: episodes[1]).marker == .upNext)
        #expect(model.status(for: episodes[2]).marker == .plain)
        #expect(model.status(for: episodes[2], download: .queued).marker == .downloading)
    }

    @Test func relatedExcludesTheShowItself() {
        let hubs = DetailFixtures.hub([
            DetailFixtures.item(["ratingKey": "show", "type": "show", "title": "Self"]),
            DetailFixtures.item(["ratingKey": "other", "type": "show", "title": "Other"]),
        ])
        let withHubs = DetailFixtures.item(["ratingKey": "show", "type": "show", "Related": hubs])
        #expect(model(show: withHubs).related.map(\.id) == ["other"])
    }

    @Test func replacingKeepsTheOtherParts() {
        let seasons = [DetailFixtures.season(1, watched: 0, total: 2)]
        let episodes = [DetailFixtures.episode(1), DetailFixtures.episode(2)]
        let base = model(seasons: seasons, selected: "s1", episodes: episodes)

        let renamed = base.replacingShow(DetailFixtures.item(["ratingKey": "show", "type": "show", "title": "Renamed"]))
        #expect(renamed.show.title == "Renamed")
        #expect(renamed.seasons.count == 1)
        #expect(renamed.selectedSeasonKey == "s1")
        #expect(renamed.episodes.count == 2)

        let reselected = base.selectingSeason("s9")
        #expect(reselected.selectedSeasonKey == "s9")
        #expect(reselected.episodes.count == 2)
        #expect(reselected.upNext == base.upNext)

        let reloaded = base.replacingEpisodes([DetailFixtures.episode(1, season: 2, watched: true)])
        #expect(reloaded.episodes.map(\.id) == ["e21"])
        #expect(reloaded.selectedSeasonKey == "s1")
        #expect(reloaded.upNext?.kind == .start)
    }

    @Test func loadingASeasonClearsTheOldEpisodesAndKeepsUpNext() {
        let all = [DetailFixtures.episode(1, watched: true), DetailFixtures.episode(2)]
        let base = model(seasons: [DetailFixtures.season(1, watched: 1, total: 2)], selected: "s1", episodes: all, all: all)
        let loading = base.loadingSeason("s2")
        #expect(loading.selectedSeasonKey == "s2")
        #expect(loading.episodes.isEmpty)
        #expect(!loading.episodesFailed)
        #expect(loading.upNext?.episode.id == "e12")
    }

    @Test func failingEpisodesIsFlaggedAndClearedByAReload() {
        let failed = model(selected: "s1", episodes: [DetailFixtures.episode(1)]).failingEpisodes()
        #expect(failed.episodesFailed)
        #expect(failed.episodes.isEmpty)
        #expect(failed.replacingShow(show).episodesFailed)
        #expect(!failed.replacingEpisodes([DetailFixtures.episode(1)]).episodesFailed)
        #expect(!failed.loadingSeason("s2").episodesFailed)
        #expect(!failed.selectingSeason("s2").episodesFailed)
    }

    @Test func summaryPresence() {
        #expect(!model().hasSummary)
        #expect(model(show: DetailFixtures.item(["summary": "Plot"])).hasSummary)
    }
}

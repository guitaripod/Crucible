import Foundation
import Testing
@testable import CrucibleCore

struct DetailMovieModelTests {
    private func role(_ name: String, _ part: String? = nil) -> [String: Any] {
        var fields: [String: Any] = ["tag": name]
        if let part { fields["role"] = part }
        return fields
    }

    @Test func playTitleFollowsTheResumePosition() {
        let fresh = MovieDetailModel(item: DetailFixtures.item(["title": "Heat"]))
        #expect(fresh.playTitle == "Play")
        #expect(fresh.playAccessibilityLabel == "Play Heat")
        #expect(!fresh.hasResumePosition)

        let partway = MovieDetailModel(item: DetailFixtures.item(["title": "Heat", "duration": 2_700_000, "viewOffset": 600_000]))
        #expect(partway.playTitle == "Resume")
        #expect(partway.hasResumePosition)
        #expect(partway.playAccessibilityLabel.hasPrefix("Resume Heat, "))
        #expect(partway.playAccessibilityLabel.hasSuffix(" left"))
    }

    @Test func resumeLabelOmitsTimeLeftWhenTheOffsetPassesTheDuration() {
        let model = MovieDetailModel(item: DetailFixtures.item(["title": "Heat", "duration": 1_000, "viewOffset": 5_000]))
        #expect(model.playAccessibilityLabel == "Resume Heat")
    }

    @Test func progressIsShownOnlyInsideTheRuntime() {
        let inside = MovieDetailModel(item: DetailFixtures.item(["duration": 2_700_000, "viewOffset": 600_000]))
        #expect(inside.hasProgress)
        #expect(inside.progress.text == "35 min left")
        #expect(abs(inside.progress.fraction - 600.0 / 2700.0) < 0.0001)
        #expect(inside.progress.accessibilityText.hasPrefix("22 percent watched, "))

        #expect(!MovieDetailModel(item: DetailFixtures.item(["duration": 2_700_000])).hasProgress)
        #expect(!MovieDetailModel(item: DetailFixtures.item(["duration": 2_700_000, "viewOffset": 2_700_000])).hasProgress)
        #expect(!MovieDetailModel(item: DetailFixtures.item(["viewOffset": 1_000])).hasProgress)
    }

    @Test func resumePositionPrefersTheDownloadedCopy() {
        let model = MovieDetailModel(item: DetailFixtures.item(["duration": 2_700_000, "viewOffset": 600_000]))
        #expect(model.resumePosition(offlineResumeSecs: nil) == 600)
        #expect(model.resumePosition(offlineResumeSecs: 90) == 90)
        #expect(model.resumePosition(offlineResumeSecs: 0) == 0)
    }

    @Test func watchedToggleNamesTheNextState() {
        #expect(MovieDetailModel(item: DetailFixtures.item()).watchedToggleTitle == "Mark Watched")
        #expect(MovieDetailModel(item: DetailFixtures.item(["viewCount": 2])).watchedToggleTitle == "Mark Unwatched")
    }

    @Test func movieHero() {
        let model = MovieDetailModel(item: DetailFixtures.item([
            "title": "Heat",
            "year": 1995,
            "duration": 10_200_000,
            "audienceRating": 8.3,
            "rating": 8.7,
            "contentRating": "R",
        ]))
        let hero = model.heroInfo
        #expect(hero.eyebrow == "MOVIE")
        #expect(hero.title == "Heat")
        #expect(hero.meta == DetailMeta(leading: ["1995", "2 h 50 m"], star: "8.3", trailing: ["87% critics"]))
        #expect(hero.badges == ["R"])
        #expect(hero.accessibilityText.hasPrefix("Heat, movie, 1995, "))
        #expect(hero.accessibilityText.hasSuffix("rated 8.3 out of 10, R"))
    }

    @Test func episodeHero() {
        let model = MovieDetailModel(item: DetailFixtures.item([
            "type": "episode",
            "title": "Low Tide",
            "grandparentTitle": "The Show",
            "parentIndex": 2,
            "index": 4,
            "year": 2021,
            "duration": 2_700_000,
        ]))
        let hero = model.heroInfo
        #expect(hero.eyebrow == "EPISODE · S2 · E4")
        #expect(hero.meta.leading == ["2021", "45 min"])
        #expect(hero.accessibilityText.hasPrefix("Low Tide, The Show, season 2 episode 4, 2021, "))
    }

    @Test func episodeHeroPrefersTheAirDateOverTheYear() throws {
        let model = MovieDetailModel(item: DetailFixtures.item([
            "type": "episode",
            "year": 2021,
            "originallyAvailableAt": "2021-03-05",
        ]))
        let date = try #require(Formatters.plexDate("2021-03-05"))
        #expect(model.heroInfo.meta.leading == [date])
    }

    @Test func otherTypesUseTheirUppercasedTypeAndUnknownHasNoEyebrow() {
        #expect(MovieDetailModel(item: DetailFixtures.item(["type": "clip"])).heroInfo.eyebrow == "CLIP")
        #expect(MovieDetailModel(item: DetailFixtures.item(["type": NSNull()])).heroInfo.eyebrow == "")
        #expect(MovieDetailModel(item: DetailFixtures.item()).heroInfo.meta.isEmpty)
    }

    @Test func heroArtworkDiffersForEpisodes() {
        let movie = MovieDetailModel(item: DetailFixtures.item(["art": "/art", "thumb": "/thumb"]))
        #expect(movie.heroArtwork == DetailArtwork(path: "/art", isBackdrop: true))
        let poster = MovieDetailModel(item: DetailFixtures.item(["thumb": "/thumb"]))
        #expect(poster.heroArtwork == DetailArtwork(path: "/thumb", isBackdrop: false))

        let still = MovieDetailModel(item: DetailFixtures.item(["type": "episode", "thumb": "/still", "grandparentArt": "/show"]))
        #expect(still.heroArtwork == DetailArtwork(path: "/still", isBackdrop: true))
        let showArt = MovieDetailModel(item: DetailFixtures.item(["type": "episode", "grandparentArt": "/show"]))
        #expect(showArt.heroArtwork == DetailArtwork(path: "/show", isBackdrop: false))
    }

    @Test func linksNeedAnEpisodeWithAShowOrSeason() {
        let episode = DetailFixtures.item(["type": "episode", "grandparentRatingKey": "show", "parentRatingKey": "season"])
        let model = MovieDetailModel(item: episode)
        #expect(model.hasLinks)
        #expect(model.showKey == "show")
        #expect(model.seasonKey == "season")
        #expect(model.showRoute == .show(ratingKey: "show", initialSeasonKey: "season"))

        let overridden = MovieDetailModel(item: episode, showRatingKey: "other", seasonRatingKey: "elsewhere")
        #expect(overridden.showKey == "other")
        #expect(overridden.seasonKey == "elsewhere")

        #expect(!MovieDetailModel(item: DetailFixtures.item(["grandparentRatingKey": "show"])).hasLinks)
        #expect(!MovieDetailModel(item: DetailFixtures.item(["type": "episode"])).hasLinks)
        #expect(MovieDetailModel(item: DetailFixtures.item(["type": "episode"])).showRoute == nil)
    }

    @Test func nextEpisodeRouteStaysInTheSeason() {
        let model = MovieDetailModel(item: DetailFixtures.item(["type": "episode", "grandparentRatingKey": "show", "parentRatingKey": "season"]))
        let next = DetailFixtures.episode(5)
        #expect(model.nextEpisodeRoute(next) == .item(ratingKey: next.id, mediaType: "episode", showRatingKey: "show", seasonRatingKey: "season"))
        #expect(MovieDetailModel(item: DetailFixtures.item(["type": "episode"])).nextEpisodeRoute(next) == nil)
    }

    @Test func nextEpisodeNeverCrossesSeasons() {
        let season = [DetailFixtures.episode(1), DetailFixtures.episode(2), DetailFixtures.episode(3)]
        #expect(MovieDetailModel.nextEpisode(after: "e11", in: season)?.id == "e12")
        #expect(MovieDetailModel.nextEpisode(after: "e12", in: season)?.id == "e13")
        #expect(MovieDetailModel.nextEpisode(after: "e13", in: season) == nil)
        #expect(MovieDetailModel.nextEpisode(after: "missing", in: season) == nil)
        #expect(MovieDetailModel.nextEpisode(after: "e11", in: []) == nil)
    }

    @Test func crewListsTwoDirectorsAndTwoWritersAndMergesRoles() {
        let model = MovieDetailModel(item: DetailFixtures.item([
            "Director": [["tag": "Ann"], ["tag": "Bob"], ["tag": "Cy"]],
            "Writer": [["tag": "Bob"], ["tag": "Dee"], ["tag": "Eve"]],
        ]))
        let crew = model.crew
        #expect(crew.map(\.tag) == ["Ann", "Bob", "Dee"])
        #expect(crew.map(\.role) == ["Director", "Director, Writer", "Writer"])
        #expect(crew.allSatisfy { $0.thumb == nil && $0.id == nil })
    }

    @Test func castAndCrewCapsCastAtTwentyAndDropsRepeats() {
        let cast = (1 ... 25).map { role("Actor \($0)", "Part \($0)") } + [role("Actor 1", "Part 1")]
        let model = MovieDetailModel(item: DetailFixtures.item([
            "Director": [["tag": "Ann"]],
            "Role": cast,
        ]))
        let list = model.castAndCrew
        #expect(list.count == 21)
        #expect(list.first?.tag == "Ann")
        #expect(list.last?.tag == "Actor 20")
        #expect(Set(list).count == list.count)

        let repeated = MovieDetailModel(item: DetailFixtures.item(["Role": [role("A", "x"), role("A", "x"), role("A", "y")]]))
        #expect(repeated.castAndCrew.count == 2)
    }

    @Test func factsSkipEmptyValuesAndLabelPluralDirectors() {
        let single = MovieDetailModel(item: DetailFixtures.item([
            "Director": [["tag": "Ann"]],
            "studio": "Warner",
            "Media": DetailFixtures.richMedia,
        ]))
        let keys = single.facts.map(\.key)
        #expect(keys == ["Director", "Studio", "File", "Audio"])
        #expect(single.facts.first?.value == "Ann")

        let plural = MovieDetailModel(item: DetailFixtures.item([
            "Director": [["tag": "Ann"], ["tag": "Bob"], ["tag": "Cy"]],
            "Writer": [["tag": "Dee"], ["tag": "Eve"]],
        ]))
        #expect(plural.facts.map(\.key) == ["Directors", "Writers"])
        #expect(plural.facts.map(\.value) == ["Ann, Bob", "Dee, Eve"])

        #expect(MovieDetailModel(item: DetailFixtures.item()).facts.isEmpty)
    }

    @Test func airedFactIsForEpisodesOnly() throws {
        let aired = try #require(Formatters.plexDate("2021-03-05"))
        let episode = MovieDetailModel(item: DetailFixtures.item(["type": "episode", "originallyAvailableAt": "2021-03-05"]))
        #expect(episode.facts == [DetailFact(key: "Aired", value: aired)])
        let movie = MovieDetailModel(item: DetailFixtures.item(["originallyAvailableAt": "2021-03-05"]))
        #expect(movie.facts.isEmpty)
    }

    @Test func relatedExcludesTheItemDedupesAcrossHubsAndCapsAtEighteen() {
        let items = (1 ... 30).map { DetailFixtures.item(["ratingKey": "r\($0)", "title": "R\($0)"]) }
        let hubs: [String: Any] = ["Hub": [
            ["hubIdentifier": "a", "Metadata": items.prefix(10).map(DetailFixtures.json) + [["ratingKey": "self", "title": "Me", "type": "movie"]]],
            ["hubIdentifier": "b", "Metadata": items.dropFirst(5).map(DetailFixtures.json)],
            ["hubIdentifier": "empty"],
        ]]
        let model = MovieDetailModel(item: DetailFixtures.item(["ratingKey": "self", "Related": hubs]))
        let related = model.related
        #expect(related.count == 18)
        #expect(related.map(\.id) == (1 ... 18).map { "r\($0)" })
        #expect(!related.contains { $0.id == "self" })
    }

    @Test func relatedIsEmptyWithoutHubs() {
        #expect(MovieDetailModel(item: DetailFixtures.item()).related.isEmpty)
    }

    @Test func tracksKeepValidPicksAndFallBackToDefaults() {
        let model = MovieDetailModel(item: DetailFixtures.item(["Media": DetailFixtures.richMedia]))
        #expect(model.hasTracks)
        #expect(model.reconciledTracks(audioId: nil, subtitleId: nil) == TrackSelection(audioId: 11, subtitleId: nil))
        #expect(model.reconciledTracks(audioId: 12, subtitleId: 13) == TrackSelection(audioId: 12, subtitleId: 13))
        #expect(model.reconciledTracks(audioId: 99, subtitleId: 99) == TrackSelection(audioId: 11, subtitleId: nil))

        let none = MovieDetailModel(item: DetailFixtures.item())
        #expect(!none.hasTracks)
        #expect(none.reconciledTracks(audioId: 5, subtitleId: 6) == TrackSelection(audioId: nil, subtitleId: nil))
    }

    @Test func trackButtonValues() {
        let model = MovieDetailModel(item: DetailFixtures.item(["Media": DetailFixtures.richMedia]))
        #expect(model.audioButtonValue(selectedId: 11) == "English · 5.1")
        #expect(model.audioButtonValue(selectedId: 12) == "French · Stereo")
        #expect(model.subtitleButtonValue(selectedId: nil) == "Off")
        #expect(model.subtitleButtonValue(selectedId: 13) == "English")

        let none = MovieDetailModel(item: DetailFixtures.item())
        #expect(none.audioButtonValue(selectedId: nil) == nil)
        #expect(none.subtitleButtonValue(selectedId: nil) == nil)
    }

    @Test func trackOptionsMarkSelectionAndDisableImageSubtitles() {
        let model = MovieDetailModel(item: DetailFixtures.item(["Media": DetailFixtures.richMedia]))
        let audio = model.audioOptions(selectedId: 12)
        #expect(audio.map(\.id) == [11, 12])
        #expect(audio.map(\.isSelected) == [false, true])
        #expect(audio.first?.title == "English (EAC3 5.1)")
        #expect(audio.first?.detail == "DD+ · 5.1 · 640 kbps")
        #expect(audio.allSatisfy { $0.isEnabled })

        let subtitles = model.subtitleOptions(selectedId: 14)
        #expect(subtitles.map(\.id) == [13, 14])
        #expect(subtitles.map(\.isEnabled) == [true, false])
        #expect(subtitles.map(\.isSelected) == [false, false])
        #expect(subtitles.last?.detail == "Image-based")
        #expect(model.subtitleOptions(selectedId: 13).map(\.isSelected) == [true, false])
    }

    @Test func summaryPresence() {
        #expect(!MovieDetailModel(item: DetailFixtures.item()).hasSummary)
        #expect(!MovieDetailModel(item: DetailFixtures.item(["summary": ""])).hasSummary)
        #expect(MovieDetailModel(item: DetailFixtures.item(["summary": "Plot"])).hasSummary)
    }
}

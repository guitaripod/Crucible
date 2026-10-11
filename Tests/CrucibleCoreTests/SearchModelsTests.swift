import Foundation
import Testing
@testable import CrucibleCore

struct SearchModelsTests {
    @Test func scopeIncludesOnlyItsMediaType() {
        #expect(SearchScope.all.includes("movie") && SearchScope.all.includes("anything"))
        #expect(SearchScope.movies.includes("movie") && !SearchScope.movies.includes("show"))
        #expect(SearchScope.shows.includes("show") && !SearchScope.shows.includes("episode"))
        #expect(SearchScope.episodes.includes("episode") && !SearchScope.episodes.includes("movie"))
    }

    @Test func scopeOrderMatchesTheScopeBarIndices() {
        #expect(SearchScope.allCases.map(\.title) == ["All", "Movies", "Shows", "Episodes"])
        #expect(SearchScope.allCases.map(\.rawValue) == [0, 1, 2, 3])
    }

    @Test func sectionTitles() {
        #expect(SearchSection.topResult.title == nil)
        #expect(SearchSection.recent.title == "Recent")
        #expect(SearchSection.browse.title == "Browse")
        #expect(SearchSection.recentlyAdded.title == "Recently Added")
        #expect(SearchSection.episodes.title == "Episodes")
    }

    @Test func resultsKeepServerOrderDropUnsupportedTypesAndDedupe() throws {
        let container = try SearchFixtures.searchContainer([
            [try SearchFixtures.item("2", "show", "Beta"), try SearchFixtures.item("9", "artist", "Band")],
            [
                try SearchFixtures.item("1", "movie", "Alpha"),
                try SearchFixtures.item("2", "show", "Beta again"),
                try SearchFixtures.item("3", "episode", "Gamma"),
                try SearchFixtures.item("4", "season", "Season 1"),
            ],
        ])
        let results = SearchResults(hubs: container.Hub ?? [])
        #expect(results.ordered.map(\.id) == ["2", "1", "3"])
        #expect(results.ordered.first?.title == "Beta")
    }

    @Test func partsGroupByTypeAndPickTheFirstVisibleAsTopResult() throws {
        let container = try SearchFixtures.searchContainer([[
            try SearchFixtures.item("3", "episode", "E1"),
            try SearchFixtures.item("1", "movie", "M1"),
            try SearchFixtures.item("2", "show", "S1"),
            try SearchFixtures.item("4", "movie", "M2"),
        ]])
        let results = SearchResults(hubs: container.Hub ?? [])

        let all = results.parts(for: .all)
        #expect(all.top?.id == "3")
        #expect(all.movies.map(\.id) == ["1", "4"])
        #expect(all.shows.map(\.id) == ["2"])
        #expect(all.episodes.map(\.id) == ["3"])

        let movies = results.parts(for: .movies)
        #expect(movies.top?.id == "1")
        #expect(movies.shows.isEmpty && movies.episodes.isEmpty)

        let shows = results.parts(for: .shows)
        #expect(shows.top?.id == "2")
    }

    @Test func partsAreEmptyWhenTheScopeHasNoMatches() throws {
        let container = try SearchFixtures.searchContainer([[try SearchFixtures.item("1", "movie", "M1")]])
        let parts = SearchResults(hubs: container.Hub ?? []).parts(for: .episodes)
        #expect(parts.isEmpty)
        #expect(parts == .empty)
        #expect(SearchResults(hubs: []).parts(for: .all).isEmpty)
    }

    @Test func searchItemMetadataAndResultFlag() throws {
        let movie = try SearchFixtures.item("1", "movie", "M")
        #expect(SearchItem.top(movie).metadata?.id == "1")
        #expect(SearchItem.recentlyAdded(movie).metadata?.id == "1")
        #expect(SearchItem.recent("q").metadata == nil)
        #expect(SearchItem.genre(SearchGenre(title: "Drama", sources: [])).metadata == nil)
        #expect(SearchItem.episode(movie).isSearchResult)
        #expect(!SearchItem.recentlyAdded(movie).isSearchResult)
        #expect(!SearchItem.recent("q").isSearchResult)
    }

    @Test func idleContentIsEmptyOnlyWhenEverySectionIs() throws {
        #expect(SearchIdleContent(recents: [], genres: [], recentlyAdded: []).isEmpty)
        #expect(!SearchIdleContent(recents: ["x"], genres: [], recentlyAdded: []).isEmpty)
        let genre = SearchGenre(title: "Drama", sources: [GenreSource(sectionId: "1", key: "5")])
        #expect(!SearchIdleContent(recents: [], genres: [genre], recentlyAdded: []).isEmpty)
        #expect(!SearchIdleContent(recents: [], genres: [], recentlyAdded: [try SearchFixtures.item("1", "movie", "M")]).isEmpty)
    }
}

struct SearchQueryTests {
    @Test func normalisationTrimsWhitespaceAndNewlines() {
        #expect(SearchQuery.normalized("  halo \n") == "halo")
        #expect(SearchQuery.normalized(nil) == "")
        #expect(SearchQuery.normalized("   ") == "")
        #expect(SearchQuery.normalized("a  b") == "a  b")
    }

    @Test func searchesStartAtTwoCharacters() {
        #expect(!SearchQuery.isSearchable(""))
        #expect(!SearchQuery.isSearchable("a"))
        #expect(SearchQuery.isSearchable("ab"))
        #expect(SearchQuery.isSearchable("\u{1F3AC}\u{1F3AC}"))
        #expect(SearchQuery.minimumLength == 2)
    }
}

struct SearchFormatTests {
    @Test func episodeCodeNeedsSeasonAndEpisode() throws {
        #expect(SearchFormat.episodeCode(try SearchFixtures.item("1", "episode", "E", ["parentIndex": 2, "index": 4])) == "S2 E4")
        #expect(SearchFormat.episodeCode(try SearchFixtures.item("1", "episode", "E", ["index": 4])) == nil)
        #expect(SearchFormat.episodeCode(try SearchFixtures.item("1", "episode", "E", ["parentIndex": 2])) == nil)
    }

    @Test func episodeSubtitleJoinsCodeAndTitle() throws {
        let item = try SearchFixtures.item("1", "episode", "Low Tide", ["parentIndex": 2, "index": 4])
        #expect(SearchFormat.episodeSubtitle(item) == "S2 E4 · Low Tide")
        #expect(SearchFormat.episodeSubtitle(try SearchFixtures.item("1", "episode", "Low Tide")) == "Low Tide")
    }

    @Test func typeLineForMovies() throws {
        let item = try SearchFixtures.item("1", "movie", "M", ["year": 1999, "duration": 5_520_000])
        #expect(SearchFormat.typeLine(for: item) == "Movie · 1999 · 1h 32m")
        #expect(SearchFormat.typeLine(for: try SearchFixtures.item("1", "movie", "M")) == "Movie · < 1m")
    }

    @Test func typeLineForShowsPluralisesSeasons() throws {
        #expect(SearchFormat.typeLine(for: try SearchFixtures.item("1", "show", "S", ["year": 2019, "childCount": 1])) == "Show · 2019 · 1 season")
        #expect(SearchFormat.typeLine(for: try SearchFixtures.item("1", "show", "S", ["childCount": 4])) == "Show · 4 seasons")
        #expect(SearchFormat.typeLine(for: try SearchFixtures.item("1", "show", "S", ["childCount": 0])) == "Show")
    }

    @Test func typeLineForEpisodesListsCodeAndShow() throws {
        let item = try SearchFixtures.item("1", "episode", "E", ["parentIndex": 1, "index": 3, "grandparentTitle": "The Show"])
        #expect(SearchFormat.typeLine(for: item) == "Episode · S1 E3 · The Show")
        #expect(SearchFormat.typeLine(for: try SearchFixtures.item("1", "episode", "E")) == "Episode")
    }
}

struct GenrePaletteTests {
    @Test func knownGenresUseTheirFixedSlot() {
        #expect(GenrePalette.pair(for: "Action") == GenrePalette.pairs[0])
        #expect(GenrePalette.pair(for: "SCI-FI") == GenrePalette.pairs[3])
        #expect(GenrePalette.pair(for: "Science Fiction") == GenrePalette.pairs[3])
        #expect(GenrePalette.pair(for: "documentary") == GenrePalette.pairs[7])
    }

    @Test func unknownGenresHashTheUnicodeScalars() {
        let samples: [(String, Int)] = [("Noir", 3), ("Anime", 7), ("Sport", 2), ("Reality", 6), ("Zzz", 6)]
        for (title, slot) in samples {
            #expect(GenrePalette.pair(for: title) == GenrePalette.pairs[slot], "slot for \(title)")
            #expect(GenrePalette.pair(for: title.uppercased()) == GenrePalette.pair(for: title))
        }
    }

    @Test func paletteHasEightGradientPairs() {
        #expect(GenrePalette.pairs.count == 8)
        #expect(GenrePalette.pairs.allSatisfy { $0.start != $0.end })
    }
}

struct SearchHighlightTests {
    private func matched(_ query: String, in text: String) -> [String] {
        SearchHighlight.matchRanges(of: query, in: text).map { (text as NSString).substring(with: $0) }
    }

    @Test func wholeQueryWinsOverWords() {
        #expect(matched("dark knight", in: "The Dark Knight Rises") == ["Dark Knight"])
    }

    @Test func fallsBackToEachWordThatOccurs() {
        #expect(matched("knight dark", in: "The Dark Knight Rises") == ["Knight", "Dark"])
        #expect(matched("knight batman", in: "The Dark Knight Rises") == ["Knight"])
    }

    @Test func ignoresCaseAndDiacritics() {
        #expect(matched("amelie", in: "Amélie") == ["Amélie"])
        #expect(matched("ÉCOLE", in: "Ecole") == ["Ecole"])
    }

    @Test func noMatchYieldsNoRanges() {
        #expect(SearchHighlight.matchRanges(of: "zzz", in: "Alpha").isEmpty)
    }
}

struct SearchCardModelTests {
    @Test func showPosterCountsUnwatchedEpisodes() throws {
        let show = try SearchFixtures.item("1", "show", "The Show", ["thumb": "/t", "year": 2020, "leafCount": 10, "viewedLeafCount": 4])
        let model = SearchPosterModel(item: show)
        #expect(model.title == "The Show" && model.subtitle == "2020" && model.posterPath == "/t")
        #expect(model.unwatchedCount == 6 && model.placeholderIcon == "tv")
        #expect(model.progress == nil && !model.isUnwatched)

        let finished = try SearchFixtures.item("1", "show", "The Show", ["leafCount": 10, "viewedLeafCount": 10])
        #expect(SearchPosterModel(item: finished).unwatchedCount == nil)
    }

    @Test func seasonPosterShowsTheParentShow() throws {
        let season = try SearchFixtures.item("5", "season", "Season 2", ["parentTitle": "The Show", "parentThumb": "/p"])
        let model = SearchPosterModel(item: season)
        #expect(model.title == "The Show" && model.subtitle == "Season 2" && model.posterPath == "/p")
        let bare = try SearchFixtures.item("5", "season", "Season 2", ["thumb": "/own"])
        #expect(SearchPosterModel(item: bare).title == "Season 2")
        #expect(SearchPosterModel(item: bare).posterPath == "/own")
    }

    @Test func episodePosterShowsTheShowWithProgress() throws {
        let episode = try SearchFixtures.item("7", "episode", "Low Tide", [
            "grandparentTitle": "The Show", "grandparentThumb": "/g", "thumb": "/e",
            "parentIndex": 1, "index": 2, "viewOffset": 500, "duration": 1000,
        ])
        let model = SearchPosterModel(item: episode)
        #expect(model.title == "The Show" && model.posterPath == "/g")
        #expect(model.subtitle == "S1 E2 · Low Tide")
        #expect(model.progress == 0.5 && model.isUnwatched)
        let watched = try SearchFixtures.item("7", "episode", "Low Tide", ["viewCount": 1])
        #expect(!SearchPosterModel(item: watched).isUnwatched)
        #expect(SearchPosterModel(item: watched).title == "Low Tide")
    }

    @Test func moviePosterFlagsUnwatchedOnlyWithoutProgress() throws {
        let fresh = SearchPosterModel(item: try SearchFixtures.item("1", "movie", "M", ["year": 1999]))
        #expect(fresh.isUnwatched && fresh.progress == nil && fresh.placeholderIcon == "film" && fresh.subtitle == "1999")
        let started = SearchPosterModel(item: try SearchFixtures.item("1", "movie", "M", ["viewOffset": 250, "duration": 1000]))
        #expect(!started.isUnwatched && started.progress == 0.25)
        let seen = SearchPosterModel(item: try SearchFixtures.item("1", "movie", "M", ["viewCount": 2]))
        #expect(!seen.isUnwatched)
    }

    @Test func topResultUsesTheShowForEpisodesAndHidesPlayForShows() throws {
        let episode = try SearchFixtures.item("7", "episode", "Low Tide", ["grandparentTitle": "The Show", "grandparentThumb": "/g", "thumb": "/e"])
        let top = SearchTopResultModel(item: episode)
        #expect(top.title == "The Show" && top.posterPath == "/g" && top.canPlay && top.placeholderIcon == "tv")
        #expect(top.meta == SearchFormat.typeLine(for: episode))

        let show = SearchTopResultModel(item: try SearchFixtures.item("1", "show", "S"))
        #expect(!show.canPlay && show.placeholderIcon == "tv")
        let movie = SearchTopResultModel(item: try SearchFixtures.item("2", "movie", "M", ["thumb": "/m"]))
        #expect(movie.canPlay && movie.placeholderIcon == "film" && movie.posterPath == "/m" && movie.title == "M")
    }

    @Test func episodeRowPrefersTheEpisodeStillAndHidesEmptyProgress() throws {
        let episode = try SearchFixtures.item("7", "episode", "Low Tide", [
            "grandparentTitle": "The Show", "grandparentThumb": "/g", "thumb": "/e", "parentIndex": 3, "index": 1,
        ])
        let row = SearchEpisodeModel(item: episode)
        #expect(row.thumbPath == "/e" && row.title == "The Show" && row.subtitle == "S3 E1 · Low Tide" && row.progress == nil)
        let noStill = SearchEpisodeModel(item: try SearchFixtures.item("7", "episode", "X", ["grandparentThumb": "/g"]))
        #expect(noStill.thumbPath == "/g")
    }
}

struct SearchItemActionsTests {
    @Test func onlyMoviesAndEpisodesPlay() throws {
        #expect(SearchItemActions.isPlayable(try SearchFixtures.item("1", "movie", "M")))
        #expect(SearchItemActions.isPlayable(try SearchFixtures.item("1", "episode", "E")))
        #expect(!SearchItemActions.isPlayable(try SearchFixtures.item("1", "show", "S")))
        #expect(!SearchItemActions.isPlayable(try SearchFixtures.item("1", "season", "S")))
    }

    @Test func playTitleResumesOnceStarted() throws {
        #expect(SearchItemActions.playTitle(for: try SearchFixtures.item("1", "movie", "M")) == "Play")
        #expect(SearchItemActions.playTitle(for: try SearchFixtures.item("1", "movie", "M", ["viewOffset": 1000])) == "Resume")
    }

    @Test func showKeyComesFromEpisodesAndSeasonsOnly() throws {
        #expect(SearchItemActions.showKey(for: try SearchFixtures.item("1", "episode", "E", ["grandparentRatingKey": "10"])) == "10")
        #expect(SearchItemActions.showKey(for: try SearchFixtures.item("1", "season", "S", ["parentRatingKey": "11"])) == "11")
        #expect(SearchItemActions.showKey(for: try SearchFixtures.item("1", "show", "S")) == nil)
        #expect(SearchItemActions.showKey(for: try SearchFixtures.item("1", "movie", "M", ["grandparentRatingKey": "10"])) == nil)
    }

    @Test func watchedTitleFlips() throws {
        #expect(SearchItemActions.watchedTitle(for: try SearchFixtures.item("1", "movie", "M")) == "Mark Watched")
        #expect(SearchItemActions.watchedTitle(for: try SearchFixtures.item("1", "movie", "M", ["viewCount": 1])) == "Mark Unwatched")
    }

    @Test func watchedTitleFollowsAnExplicitState() {
        #expect(SearchItemActions.watchedTitle(isWatched: false) == "Mark Watched")
        #expect(SearchItemActions.watchedTitle(isWatched: true) == "Mark Unwatched")
    }

    @Test func destinationsFollowTheItemType() throws {
        #expect(SearchDestination(item: try SearchFixtures.item("1", "movie", "M")) == .movie(ratingKey: "1"))
        #expect(SearchDestination(item: try SearchFixtures.item("2", "show", "S")) == .show(ratingKey: "2", initialSeasonKey: nil))
        #expect(SearchDestination(item: try SearchFixtures.item("3", "season", "S", ["parentRatingKey": "2"])) == .show(ratingKey: "2", initialSeasonKey: "3"))
        #expect(SearchDestination(item: try SearchFixtures.item("3", "season", "S")) == .show(ratingKey: "3", initialSeasonKey: "3"))
        let episode = try SearchFixtures.item("4", "episode", "E", ["grandparentRatingKey": "2", "parentRatingKey": "3"])
        #expect(SearchDestination(item: episode) == .episode(ratingKey: "4", showRatingKey: "2", seasonRatingKey: "3"))
        #expect(SearchDestination(item: try SearchFixtures.item("5", "clip", "C")) == .movie(ratingKey: "5"))
    }
}

struct SearchCopyTests {
    @Test func strings() {
        #expect(SearchCopy.noResultsTitle(query: "halo") == "No results for \u{201C}halo\u{201D}")
        #expect(SearchCopy.noResultsHint(scope: .all) == "Check the spelling or try a different search.")
        #expect(SearchCopy.noResultsHint(scope: .movies) == "Try the All scope.")
        #expect(SearchCopy.genreEmptyTitle("Drama") == "No Drama Titles")
        #expect(SearchCopy.genreFailureTitle("Drama") == "Couldn\u{2019}t Load Drama")
    }
}

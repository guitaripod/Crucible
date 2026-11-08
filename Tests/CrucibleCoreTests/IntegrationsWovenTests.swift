import Foundation
import Testing
@testable import CrucibleCore

struct RatingSourceTests {
    @Test func plexImageNamesTellTheSource() {
        #expect(RatingSource(plexImage: "rottentomatoes://image.rating.ripe") == .rottenTomatoesCritics)
        #expect(RatingSource(plexImage: "rottentomatoes://image.rating.rotten") == .rottenTomatoesCritics)
        #expect(RatingSource(plexImage: "rottentomatoes://image.rating.upright") == .rottenTomatoesAudience)
        #expect(RatingSource(plexImage: "imdb://image.rating") == .imdb)
        #expect(RatingSource(plexImage: "themoviedb://image.rating") == .tmdb)
        #expect(RatingSource(plexImage: "something://else") == nil)
        #expect(RatingSource(plexImage: nil) == nil)
    }

    @Test func ratingSortsAreNamedAfterTheirSourceAndAudienceGetsItsOwn() {
        let sources = LibraryRatingSources.Sources(critic: .rottenTomatoesCritics, audience: .imdb)
        let options = LibraryGridKind.movie.sortOptions(sources: sources)
        let rating = options.first { $0.key == "rating:desc" }
        #expect(rating?.title == "Rotten Tomatoes")
        #expect(rating?.source == .rottenTomatoesCritics)
        let audience = options.first { $0.key == "audienceRating:desc" }
        #expect(audience?.title == "IMDb Rating")
        #expect(options.firstIndex { $0.key == "audienceRating:desc" } == options.firstIndex { $0.key == "rating:desc" }.map { $0 + 1 })
        let plain = LibraryGridKind.movie.sortOptions(sources: .init())
        #expect(plain.map(\.key) == LibraryGridKind.movie.sortOptions.map(\.key))
    }

    @Test func aRememberedAudienceSortKeepsItsNameBeforeTheSourcesAreKnown() {
        var options = LibraryGridOptions()
        options.sort = "audienceRating:desc"
        #expect(options.sortTitle(for: .movie) == "Audience Rating")
    }

    @MainActor
    @Test func sourcesAreLearnedFromLoadedTitles() throws {
        let book = LibraryRatingSources()
        let item = try JSONDecoder().decode(PlexMetadata.self, from: Data(#"{"ratingKey":"1","type":"movie","title":"X","ratingImage":"rottentomatoes://image.rating.ripe","audienceRatingImage":"themoviedb://image.rating"}"#.utf8))
        #expect(book.note([item], section: "1"))
        #expect(book.sources(for: "1") == .init(critic: .rottenTomatoesCritics, audience: .tmdb))
        #expect(!book.note([item], section: "1"))
    }
}

struct SeerrSearchTests {
    private func result(_ json: String) -> SeerrSearchResult {
        try! JSONDecoder().decode(SeerrSearchResult.self, from: Data(json.utf8))
    }

    @MainActor
    @Test func searchKeepsOnlyTitlesTheServerLacks() {
        let missing = SeerrTitles.hit(result(#"{"id":1,"mediaType":"movie","title":"Night Train","releaseDate":"2024-03-14"}"#))
        #expect(missing?.year == 2024)
        #expect(missing?.availability == .notRequested)
        let show = SeerrTitles.hit(result(#"{"id":2,"mediaType":"tv","name":"Glass Orchard","mediaInfo":{"status":2}}"#))
        #expect(show?.kind == .tv)
        #expect(show?.availability == .pending)
        #expect(SeerrTitles.hit(result(#"{"id":3,"mediaType":"movie","title":"Halcyon","mediaInfo":{"status":5}}"#)) == nil)
        #expect(SeerrTitles.hit(result(#"{"id":4,"mediaType":"person","name":"Ana Reyes"}"#)) == nil)
    }

    @Test func aHitBecomesATitleCarryingItsTMDBId() {
        let hit = SeerrSearchHit(tmdbID: 42, kind: .tv, title: "Glass Orchard", year: 2023, posterPath: nil, overview: "x", availability: .notRequested)
        #expect(hit.asMetadata.externalIDs.tmdb == 42)
        #expect(hit.asMetadata.mediaType == "show")
    }

    @Test func searchScopeFiltersSeerrHitsAndTheyCountAsResults() {
        var results = SearchResults(hubs: [])
        results.elsewhere = [
            SeerrSearchHit(tmdbID: 1, kind: .movie, title: "A", year: nil, posterPath: nil, overview: nil, availability: .notRequested),
            SeerrSearchHit(tmdbID: 2, kind: .tv, title: "B", year: nil, posterPath: nil, overview: nil, availability: .notRequested),
        ]
        #expect(!results.parts(for: .all).isEmpty)
        #expect(results.parts(for: .movies).elsewhere.map(\.tmdbID) == [1])
        #expect(results.parts(for: .shows).elsewhere.map(\.tmdbID) == [2])
        #expect(results.parts(for: .episodes).isEmpty)
    }
}

struct SettleTests {
    @Test func aQuickAnswerIsTakenAndASlowOneIsLeftRunning() async {
        let quick = Task { 7 }
        #expect(await Settle.value(of: quick, within: .seconds(1)) == 7)
        let slow = Task { () -> Int in
            try? await Task.sleep(for: .milliseconds(400))
            return 9
        }
        #expect(await Settle.value(of: slow, within: .milliseconds(20)) == nil)
        #expect(await slow.value == 9)
    }
}

import Testing
@testable import CrucibleStats

struct StatsPosterTests {
    private func item(type: String?, ratingKey: String = "k1", title: String = "Pilot", show: String? = "Severance", showKey: String? = "s1", thumb: String? = "/e", showThumb: String? = "/s", yearsAgo: Int = 2) -> OnThisDayItem {
        OnThisDayItem(ratingKey: ratingKey, type: type, title: title, grandparentTitle: show, grandparentRatingKey: showKey, thumb: thumb, grandparentThumb: showThumb, yearsAgo: yearsAgo)
    }

    @Test func destinationFollowsTheItemType() {
        #expect(StatsDestination(item(type: "episode")) == .episode(ratingKey: "k1", showRatingKey: "s1"))
        #expect(StatsDestination(item(type: "show")) == .show(ratingKey: "k1"))
        #expect(StatsDestination(item(type: "movie")) == .movie(ratingKey: "k1"))
        #expect(StatsDestination(item(type: nil)) == .movie(ratingKey: "k1"))
    }

    @Test func moviePosterShowsTheRewatchCountOnlyAboveOne() {
        let once = StatsPoster(MovieStat(ratingKey: "m", title: "Heat", thumb: "/t", count: 1, lastViewedAt: 0))
        let thrice = StatsPoster(MovieStat(ratingKey: "m", title: "Heat", thumb: "/t", count: 3, lastViewedAt: 0))
        #expect(once.subtitle == nil)
        #expect(thrice.subtitle == "3× watched")
        #expect(thrice.posterPath == "/t")
        #expect(thrice.placeholderSymbol == "film")
        #expect(thrice.destination == .movie(ratingKey: "m"))
    }

    @Test func onThisDayPosterPrefersTheShowTitleAndSingularYear() {
        let episode = StatsPoster(onThisDay: item(type: "episode", yearsAgo: 1))
        #expect(episode.title == "Severance")
        #expect(episode.subtitle == "1 year ago")
        #expect(episode.placeholderSymbol == "tv")
        let movie = StatsPoster(onThisDay: item(type: "movie", show: nil, thumb: nil, showThumb: nil, yearsAgo: 4))
        #expect(movie.title == "Pilot")
        #expect(movie.subtitle == "4 years ago")
        #expect(movie.posterPath == nil)
        #expect(movie.placeholderSymbol == "film")
    }

    @Test func onThisDayPosterFallsBackToTheShowArtwork() {
        #expect(StatsPoster(onThisDay: item(type: "episode", thumb: nil)).posterPath == "/s")
    }

    @Test func dayPosterStacksEpisodeOverShowAndKeepsMoviesPlain() {
        let episode = StatsPoster(playedOnDay: item(type: "episode"))
        #expect(episode.title == "Severance")
        #expect(episode.subtitle == "Pilot")
        #expect(episode.placeholderSymbol == "tv")
        let movie = StatsPoster(playedOnDay: item(type: "movie"))
        #expect(movie.title == "Pilot")
        #expect(movie.subtitle == nil)
        #expect(movie.placeholderSymbol == "film")
    }
}

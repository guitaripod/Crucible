import Foundation
import Testing
@testable import CrucibleCore

struct UserRatingTests {
    private let server = DetailStubServer()

    @Test func theServerScaleMapsToHalfStars() {
        #expect(UserRating(plexValue: 10)?.stars == 5)
        #expect(UserRating(plexValue: 7)?.stars == 3.5)
        #expect(UserRating(plexValue: 1)?.stars == 0.5)
        #expect(UserRating(plexValue: 8.4)?.halfStars == 8)
    }

    @Test func anUnratedTitleHasNoRating() {
        #expect(UserRating(plexValue: nil) == nil)
        #expect(UserRating(plexValue: 0) == nil)
        #expect(UserRating(plexValue: -1) == nil)
        #expect(UserRating(plexValue: .nan) == nil)
        #expect(UserRating(halfStars: 0) == nil)
        #expect(UserRating(halfStars: 11) == nil)
    }

    @Test func aValueAboveTheScaleIsHeldAtFiveStars() {
        #expect(UserRating(plexValue: 14)?.halfStars == 10)
    }

    @Test func aPositionAlongTheRowPicksTheStepUnderIt() {
        #expect(UserRating(fraction: 0) == nil)
        #expect(UserRating(fraction: 0.04)?.halfStars == 1)
        #expect(UserRating(fraction: 0.1)?.halfStars == 1)
        #expect(UserRating(fraction: 0.11)?.halfStars == 2)
        #expect(UserRating(fraction: 0.5)?.halfStars == 5)
        #expect(UserRating(fraction: 0.99)?.halfStars == 10)
        #expect(UserRating(fraction: 1.7)?.halfStars == 10)
        #expect(UserRating(fraction: -0.3) == nil)
        #expect(UserRating(fraction: .infinity) == nil)
    }

    @Test func steppingMovesByHalfStarsAndStopsAtTheEnds() {
        let three = UserRating(halfStars: 6)
        #expect(three?.stepped(by: 1)?.halfStars == 7)
        #expect(three?.stepped(by: -1)?.halfStars == 5)
        #expect(UserRating(halfStars: 10)?.stepped(by: 1)?.halfStars == 10)
        #expect(UserRating(halfStars: 1)?.stepped(by: -1) == nil)
    }

    @Test func starsSplitIntoWholeAndHalf() throws {
        let rating = try #require(UserRating(halfStars: 7))
        #expect(rating.fullStars == 3)
        #expect(rating.hasHalfStar)
        #expect(!(try #require(UserRating(halfStars: 8))).hasHalfStar)
    }

    @Test func textDropsAnEmptyFraction() throws {
        #expect(try #require(UserRating(halfStars: 8)).text == "4")
        #expect(try #require(UserRating(halfStars: 9)).text == "4.5")
        #expect(UserRatingCopy.detail(for: try #require(UserRating(halfStars: 9))) == "4.5 of 5")
    }

    @Test func theRateButtonSpeaksTheCurrentRating() throws {
        #expect(UserRatingCopy.accessibilityLabel(for: nil) == "Rate")
        #expect(UserRatingCopy.accessibilityLabel(for: try #require(UserRating(halfStars: 9))) == "Your rating, 4.5 out of 5 stars")
    }

    @Test func rateEndpointPutsTheScaleValueForTheKey() throws {
        let endpoint = PlexEndpoint.rate(ratingKey: "42", rating: 7)
        let request = try endpoint.urlRequest(baseURL: URL(string: "http://192.168.1.5:32400")!, token: "tok")
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/:/rate")
        #expect(request.url?.query == "identifier=com.plexapp.plugins.library&key=42&rating=7")
    }

    @Test func clearingRatesWithMinusOne() async throws {
        server.reply(path: "/:/rate")
        try await RatingService.setRating(nil, ratingKey: "9", api: server.client)
        #expect(server.requestedURLs.last?.hasSuffix("rating=-1") == true)
    }

    @Test func ratingSendsTheStepAndDropsTheCachedTitle() async throws {
        let api = server.client
        server.reply(path: "/library/metadata/1", items: [DetailFixtures.item()])
        server.reply(path: "/:/rate")

        _ = try await api.requestContainer(.metadata(ratingKey: "1"))
        try await RatingService.setRating(UserRating(halfStars: 9), ratingKey: "1", api: api)
        #expect(server.requestedURLs.last?.hasSuffix("rating=9") == true)

        _ = try await api.requestContainer(.metadata(ratingKey: "1"))
        #expect(server.requests.filter { $0 == "/library/metadata/1" }.count == 2)
    }

    @Test func aRefusedRatingIsAFailure() async {
        server.reply(path: "/:/rate", status: 404)
        await #expect(throws: APIError.self) {
            try await RatingService.setRating(UserRating(halfStars: 4), ratingKey: "1", api: server.client)
        }
    }

    @Test func theDetailModelShowsTheViewersRatingAsADetail() {
        let rated = MovieDetailModel(item: DetailFixtures.item(["userRating": 9.0]))
        #expect(rated.userRating?.stars == 4.5)
        #expect(rated.facts.first == DetailFact(key: "Your Rating", value: "4.5 of 5"))

        let unrated = MovieDetailModel(item: DetailFixtures.item())
        #expect(unrated.userRating == nil)
        #expect(!unrated.facts.contains { $0.key == "Your Rating" })
    }

    @Test func aShowCarriesItsRatingToo() {
        let show = ShowDetailModel(show: DetailFixtures.item(["type": "show", "userRating": 6]))
        #expect(show.userRating?.stars == 3)
    }

    @Test func theServerSpellingOfARatingDecodesLeniently() throws {
        let text = DetailFixtures.item(["userRating": "8.0"])
        #expect(text.userRating == 8)
        #expect(DetailFixtures.item().userRating == nil)
    }
}

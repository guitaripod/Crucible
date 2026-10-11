import Foundation
import Testing
@testable import CrucibleCore

struct WatchedUnificationTests {
    private let server = DetailStubServer()

    @Test func theTitleNamesTheActionThatFlipsTheCurrentState() {
        #expect(WatchedService.title(isWatched: false) == "Mark Watched")
        #expect(WatchedService.title(isWatched: true) == "Mark Unwatched")
    }

    @Test func everyCopySiteUsesTheSameStrings() throws {
        let unwatched = DetailFixtures.item()
        let watched = DetailFixtures.item(["viewCount": 2])
        #expect(MovieDetailModel(item: unwatched).watchedToggleTitle == WatchedService.title(isWatched: false))
        #expect(MovieDetailModel(item: watched).watchedToggleTitle == WatchedService.title(isWatched: true))
        #expect(HomeMediaRules.watchedToggle(for: unwatched).title == WatchedService.title(isWatched: false))
        #expect(HomeMediaRules.watchedToggle(for: watched).title == WatchedService.title(isWatched: true))
        let actions = LibraryItemAction.grid(for: unwatched, kind: .movie).map(\.title)
        #expect(actions.contains(WatchedService.title(isWatched: false)))
    }

    @Test func aHomeToggleScrobblesAndDropsTheCacheSoDetailShowsTheNewState() async throws {
        let api = server.client
        server.reply(path: "/library/metadata/1", items: [DetailFixtures.item()])
        server.reply(path: "/:/scrobble")
        _ = try await api.requestContainer(.metadata(ratingKey: "1"))
        _ = try await api.requestContainer(.metadata(ratingKey: "1"))
        #expect(server.requests.filter { $0 == "/library/metadata/1" }.count == 1)

        let toggle = HomeMediaRules.watchedToggle(for: DetailFixtures.item())
        try await toggle.perform(using: api)
        #expect(server.requests.last == "/:/scrobble")

        _ = try await api.requestContainer(.metadata(ratingKey: "1"))
        #expect(server.requests.filter { $0 == "/library/metadata/1" }.count == 2)
    }

    @Test func aHomeToggleOfAWatchedTitleUnscrobbles() async throws {
        server.reply(path: "/:/unscrobble")
        let toggle = HomeMediaRules.watchedToggle(for: DetailFixtures.item(["viewCount": 1]))
        try await toggle.perform(using: server.client)
        #expect(server.requests == ["/:/unscrobble"])
    }

    @Test func aFailedHomeToggleThrowsSoTheCallerCanSayWhy() async throws {
        server.failTransport(path: "/:/scrobble")
        await #expect(throws: URLError.self) {
            try await HomeMediaRules.watchedToggle(for: DetailFixtures.item()).perform(using: self.server.client)
        }
    }
}

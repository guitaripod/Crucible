import Foundation
import Testing
@testable import CrucibleCore

@MainActor
struct DetailLoaderTests {
    private let server = DetailStubServer()

    private func seasonLists() {
        server.reply(path: "/library/metadata/show", items: [DetailFixtures.item(["ratingKey": "show", "type": "show", "title": "The Show"])])
        server.reply(path: "/library/metadata/show/children", items: [
            DetailFixtures.season(1, watched: 10, total: 10),
            DetailFixtures.season(2, watched: 3, total: 10),
            DetailFixtures.item(["ratingKey": "extras", "type": "collection", "title": "Extras"]),
        ])
        server.reply(path: "/library/metadata/s1/children", items: [DetailFixtures.episode(1, season: 1, watched: true)])
        server.reply(path: "/library/metadata/s2/children", items: [
            DetailFixtures.episode(1, season: 2, watched: true),
            DetailFixtures.episode(2, season: 2),
        ])
        server.reply(path: "/library/metadata/show/allLeaves", items: [
            DetailFixtures.episode(1, season: 1, watched: true),
            DetailFixtures.episode(1, season: 2, watched: true),
            DetailFixtures.episode(2, season: 2),
            DetailFixtures.item(["ratingKey": "trailer", "type": "clip", "title": "Trailer"]),
        ])
    }

    private func loadShow(initialSeasonKey: String? = nil, selected: String? = nil) async throws -> ShowDetailModel? {
        try await ShowDetailLoader.load(
            api: server.client,
            showRatingKey: "show",
            initialSeasonKey: initialSeasonKey,
            selectedSeasonKey: { selected },
            onShow: { [server] show in server.note("onShow \(show.title)") }
        )
    }

    @Test func movieLoadReturnsTheModelWithItsNavigationContext() async throws {
        server.reply(path: "/library/metadata/m1", items: [DetailFixtures.item(["ratingKey": "m1", "title": "Heat"])])
        let model = try await MovieDetailLoader.load(api: server.client, ratingKey: "m1", showRatingKey: "s", seasonRatingKey: "se")
        #expect(model?.item.title == "Heat")
        #expect(model?.showRatingKey == "s")
        #expect(model?.seasonRatingKey == "se")
    }

    @Test func movieLoadReturnsNilWhenTheServerHasNoMetadata() async throws {
        server.reply(path: "/library/metadata/gone", items: [])
        #expect(try await MovieDetailLoader.load(api: server.client, ratingKey: "gone") == nil)
    }

    @Test func movieLoadThrowsOnFailure() async {
        server.reply(path: "/library/metadata/bad", status: 404)
        await #expect(throws: APIError.self) {
            _ = try await MovieDetailLoader.load(api: server.client, ratingKey: "bad")
        }
    }

    @Test func nextEpisodeLookupStaysInTheSeason() async throws {
        server.reply(path: "/library/metadata/s1/children", items: [DetailFixtures.episode(1), DetailFixtures.episode(2)])
        let next = try await MovieDetailLoader.nextEpisode(after: "e11", inSeason: "s1", api: server.client)
        #expect(next?.id == "e12")
        let last = try await MovieDetailLoader.nextEpisode(after: "e12", inSeason: "s1", api: server.client)
        #expect(last == nil)
    }

    @Test func showLoadPicksTheFirstUnwatchedSeasonAndItsEpisodes() async throws {
        seasonLists()
        let model = try #require(await loadShow())
        #expect(model.show.title == "The Show")
        #expect(model.seasons.map(\.id) == ["s1", "s2"])
        #expect(model.selectedSeasonKey == "s2")
        #expect(model.episodes.map(\.id) == ["e21", "e22"])
        #expect(model.allEpisodes.map(\.id) == ["e11", "e21", "e22"])
        #expect(model.upNext?.episode.id == "e22")
        #expect(model.upNext?.kind == .next)
    }

    @Test func showLoadHonoursTheCallersSeasonAndThePickedSeason() async throws {
        seasonLists()
        let preferred = try #require(await loadShow(initialSeasonKey: "s1"))
        #expect(preferred.selectedSeasonKey == "s1")
        #expect(preferred.episodes.map(\.id) == ["e11"])

        let picked = try #require(await loadShow(initialSeasonKey: "s1", selected: "s2"))
        #expect(picked.selectedSeasonKey == "s2")

        let stale = try #require(await loadShow(initialSeasonKey: nil, selected: "gone"))
        #expect(stale.selectedSeasonKey == "s2")
    }

    @Test func showArrivesBeforeTheSeasonsAreRequested() async throws {
        seasonLists()
        _ = try await loadShow()
        let log = server.requests
        let arrived = try #require(log.firstIndex(of: "onShow The Show"))
        let metadata = try #require(log.firstIndex(of: "/library/metadata/show"))
        let seasons = try #require(log.firstIndex(of: "/library/metadata/show/children"))
        #expect(metadata < arrived)
        #expect(arrived < seasons)
    }

    @Test func showLoadSurvivesAFailingLeavesRequest() async throws {
        seasonLists()
        server.reply(path: "/library/metadata/show/allLeaves", status: 404)
        let model = try #require(await loadShow())
        #expect(model.allEpisodes.isEmpty)
        #expect(model.episodes.map(\.id) == ["e21", "e22"])
        #expect(model.upNext?.episode.id == "e22")
    }

    @Test func showLoadSurvivesAFailingSeasonRequest() async throws {
        seasonLists()
        server.reply(path: "/library/metadata/s2/children", status: 404)
        let model = try #require(await loadShow())
        #expect(model.selectedSeasonKey == "s2")
        #expect(model.episodes.isEmpty)
        #expect(model.allEpisodes.count == 3)
    }

    @Test func showLoadWithoutSeasonsHasNoSelection() async throws {
        server.reply(path: "/library/metadata/show", items: [DetailFixtures.item(["ratingKey": "show", "type": "show"])])
        server.reply(path: "/library/metadata/show/children", items: [])
        let model = try #require(await loadShow())
        #expect(model.seasons.isEmpty)
        #expect(model.selectedSeasonKey == nil)
        #expect(model.upNext == nil)
    }

    @Test func showLoadReturnsNilWithoutNotifyingWhenTheShowIsGone() async throws {
        server.reply(path: "/library/metadata/show", items: [])
        #expect(try await loadShow() == nil)
        #expect(!server.requests.contains { $0.hasPrefix("onShow") })
    }

    @Test func showLoadThrowsAfterNotifyingWhenTheSeasonsFail() async {
        server.reply(path: "/library/metadata/show", items: [DetailFixtures.item(["ratingKey": "show", "type": "show"])])
        server.reply(path: "/library/metadata/show/children", status: 404)
        await #expect(throws: APIError.self) {
            _ = try await loadShow()
        }
        #expect(server.requests.contains { $0.hasPrefix("onShow") })
    }

    @Test func seasonEpisodesFallBackToNothingOnFailure() async {
        server.reply(path: "/library/metadata/s1/children", items: [DetailFixtures.episode(1)])
        #expect(await ShowDetailLoader.episodes(inSeason: "s1", api: server.client)?.map(\.id) == ["e11"])
        #expect(await ShowDetailLoader.episodes(inSeason: "missing", api: server.client)?.isEmpty == true)
    }

    @Test func cancelledLoadsThrow() async {
        seasonLists()
        let client = server.client
        let task = Task { () -> ShowDetailModel? in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ShowDetailLoader.load(
                api: client,
                showRatingKey: "show",
                initialSeasonKey: nil,
                selectedSeasonKey: { nil },
                onShow: { _ in }
            )
        }
        let result = await task.result
        #expect(throws: (any Error).self) { try result.get() }
    }
}

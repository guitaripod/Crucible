import Foundation
import Testing
@testable import CrucibleCore

struct DetailWatchedServiceTests {
    private let server = DetailStubServer()

    private func metadataHits() -> Int {
        server.requests.filter { $0 == "/library/metadata/1" }.count
    }

    @Test func markingWatchedScrobblesAndDropsTheCache() async throws {
        let api = server.client
        server.reply(path: "/library/metadata/1", items: [DetailFixtures.item()])
        server.reply(path: "/:/scrobble")

        _ = try await api.requestContainer(.metadata(ratingKey: "1"))
        _ = try await api.requestContainer(.metadata(ratingKey: "1"))
        #expect(metadataHits() == 1)

        try await WatchedService.setWatched(true, ratingKey: "1", api: api)
        #expect(server.requests.last == "/:/scrobble")

        _ = try await api.requestContainer(.metadata(ratingKey: "1"))
        #expect(metadataHits() == 2)
    }

    @Test func markingUnwatchedUnscrobbles() async throws {
        let api = server.client
        server.reply(path: "/:/unscrobble")
        try await WatchedService.setWatched(false, ratingKey: "1", api: api)
        #expect(server.requests == ["/:/unscrobble"])
    }

    @Test func aFailedRequestRethrowsAndKeepsTheCache() async throws {
        let api = server.client
        server.reply(path: "/library/metadata/1", items: [DetailFixtures.item()])
        _ = try await api.requestContainer(.metadata(ratingKey: "1"))

        server.failTransport(path: "/:/scrobble")
        await #expect(throws: URLError.self) {
            try await WatchedService.setWatched(true, ratingKey: "1", api: api)
        }

        _ = try await api.requestContainer(.metadata(ratingKey: "1"))
        #expect(metadataHits() == 1)
    }
}

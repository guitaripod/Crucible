@testable import CrucibleCore
import Foundation
import Testing
@testable import CrucibleDemo

/// The demo's stand-in Trakt, reached through the app's own Trakt client with every request sent to the demo's address.
struct DemoTraktTests {
    private func client(_ demo: DemoHarness) async -> TraktClient {
        let base = demo.base
        let transport = TraktTransport { request in
            var request = request
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            components.scheme = base.scheme
            components.host = base.host
            components.port = base.port
            request.url = components.url
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, response as! HTTPURLResponse)
        }
        let store = TraktTokenStore(keychain: .memory(), owner: { "demo" })
        await store.save(TraktToken(accessToken: "demo-trakt", refreshToken: "r", expiresIn: 604_800, createdAt: Int(Date().timeIntervalSince1970)))
        return TraktClient(transport: transport, tokens: store, sleep: { _ in }, clientID: { "crucible-demo" })
    }

    @MainActor
    private func resolver(_ client: TraktClient) -> TraktResolver {
        let lookup = TraktResolver.Lookup(
            search: { id, kind in try await client.send(.lookup(id, kind: kind), as: [TraktSearchResult].self) },
            episode: { show, season, number in try await client.send(.episode(showID: show, season: season, number: number), as: TraktEpisode.self) },
            plexItem: { key, api in try await api.requestContainer(.metadata(ratingKey: key)).Metadata?.first }
        )
        return TraktResolver(lookup: lookup, storage: nil)
    }

    @Test func theDeviceCodeIsApprovedOnTheSecondAsk() async throws {
        try await withDemo { demo in
            let client = await client(demo)
            let code = try await client.send(.deviceCode, as: TraktDeviceCode.self)
            #expect(code.userCode == "CRUC1BLE")
            #expect(try await client.pollDeviceToken(code.deviceCode) == .pending)
            guard case .approved(let token) = try await client.pollDeviceToken(code.deviceCode) else {
                Issue.record("expected approval")
                return
            }
            #expect(token.accessToken == "demo-trakt")
            let settings = try await client.send(.userSettings, as: TraktUserSettings.self)
            #expect(settings.user.username == "demo")
        }
    }

    @Test func everyKindOfTitleMatchesItsTraktItem() async throws {
        try await withDemo { demo in
            let resolver = await resolver(await client(demo))
            let movie = await resolver.resolve(ratingKey: "1001", server: "demo", api: demo.api)
            #expect(movie.target?.kind == .movie)
            #expect(movie.target?.ids.trakt == 1001)
            let episode = await resolver.resolve(ratingKey: "4012", server: "demo", api: demo.api)
            #expect(episode.target?.kind == .episode)
            #expect(episode.target?.ids.trakt == 4012)
            #expect(episode.target?.showIDs?.trakt == 2001)
            #expect(episode.target?.season == 2)
            #expect(episode.target?.number == 4)
            let lanterns = await resolver.resolve(ratingKey: "2005", server: "demo", api: demo.api)
            #expect(lanterns.target?.ids.tvdb == 9_100_005)
        }
    }

    @Test func aMovieHasEveryScoreAndAnEpisodeHasItsOwn() async throws {
        try await withDemo { demo in
            let client = await client(demo)
            let resolver = await resolver(client)
            let movie = try #require(await resolver.target(ratingKey: "1001", server: "demo", api: demo.api))
            let endpoint = try #require(await TraktScores.ratingsEndpoint(for: movie))
            let scores = try await client.send(endpoint, as: TraktRatings.self).scores
            #expect(scores.map(\.source) == [.trakt, .imdb, .rottenTomatoes, .metascore, .letterboxd, .tmdb])
            let episode = try #require(await resolver.target(ratingKey: "4012", server: "demo", api: demo.api))
            let episodeEndpoint = try #require(await TraktScores.ratingsEndpoint(for: episode))
            let episodeScores = try await client.send(episodeEndpoint, as: TraktRatings.self).scores
            #expect(episodeScores.first?.source == .trakt)
        }
    }

    @Test func aFinishedScrobbleIsRecordedAndACheckInAccepted() async throws {
        try await withDemo { demo in
            let client = await client(demo)
            let ids = TraktIDs(trakt: 1001)
            let stop = try await client.send(.scrobble(.stop, kind: .movie, ids: ids, progress: 96), as: TraktScrobbleResult.self)
            #expect(stop.action == "scrobble")
            let pause = try await client.send(.scrobble(.stop, kind: .movie, ids: ids, progress: 40), as: TraktScrobbleResult.self)
            #expect(pause.action == "stop")
            try await client.sendVoid(.checkin(kind: .movie, ids: ids))
            try await client.sendVoid(.cancelCheckin)
        }
    }
}

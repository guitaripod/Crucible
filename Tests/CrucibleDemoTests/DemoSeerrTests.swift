@testable import CrucibleCore
import Foundation
import Testing
@testable import CrucibleDemo

/// The demo's stand-in Seerr, reached through the app's own Seerr client at the address the demo serves it under.
struct DemoSeerrTests {
    private func client(_ demo: DemoHarness) -> (SeerrClient, URL) {
        let address = demo.base.appendingPathComponent("seerr")
        return (SeerrClient(transport: .live, vault: .memory(), plexToken: { "demo-plex" }), address)
    }

    @Test func itAnswersAsASeerrForPlexAndSignsInWithAPlexToken() async throws {
        try await withDemo { demo in
            let (client, address) = client(demo)
            let settings = try await client.probe(address)
            #expect(settings.servesPlex)
            #expect(settings.partialRequestsEnabled == true)
            await client.use(SeerrTarget(address: address, auth: .plex, secretKey: "demo"))
            let user = try await client.signIn()
            #expect(user.rights.managesRequests)
            let again = try await client.send(.me, as: SeerrUser.self)
            #expect(again.id == user.id)
        }
    }

    @Test func aRequestedWatchlistTitleStartsDownloadingForTheOwner() async throws {
        try await withDemo { demo in
            let (client, address) = client(demo)
            await client.use(SeerrTarget(address: address, auth: .plex, secretKey: "demo"))
            try await client.signIn()
            let before = try await client.send(.movie(tmdbID: 980_001), as: SeerrTitleDetails.self)
            #expect(SeerrAvailability(media: before.mediaInfo) == .notRequested)
            try await client.sendVoid(.createRequest(kind: .movie, tmdbID: 980_001, tvdbID: nil, seasons: nil))
            let after = try await client.send(.movie(tmdbID: 980_001), as: SeerrTitleDetails.self)
            guard case .downloading(let progress, let eta) = SeerrAvailability(media: after.mediaInfo) else {
                Issue.record("expected a download")
                return
            }
            #expect(progress == 0.35)
            #expect(eta != nil)
            await #expect(throws: SeerrError.alreadyRequested) {
                try await client.sendVoid(.createRequest(kind: .movie, tmdbID: 980_001, tvdbID: nil, seasons: nil))
            }
        }
    }

    @Test func aLibraryShowIsMissingOneSeasonAndEveryCatalogueTitleHasATMDBId() async throws {
        try await withDemo { demo in
            let (client, address) = client(demo)
            await client.use(SeerrTarget(address: address, auth: .plex, secretKey: "demo"))
            try await client.signIn()
            let show = try #require(try await demo.api.requestContainer(.metadata(ratingKey: "2001")).Metadata?.first)
            let tmdb = try #require(show.externalIDs.tmdb)
            let details = try await client.send(.show(tmdbID: tmdb), as: SeerrTitleDetails.self)
            let state = SeerrTitleState(details: details, kind: .tv, viewerID: 1)
            #expect(state.requestableSeasons == [5])
            #expect(state.availability == .partiallyAvailable)
            #expect(state.ratingKey == "2001")
            let lanterns = try #require(try await demo.api.requestContainer(.metadata(ratingKey: "2005")).Metadata?.first)
            let lanternsDetails = try await client.send(.show(tmdbID: try #require(lanterns.externalIDs.tmdb)), as: SeerrTitleDetails.self)
            #expect(lanternsDetails.mediaInfo?.ratingKey == "2005")
        }
    }

    @Test func theOwnerSeesSamsPendingRequestAndApprovesIt() async throws {
        try await withDemo { demo in
            let (client, address) = client(demo)
            await client.use(SeerrTarget(address: address, auth: .plex, secretKey: "demo"))
            try await client.signIn()
            let pending = try await client.send(.requests(take: 10, skip: 0, filter: "pending", requestedBy: nil), as: SeerrPage<SeerrRequest>.self)
            let sams = try #require(pending.results.first)
            #expect(sams.requestedBy?.name == "Sam")
            try await client.sendVoid(.moderate(id: sams.id, approve: true))
            let after = try await client.send(.requests(take: 10, skip: 0, filter: "pending", requestedBy: nil), as: SeerrPage<SeerrRequest>.self)
            #expect(after.results.isEmpty)
            let mine = try await client.send(.requests(take: 10, skip: 0, filter: "all", requestedBy: 1), as: SeerrPage<SeerrRequest>.self)
            #expect(mine.results.allSatisfy { $0.requestedBy?.id == 1 })
            #expect(mine.results.contains { SeerrRequests.availability(of: $0) == .available && $0.media?.ratingKey == "1003" })
        }
    }

    @Test func aTitleTheServerDoesNotHaveShowsItsOwnPoster() async throws {
        try await withDemo { demo in
            let (client, address) = client(demo)
            await client.use(SeerrTarget(address: address, auth: .plex, secretKey: "demo"))
            try await client.signIn()
            let details = try await client.send(.show(tmdbID: 980_002), as: SeerrTitleDetails.self)
            #expect(details.posterPath == "/remote/980002.jpg")
            let poster = try #require(SeerrImage.poster(details.posterPath, base: address))
            let (proxied, proxiedResponse) = try await URLSession.shared.data(from: poster)
            #expect((proxiedResponse as? HTTPURLResponse)?.statusCode == 200)
            #expect(proxied.starts(with: [0xFF, 0xD8]))
            let (_, watchlist) = try await demo.get("/remote/980002.jpg")
            #expect(watchlist.statusCode == 200)
            let (_, unknown) = try await demo.get("/remote/123.jpg")
            #expect(unknown.statusCode == 404)
        }
    }

    @Test func plexsCatalogueKnowsTheWatchlistTitlesTheServerDoesNotHave() async throws {
        try await withDemo { demo in
            let (data, response) = try await demo.get("/library/metadata/demo-glass-orchard")
            #expect(response.statusCode == 200)
            let entry = try #require(try JSONDecoder().decode(PlexResponse.self, from: data).MediaContainer.Metadata?.first)
            #expect(entry.externalIDs.tmdb == 980_002)
            #expect(entry.mediaType == "show")
        }
    }
}

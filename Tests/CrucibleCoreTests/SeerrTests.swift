import Foundation
import Testing
@testable import CrucibleCore

/// A scripted Seerr: answers each request with the next reply queued for its path and records every request it saw.
final class SeerrScript: @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: String
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private var replies: [String: [Reply]] = [:]
    private(set) var requests: [URLRequest] = []

    func queue(_ path: String, _ status: Int, _ body: String = "{}", headers: [String: String] = [:]) {
        lock.withLock { replies[path, default: []].append(Reply(status: status, body: body, headers: headers)) }
    }

    var transport: SeerrTransport {
        SeerrTransport { [self] request in
            let path = request.url?.path ?? ""
            let reply: Reply = lock.withLock {
                requests.append(request)
                guard var queued = replies[path], !queued.isEmpty else { return Reply(status: 404, body: "{}") }
                let next = queued.removeFirst()
                replies[path] = queued
                return next
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
            return (Data(reply.body.utf8), response)
        }
    }

    func paths() -> [String] { lock.withLock { requests.compactMap { $0.url?.path } } }
    func request(_ index: Int) -> URLRequest { lock.withLock { requests[index] } }

    func json(at index: Int) -> [String: Any]? {
        let body = lock.withLock { requests[index].httpBody }
        return body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

enum SeerrFixtures {
    static let base = URL(string: "http://10.0.0.5:5055")!
    static let user = #"{"id":7,"displayName":"Robin","permissions":32,"email":"r@example.com","createdAt":"x","updatedAt":"x"}"#

    static func target(_ auth: SeerrTarget.Auth = .plex, base: URL = base) -> SeerrTarget {
        SeerrTarget(address: base, auth: auth, secretKey: "seerr.test")
    }

    static func client(_ script: SeerrScript, vault: SeerrVault = .memory(), token: String? = "plex-token") -> SeerrClient {
        SeerrClient(transport: script.transport, vault: vault, plexToken: { token }, isAwayFromHome: { false })
    }

    static func details(_ json: String) -> SeerrTitleDetails {
        try! JSONDecoder().decode(SeerrTitleDetails.self, from: Data(json.utf8))
    }
}

struct SeerrDiscoveryTests {
    @Test func typedHostGetsSeerrPortFirstOnTheHomeNetwork() {
        let addresses = SeerrDiscovery.addresses(from: " 192.168.1.20 ").map(\.absoluteString)
        #expect(addresses == ["http://192.168.1.20:5055", "http://192.168.1.20", "https://192.168.1.20"])
    }

    @Test func typedDomainTriesHTTPSFirst() {
        let addresses = SeerrDiscovery.addresses(from: "requests.example.com").map(\.absoluteString)
        #expect(addresses.first == "https://requests.example.com")
        #expect(addresses.contains("http://requests.example.com:5055"))
    }

    @Test func typedAddressKeepsItsPortSchemeAndPathButDropsSeerrPages() {
        #expect(SeerrDiscovery.addresses(from: "nas.lan:8055").map(\.absoluteString) == ["http://nas.lan:8055"])
        #expect(SeerrDiscovery.addresses(from: "https://box.example.com/seerr/api/v1/").map(\.absoluteString) == ["https://box.example.com/seerr"])
        #expect(SeerrDiscovery.addresses(from: "http://10.0.0.2/requests").map(\.absoluteString) == ["http://10.0.0.2", "http://10.0.0.2:5055"])
        #expect(SeerrDiscovery.addresses(from: "   ").isEmpty)
    }

    @Test func candidatesAreSeerrsPortOnTheServersHomeAddresses() {
        let routes = [
            URL(string: "https://192-168-1-20.0123abcd.plex.direct:32400")!,
            URL(string: "http://192.168.1.20:32400")!,
            URL(string: "https://84-12-3-4.0123abcd.plex.direct:32400")!,
            URL(string: "https://relay.plex.tv:443")!,
            URL(string: "http://nas.local:32400")!,
            URL(string: "http://100.80.1.2:32400")!,
        ]
        let candidates = SeerrDiscovery.candidates(serverRoutes: routes).map(\.absoluteString)
        #expect(candidates == ["http://192.168.1.20:5055", "http://nas.local:5055", "http://100.80.1.2:5055"])
    }

    @Test func displayAddressIsHostPortAndPath() {
        #expect(SeerrDiscovery.displayAddress(URL(string: "http://10.0.0.5:5055")!) == "10.0.0.5:5055")
        #expect(SeerrDiscovery.displayAddress(URL(string: "https://box.example.com/seerr")!) == "box.example.com/seerr")
    }
}

struct SeerrEndpointTests {
    @Test func routesSitUnderTheAddressPath() {
        let base = URL(string: "https://box.example.com/seerr")!
        #expect(SeerrEndpoint.movie(tmdbID: 12).url(base: base)?.absoluteString == "https://box.example.com/seerr/api/v1/movie/12")
        #expect(SeerrEndpoint.moderate(id: 4, approve: false).url(base: base)?.path == "/seerr/api/v1/request/4/decline")
        let list = SeerrEndpoint.requests(take: 10, skip: 0, filter: "pending", requestedBy: 3).url(base: base)!
        let items = URLComponents(url: list, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.contains(URLQueryItem(name: "requestedBy", value: "3")))
        #expect(items.contains(URLQueryItem(name: "filter", value: "pending")))
    }

    @Test func showRequestsAskForSeasonsOrAll() throws {
        let some = try JSONSerialization.jsonObject(with: SeerrEndpoint.createRequest(kind: .tv, tmdbID: 5, tvdbID: 9, seasons: [2, 3]).body!) as! [String: Any]
        #expect(some["seasons"] as? [Int] == [2, 3])
        #expect(some["tvdbId"] as? Int == 9)
        let all = try JSONSerialization.jsonObject(with: SeerrEndpoint.createRequest(kind: .tv, tmdbID: 5, tvdbID: nil, seasons: nil).body!) as! [String: Any]
        #expect(all["seasons"] as? String == "all")
        let movie = try JSONSerialization.jsonObject(with: SeerrEndpoint.createRequest(kind: .movie, tmdbID: 5, tvdbID: nil, seasons: nil).body!) as! [String: Any]
        #expect(movie["seasons"] == nil)
        #expect(movie["mediaType"] as? String == "movie")
    }

    @Test func artworkGoesThroughSeerrsImageProxyOnly() {
        #expect(SeerrImage.poster("/abc.jpg", base: SeerrFixtures.base)?.absoluteString == "http://10.0.0.5:5055/imageproxy/tmdb/t/p/w342/abc.jpg")
        #expect(SeerrImage.poster("https://evil.example/x.jpg", base: SeerrFixtures.base) == nil)
        #expect(SeerrImage.poster(nil, base: SeerrFixtures.base) == nil)
    }
}

struct SeerrStateTests {
    @Test func availabilityPrefersARunningDownload() {
        let media = SeerrMediaInfo(status: 3, downloadStatus: [SeerrDownload(size: 100, sizeLeft: 25), SeerrDownload(size: 100, sizeLeft: 75)])
        guard case .downloading(let progress, _) = SeerrAvailability(media: media) else { Issue.record("not downloading"); return }
        #expect(progress == 0.5)
    }

    @Test func availabilityFollowsStatusThenTheLatestRequest() {
        #expect(SeerrAvailability(media: nil) == .notRequested)
        #expect(SeerrAvailability(media: SeerrMediaInfo(status: 5)) == .available)
        #expect(SeerrAvailability(media: SeerrMediaInfo(status: 2)) == .pending)
        #expect(SeerrAvailability(media: SeerrMediaInfo(status: 3)) == .approved)
        #expect(SeerrAvailability(media: SeerrMediaInfo(status: 3, requests: [SeerrRequest(id: 1, status: 4)])) == .failed)
        #expect(SeerrAvailability(media: SeerrMediaInfo(status: 1, requests: [SeerrRequest(id: 1, status: 1), SeerrRequest(id: 2, status: 3)])) == .declined)
        #expect(SeerrAvailability(media: SeerrMediaInfo(status: 7)) == .notRequested)
        #expect(SeerrAvailability(media: SeerrMediaInfo(status: 6)) == .blocklisted)
    }

    @Test func showSeasonsSayWhatIsMissingAndWhatIsOnItsWay() {
        let details = SeerrFixtures.details(#"""
        {"id":5,"name":"Glass Orchard","seasons":[{"seasonNumber":0},{"seasonNumber":1},{"seasonNumber":2},{"seasonNumber":3},{"seasonNumber":4}],
         "mediaInfo":{"status":4,"seasons":[{"seasonNumber":1,"status":5},{"seasonNumber":2,"status":3}],
          "requests":[{"id":9,"status":1,"seasons":[{"seasonNumber":3}],"requestedBy":{"id":7}},{"id":8,"status":3,"seasons":[{"seasonNumber":4}],"requestedBy":{"id":7}}]}}
        """#)
        let state = SeerrTitleState(details: details, kind: .tv, viewerID: 7)
        #expect(state.seasons.map(\.number) == [1, 2, 3, 4])
        #expect(state.seasons.map(\.status) == [.available, .processing, .requested, .missing])
        #expect(state.requestableSeasons == [4])
        #expect(state.ownPendingRequest?.id == 9)
        #expect(state.canRequest(with: [.request]))
        #expect(!state.canRequest(with: [.requestMovie]))
    }

    @Test func aMovieCanBeRequestedOnlyWhileNobodyHas() {
        let fresh = SeerrTitleState(details: SeerrFixtures.details(#"{"id":1,"title":"Halcyon","releaseDate":"2021-05-01"}"#), kind: .movie, viewerID: 7)
        #expect(fresh.canRequest(with: [.requestMovie]))
        #expect(fresh.year == 2021)
        let asked = SeerrTitleState(details: SeerrFixtures.details(#"{"id":1,"title":"Halcyon","mediaInfo":{"status":2,"ratingKey":"55"}}"#), kind: .movie, viewerID: 7)
        #expect(!asked.canRequest(with: [.admin]))
        #expect(asked.ratingKey == "55")
    }

    @Test func manageRequestsIsListedOnlyForWhoeverApprovesRequests() {
        #expect(!ProFeature.listed(isTV: false).contains(.manageRequests))
        #expect(!ProFeature.listed(isTV: true).contains(.manageRequests))
        #expect(ProFeature.listed(isTV: false, includingRequests: true).last == .manageRequests)
        #expect(ProFeature.listed(isTV: true, includingRequests: true).contains(.topShelf))
    }

    @Test func permissionsReadSeerrsBits() {
        let admin = SeerrPermissions(rawValue: 2)
        #expect(admin.canRequest(.tv) && admin.autoApproves(.movie) && admin.managesRequests)
        let viewer = SeerrPermissions(rawValue: 32)
        #expect(viewer.canRequest(.movie) && !viewer.autoApproves(.movie) && !viewer.managesRequests)
        let tvOnly = SeerrPermissions(rawValue: 524_288 | 512)
        #expect(tvOnly.canRequest(.tv) && !tvOnly.canRequest(.movie) && tvOnly.autoApproves(.tv))
    }

    @Test func requestEntriesLabelTheirSeasons() {
        func entry(_ seasons: [Int]) -> SeerrRequestEntry {
            SeerrRequestEntry(
                request: SeerrRequest(id: 1, status: 2, type: "tv", seasons: seasons.map { SeerrRequestSeason(seasonNumber: $0, status: 2) }),
                title: "X", year: nil, posterPath: nil, availability: .approved, isMine: true
            )
        }
        #expect(entry([2]).seasonsLabel == "Season 2")
        #expect(entry([3, 1, 2]).seasonsLabel == "Seasons 1–3")
        #expect(entry([1, 4]).seasonsLabel == "2 seasons")
    }

    @Test func aRequestsOwnRefusalComesBeforeItsTitlesState() {
        #expect(SeerrRequests.availability(of: SeerrRequest(id: 1, status: 3, media: SeerrMediaInfo(status: 5))) == .declined)
        #expect(SeerrRequests.availability(of: SeerrRequest(id: 1, status: 2, media: SeerrMediaInfo(status: 1))) == .approved)
        #expect(SeerrRequests.availability(of: SeerrRequest(id: 1, status: 5, media: SeerrMediaInfo(status: 5))) == .available)
    }
}

struct SeerrClientTests {
    @Test func signingInWithPlexKeepsTheSessionCookieForLaterCalls() async throws {
        let script = SeerrScript()
        let vault = SeerrVault.memory()
        script.queue("/api/v1/auth/plex", 200, SeerrFixtures.user, headers: ["Set-Cookie": "connect.sid=s%3Aabc; Path=/; HttpOnly"])
        script.queue("/api/v1/auth/me", 200, SeerrFixtures.user)
        let client = SeerrFixtures.client(script, vault: vault)
        await client.use(SeerrFixtures.target())
        let user = try await client.signIn()
        #expect(user.name == "Robin")
        #expect(script.json(at: 0)?["authToken"] as? String == "plex-token")
        _ = try await client.send(.me, as: SeerrUser.self)
        #expect(script.request(1).value(forHTTPHeaderField: "Cookie") == "connect.sid=s%3Aabc")
        #expect(vault.load("seerr.test.session") == "s%3Aabc")
    }

    @Test func aSavedSessionComesBackWithTheTarget() async throws {
        let script = SeerrScript()
        let vault = SeerrVault.memory()
        vault.save("seerr.test.session", "saved")
        script.queue("/api/v1/auth/me", 200, SeerrFixtures.user)
        let client = SeerrFixtures.client(script, vault: vault)
        await client.use(SeerrFixtures.target())
        _ = try await client.send(.me, as: SeerrUser.self)
        #expect(script.request(0).value(forHTTPHeaderField: "Cookie") == "connect.sid=saved")
    }

    @Test func anExpiredSessionSignsInAgainOnceWithThePlexToken() async throws {
        let script = SeerrScript()
        script.queue("/api/v1/request", 403, #"{"status":403,"error":"You do not have permission to access this endpoint"}"#)
        script.queue("/api/v1/auth/plex", 200, SeerrFixtures.user, headers: ["Set-Cookie": "connect.sid=fresh; Path=/"])
        script.queue("/api/v1/request", 200, #"{"pageInfo":{"results":0},"results":[]}"#)
        let client = SeerrFixtures.client(script)
        await client.use(SeerrFixtures.target())
        let page = try await client.send(.requests(take: 5, skip: 0, filter: "all", requestedBy: 7), as: SeerrPage<SeerrRequest>.self)
        #expect(page.results.isEmpty)
        #expect(script.paths() == ["/api/v1/request", "/api/v1/auth/plex", "/api/v1/request"])
        #expect(script.request(2).value(forHTTPHeaderField: "Cookie") == "connect.sid=fresh")
    }

    @Test func aRefusedPlexAccountMeansSignedOut() async {
        let script = SeerrScript()
        script.queue("/api/v1/auth/me", 403, "{}")
        script.queue("/api/v1/auth/plex", 403, #"{"message":"Access denied."}"#)
        let client = SeerrFixtures.client(script)
        await client.use(SeerrFixtures.target())
        await #expect(throws: SeerrError.signedOut) { _ = try await client.send(.me, as: SeerrUser.self) }
    }

    @Test func crossSiteProtectionIsAnsweredWithItsToken() async throws {
        let script = SeerrScript()
        script.queue("/api/v1/request", 403, #"{"message":"invalid csrf token"}"#)
        script.queue("/api/v1/status", 200, #"{"version":"3.5.1"}"#, headers: ["Set-Cookie": "XSRF-TOKEN=tok123; Path=/"])
        script.queue("/api/v1/request", 201, #"{"id":3,"status":1}"#)
        let client = SeerrFixtures.client(script)
        await client.use(SeerrFixtures.target(.apiKey))
        try await client.sendVoid(.createRequest(kind: .movie, tmdbID: 1, tvdbID: nil, seasons: nil))
        #expect(script.request(2).value(forHTTPHeaderField: "X-XSRF-TOKEN") == "tok123")
        #expect(script.request(2).value(forHTTPHeaderField: "Cookie")?.contains("XSRF-TOKEN=tok123") == true)
    }

    @Test func anAPIKeyIsSentAndAWrongOneIsNamed() async {
        let script = SeerrScript()
        let vault = SeerrVault.memory()
        script.queue("/api/v1/auth/me", 403, "{}")
        let client = SeerrFixtures.client(script, vault: vault)
        let target = SeerrFixtures.target(.apiKey)
        await client.use(target)
        await client.saveAPIKey("key-1", for: target)
        await #expect(throws: SeerrError.invalidAPIKey) { try await client.signIn() }
        #expect(script.request(0).value(forHTTPHeaderField: "X-Api-Key") == "key-1")
    }

    @Test func refusalsAreReadFromStatusAndMessage() {
        let create = SeerrEndpoint.createRequest(kind: .movie, tmdbID: 1, tvdbID: nil, seasons: nil)
        #expect(SeerrError.status(403, data: Data(#"{"message":"Movie Quota exceeded."}"#.utf8), endpoint: create) == .quotaReached)
        #expect(SeerrError.status(403, data: Data(#"{"message":"This media is blocklisted."}"#.utf8), endpoint: create) == .blocklisted)
        #expect(SeerrError.status(409, data: Data(), endpoint: create) == .alreadyRequested)
        #expect(SeerrError.status(202, data: Data(), endpoint: create) == .nothingToRequest)
        #expect(SeerrError.status(500, data: Data(#"{"error":"Plex login is disabled"}"#.utf8), endpoint: .signInWithPlex(token: "")) == .plexSignInOff)
        #expect(SeerrError.status(403, data: Data(), endpoint: .signInWithPlex(token: "")) == .accessDenied)
        #expect(SeerrError.status(200, data: Data(), endpoint: .me) == nil)
    }

    @Test func probingChecksStatusAndRefusesJellyfinSetups() async throws {
        let script = SeerrScript()
        script.queue("/api/v1/status", 200, #"{"version":"3.5.1"}"#)
        script.queue("/api/v1/settings/public", 200, #"{"initialized":true,"applicationTitle":"Requests","mediaServerType":1,"partialRequestsEnabled":false}"#)
        script.queue("/api/v1/status", 200, #"{"version":"3.5.1"}"#)
        script.queue("/api/v1/settings/public", 200, #"{"mediaServerType":2}"#)
        script.queue("/api/v1/status", 200, "<html>Plex</html>")
        let client = SeerrFixtures.client(script)
        let settings = try await client.probe(SeerrFixtures.base)
        #expect(settings.applicationTitle == "Requests")
        #expect(settings.partialRequestsEnabled == false)
        await #expect(throws: SeerrError.notPlex) { _ = try await client.probe(SeerrFixtures.base) }
        await #expect(throws: SeerrError.notSeerr) { _ = try await client.probe(SeerrFixtures.base) }
    }
}

@MainActor
struct SeerrAccountTests {
    private func rig(_ script: SeerrScript) -> (SeerrAccount, SeerrTitles, UserDefaults) {
        let defaults = UserDefaults(suiteName: "seerr.tests.\(UUID().uuidString)")!
        let client = SeerrFixtures.client(script)
        let account = SeerrAccount(client: client, defaults: defaults, server: { "server-1" }, owner: { "tester" }, standIn: { nil })
        let titles = SeerrTitles(client: client, account: account, catalog: { _ in
            try! JSONDecoder().decode(PlexMetadata.self, from: Data(#"{"ratingKey":"abc","type":"movie","title":"Night Train","Guid":[{"id":"tmdb://42"}]}"#.utf8))
        })
        return (account, titles, defaults)
    }

    @Test func connectingSavesTheConnectionAndDisconnectingForgetsIt() async throws {
        let script = SeerrScript()
        script.queue("/api/v1/auth/plex", 200, SeerrFixtures.user, headers: ["Set-Cookie": "connect.sid=abc; Path=/"])
        let (account, _, defaults) = rig(script)
        try await account.connect(address: SeerrFixtures.base, settings: SeerrPublicSettings(applicationTitle: "Requests"))
        #expect(account.isConnected)
        #expect(account.connection?.displayName == "Requests")
        #expect(account.permissions.canRequest(.movie))
        #expect(account.knownAddress == SeerrFixtures.base)
        script.queue("/api/v1/auth/logout", 200, "{}")
        await account.disconnect()
        #expect(account.status == .disconnected)
        #expect(defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("seerr.connection.") } == false)
    }

    @Test func aFailedConnectLeavesNothingSaved() async {
        let script = SeerrScript()
        script.queue("/api/v1/auth/plex", 500, #"{"error":"Plex login is disabled"}"#)
        let (account, _, defaults) = rig(script)
        await #expect(throws: SeerrError.plexSignInOff) { try await account.connect(address: SeerrFixtures.base, settings: SeerrPublicSettings()) }
        #expect(account.status == .disconnected)
        #expect(defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("seerr.connection.") } == false)
    }

    @Test func aWatchlistTitleIsIdentifiedThroughPlexsCatalogueAndRequested() async throws {
        let script = SeerrScript()
        script.queue("/api/v1/auth/plex", 200, SeerrFixtures.user)
        let (account, titles, _) = rig(script)
        try await account.connect(address: SeerrFixtures.base, settings: SeerrPublicSettings())
        script.queue("/api/v1/movie/42", 200, #"{"id":42,"title":"Night Train","releaseDate":"2024-01-01"}"#)
        let entry = try JSONDecoder().decode(PlexMetadata.self, from: Data(#"{"ratingKey":"abc","guid":"plex://movie/abc","type":"movie","title":"Night Train"}"#.utf8))
        let state = try #require(try await titles.state(for: entry, api: nil))
        #expect(state.tmdbID == 42)
        #expect(state.availability == .notRequested)
        script.queue("/api/v1/request", 201, #"{"id":5,"status":1}"#)
        script.queue("/api/v1/movie/42", 200, #"{"id":42,"title":"Night Train","mediaInfo":{"status":2,"requests":[{"id":5,"status":1,"requestedBy":{"id":7}}]}}"#)
        let after = try await titles.request(state)
        #expect(after.availability == .pending)
        #expect(after.ownPendingRequest?.id == 5)
        let sent = script.json(at: script.paths().firstIndex(of: "/api/v1/request")!)
        #expect(sent?["mediaId"] as? Int == 42)
    }

    @Test func aShowRequestAsksOnlyForMissingSeasonsAndAllWhenTheyAreAll() async throws {
        let script = SeerrScript()
        script.queue("/api/v1/auth/plex", 200, SeerrFixtures.user)
        let (account, titles, _) = rig(script)
        try await account.connect(address: SeerrFixtures.base, settings: SeerrPublicSettings())
        let some = #"{"id":9,"name":"S","seasons":[{"seasonNumber":1},{"seasonNumber":2},{"seasonNumber":3}],"mediaInfo":{"status":4,"seasons":[{"seasonNumber":1,"status":5}]}}"#
        script.queue("/api/v1/tv/9", 200, some)
        let state = try await titles.state(tmdbID: 9, kind: .tv)
        #expect(state.requestableSeasons == [2, 3])
        script.queue("/api/v1/request", 201, #"{"id":1,"status":2}"#)
        script.queue("/api/v1/tv/9", 200, some)
        _ = try await titles.request(state, seasons: [1, 3])
        let body = script.json(at: script.paths().lastIndex(of: "/api/v1/request")!)
        #expect(body?["seasons"] as? [Int] == [3])
        await #expect(throws: SeerrError.nothingToRequest) { _ = try await titles.request(state, seasons: [1]) }
    }
}

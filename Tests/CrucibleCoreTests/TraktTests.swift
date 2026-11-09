import Foundation
import Testing
@testable import CrucibleCore

/// A scripted Trakt: answers each request with the next reply queued for its path and records every request it saw.
final class TraktScript: @unchecked Sendable {
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

    var transport: TraktTransport {
        TraktTransport { [self] request in
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

    func json(at index: Int) -> [String: Any]? {
        let body = lock.withLock { requests[index].httpBody }
        return body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

enum TraktFixtures {
    static func token(access: String = "access", refresh: String = "refresh", createdAt: Date = Date(), expiresIn: Int = 604_800) -> TraktToken {
        TraktToken(accessToken: access, refreshToken: refresh, expiresIn: expiresIn, createdAt: Int(createdAt.timeIntervalSince1970))
    }

    static func tokenJSON(access: String, refresh: String) -> String {
        "{\"access_token\":\"\(access)\",\"token_type\":\"bearer\",\"expires_in\":604800,\"refresh_token\":\"\(refresh)\",\"scope\":\"public\",\"created_at\":\(Int(Date().timeIntervalSince1970))}"
    }

    static func plexItem(_ json: String) -> PlexMetadata {
        try! JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
    }

    static let api = APIClient(baseURL: URL(string: "http://127.0.0.1:32400")!, token: "plex")
}

struct TraktEndpointTests {
    @Test func everyRequestCarriesTheHeadersTraktRequires() throws {
        let request = try TraktEndpoint.userSettings.urlRequest(token: "abc", clientID: "client")
        #expect(request.value(forHTTPHeaderField: "trakt-api-key") == "client")
        #expect(request.value(forHTTPHeaderField: "trakt-api-version") == "2")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Crucible/") == true)
        #expect(request.url?.absoluteString == "https://api.trakt.tv/users/settings")
    }

    @Test func signInGoesToTheAuthHostWithoutAToken() throws {
        let request = try TraktEndpoint.deviceCode.urlRequest(token: nil, clientID: "client")
        #expect(request.url?.absoluteString == "https://auth.trakt.tv/oauth/device/code")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String]
        #expect(body == ["client_id": "client"])
        #expect(!TraktEndpoint.deviceCode.isWrite)
    }

    @Test func refreshSendsNoSecret() throws {
        let request = try TraktEndpoint.refreshToken("r1").urlRequest(token: nil, clientID: "client")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String]
        #expect(body?["refresh_token"] == "r1")
        #expect(body?["grant_type"] == "refresh_token")
        #expect(body?["client_secret"] == nil)
    }

    @Test func scrobbleNamesTheItemUnderItsKindWithRoundedProgress() throws {
        let endpoint = TraktEndpoint.scrobble(.stop, kind: .episode, ids: TraktIDs(trakt: 42), progress: 87.456)
        let request = try endpoint.urlRequest(token: "t", clientID: "c")
        #expect(request.url?.path == "/scrobble/stop")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
        #expect((body?["episode"] as? [String: Any])?["ids"] as? [String: Int] == ["trakt": 42])
        #expect(body?["progress"] as? Double == 87.46)
        #expect(body?["movie"] == nil)
    }

    @Test func lookupsAskForTheKindAndEscapeTheID() throws {
        let request = try TraktEndpoint.lookup(.imdb("tt0111161"), kind: .movie).urlRequest(token: nil, clientID: "c")
        #expect(request.url?.absoluteString == "https://api.trakt.tv/search/imdb/tt0111161?type=movie")
    }

    @Test func aSeasonIsWrittenAsItsShowWithThatSeason() throws {
        let target = TraktTarget(kind: .show, ids: TraktIDs(trakt: 7, slug: "x"), showIDs: TraktIDs(trakt: 7), season: 2)
        let items = TraktPlugin.items(for: target, watchedAt: Date(timeIntervalSince1970: 0), rating: nil)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(items)) as? [String: Any]
        let show = (json?["shows"] as? [[String: Any]])?.first
        #expect(show?["ids"] as? [String: Int] == ["trakt": 7])
        #expect(show?["watched_at"] == nil)
        let season = (show?["seasons"] as? [[String: Any]])?.first
        #expect(season?["number"] as? Int == 2)
        #expect(season?["watched_at"] as? String == "1970-01-01T00:00:00.000Z")
        #expect(json?["movies"] == nil)
    }

    @Test func aRatingWritesTheTenPointValue() throws {
        let target = TraktTarget(kind: .movie, ids: TraktIDs(trakt: 3, imdb: "tt1"))
        let items = TraktPlugin.items(for: target, watchedAt: nil, rating: 9, ratedAt: Date(timeIntervalSince1970: 60))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(items)) as? [String: Any]
        let movie = (json?["movies"] as? [[String: Any]])?.first
        #expect(movie?["rating"] as? Int == 9)
        #expect(movie?["rated_at"] as? String == "1970-01-01T00:01:00.000Z")
        #expect(movie?["ids"] as? [String: Int] == ["trakt": 3])
    }

    @Test func overridesAreOnlyTakenInDebugBuildsAndWellFormed() {
        #expect(TraktConfig.parseOverride(" http://127.0.0.1:9 ", allowed: true)?.absoluteString == "http://127.0.0.1:9")
        #expect(TraktConfig.parseOverride("http://127.0.0.1:9", allowed: false) == nil)
        #expect(TraktConfig.parseOverride("ftp://x", allowed: true) == nil)
        #expect(TraktConfig.parseOverride(nil, allowed: true) == nil)
    }
}

struct TraktClientTests {
    private func client(_ script: TraktScript, token: TraktToken? = TraktFixtures.token(), sleeps: SleepLog = SleepLog()) async -> (TraktClient, TraktTokenStore) {
        let store = TraktTokenStore(keychain: .memory(), owner: { "test" })
        if let token { await store.save(token) }
        let client = TraktClient(transport: script.transport, tokens: store, sleep: { await sleeps.add($0) }, clientID: { "client" })
        return (client, store)
    }

    actor SleepLog {
        private(set) var waits: [Duration] = []
        func add(_ duration: Duration) { waits.append(duration) }
    }

    @Test func aRefusedTokenIsRefreshedOnceAndTheCallRetried() async throws {
        let script = TraktScript()
        script.queue("/users/settings", 401)
        script.queue("/oauth/token", 200, TraktFixtures.tokenJSON(access: "fresh", refresh: "next"))
        script.queue("/users/settings", 200, "{\"user\":{\"username\":\"sam\"}}")
        let (client, store) = await client(script)
        let settings = try await client.send(.userSettings, as: TraktUserSettings.self)
        #expect(settings.user.username == "sam")
        #expect(script.paths() == ["/users/settings", "/oauth/token", "/users/settings"])
        #expect(script.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
        #expect(await store.token?.refreshToken == "next")
    }

    @Test func aRefreshTraktRefusesSignsTheViewerOut() async {
        let script = TraktScript()
        script.queue("/users/settings", 401)
        script.queue("/oauth/token", 400, "{\"error\":\"invalid_grant\"}")
        let (client, store) = await client(script)
        await #expect(throws: TraktError.unauthorized) { try await client.sendVoid(.userSettings) }
        #expect(await store.token == nil)
    }

    @Test func aTokenCloseToExpiringIsRefreshedBeforeTheCall() async throws {
        let script = TraktScript()
        script.queue("/oauth/token", 200, TraktFixtures.tokenJSON(access: "fresh", refresh: "next"))
        script.queue("/users/settings", 200, "{\"user\":{\"username\":\"sam\"}}")
        let old = TraktFixtures.token(createdAt: Date().addingTimeInterval(-600_000))
        let (client, _) = await client(script, token: old)
        _ = try await client.send(.userSettings, as: TraktUserSettings.self)
        #expect(script.paths() == ["/oauth/token", "/users/settings"])
    }

    @Test func aRateLimitWaitsWhatTraktSaysThenRetries() async throws {
        let script = TraktScript()
        script.queue("/sync/history", 429, headers: ["Retry-After": "3"])
        script.queue("/sync/history", 201)
        let sleeps = SleepLog()
        let (client, _) = await client(script, sleeps: sleeps)
        try await client.sendVoid(.addHistory(TraktSyncItems(movies: [.init(ids: TraktIDs(trakt: 1), watchedAt: nil, rating: nil, ratedAt: nil)])))
        #expect(script.paths().count == 2)
        #expect(await sleeps.waits.contains(.seconds(3)))
    }

    @Test func limitsLocksAndVIPAreTold() async {
        let script = TraktScript()
        script.queue("/sync/ratings", 420)
        script.queue("/sync/ratings/remove", 423)
        script.queue("/checkin", 426, headers: ["X-Upgrade-URL": "https://app.trakt.tv/vip"])
        let (client, _) = await client(script)
        let items = TraktSyncItems(movies: [.init(ids: TraktIDs(trakt: 1), watchedAt: nil, rating: 5, ratedAt: nil)])
        await #expect(throws: TraktError.accountLimit) { try await client.sendVoid(.addRatings(items)) }
        await #expect(throws: TraktError.locked) { try await client.sendVoid(.removeRatings(items)) }
        await #expect(throws: TraktError.vipOnly(URL(string: "https://app.trakt.tv/vip"))) { try await client.sendVoid(.checkin(kind: .movie, ids: TraktIDs(trakt: 1))) }
    }

    @Test func callsNeedingTheViewerFailWithoutAToken() async {
        let script = TraktScript()
        let (client, _) = await client(script, token: nil)
        await #expect(throws: TraktError.signedOut) { try await client.sendVoid(.userSettings) }
        #expect(script.paths().isEmpty)
    }

    @Test func writesAreSpacedASecondApart() async throws {
        let script = TraktScript()
        script.queue("/sync/history", 201)
        script.queue("/sync/history", 201)
        let sleeps = SleepLog()
        let (client, _) = await client(script, sleeps: sleeps)
        let items = TraktSyncItems(movies: [.init(ids: TraktIDs(trakt: 1), watchedAt: nil, rating: nil, ratedAt: nil)])
        try await client.sendVoid(.addHistory(items))
        try await client.sendVoid(.addHistory(items))
        #expect(await sleeps.waits.count == 1)
    }

    @Test func pollingReadsEveryDeviceStatus() async throws {
        let script = TraktScript()
        for status in [400, 429, 410, 418, 404] { script.queue("/oauth/device/token", status) }
        script.queue("/oauth/device/token", 200, TraktFixtures.tokenJSON(access: "a", refresh: "r"))
        let (client, _) = await client(script, token: nil)
        #expect(try await client.pollDeviceToken("d") == .pending)
        #expect(try await client.pollDeviceToken("d") == .slowDown)
        #expect(try await client.pollDeviceToken("d") == .expired)
        #expect(try await client.pollDeviceToken("d") == .denied)
        #expect(try await client.pollDeviceToken("d") == .invalid)
        guard case .approved(let token) = try await client.pollDeviceToken("d") else {
            Issue.record("expected approval")
            return
        }
        #expect(token.accessToken == "a")
    }
}

struct TraktLinkSessionTests {
    final class Polls: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [TraktDevicePoll]
        private(set) var asked = 0
        init(_ answers: [TraktDevicePoll]) { self.answers = answers }
        func next() -> TraktDevicePoll { lock.withLock { asked += 1; return answers.isEmpty ? .pending : answers.removeFirst() } }
    }

    private func states(_ polls: Polls, expiresIn: Int = 600, clock: TestClock = TestClock()) async -> [TraktLinkState] {
        let transport = TraktLinkSession.Transport(
            requestCode: { TraktDeviceCode(deviceCode: "dev", userCode: "ABCD1234", verificationURL: "https://auth.trakt.tv/activate", expiresIn: expiresIn, interval: 5) },
            poll: { _ in polls.next() }
        )
        let session = TraktLinkSession(transport: transport, now: { clock.now }, sleep: { clock.advance($0) })
        var seen: [TraktLinkState] = []
        for await state in session.states() { seen.append(state) }
        return seen
    }

    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_000)
        var now: Date { lock.withLock { current } }
        func advance(_ duration: Duration) { lock.withLock { current = current.addingTimeInterval(TimeInterval(duration.components.seconds)) } }
    }

    @Test func showsTheCodeThenConnectsWhenApproved() async {
        let token = TraktFixtures.token()
        let seen = await states(Polls([.pending, .slowDown, .approved(token)]))
        #expect(seen.first == .requesting)
        guard case .waiting(let code) = seen[1] else {
            Issue.record("expected the code")
            return
        }
        #expect(code.displayGroups == ["ABCD", "1234"])
        #expect(seen.last == .approved(token))
    }

    @Test func stopsWhenTheCodeRunsOut() async {
        let seen = await states(Polls([]), expiresIn: 20)
        #expect(seen.last == .expired)
    }

    @Test func aDeclinedCodeEndsTheSession() async {
        let seen = await states(Polls([.denied]))
        #expect(seen.last == .denied)
    }

    @Test func anAccountTraktDoesNotAllowIsTold() async {
        let seen = await states(Polls([.notAllowed]))
        #expect(seen.last == .notAllowed)
    }
}

@MainActor
struct TraktResolverTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        func add(_ entry: String) { lock.withLock { log.append(entry) } }
        var all: [String] { lock.withLock { log } }
    }

    private func resolver(
        items: [String: String],
        search: [String: String],
        episodes: [String: String] = [:],
        calls: Calls = Calls()
    ) -> TraktResolver {
        let lookup = TraktResolver.Lookup(
            search: { id, kind in
                calls.add("search \(id.pathType)/\(id.pathValue) \(kind.rawValue)")
                let json = search["\(id.pathType)/\(id.pathValue)"] ?? "[]"
                return try JSONDecoder().decode([TraktSearchResult].self, from: Data(json.utf8))
            },
            episode: { show, season, number in
                calls.add("episode \(show) \(season)x\(number)")
                guard let json = episodes["\(show)/\(season)/\(number)"] else { throw TraktError.notFound }
                return try JSONDecoder().decode(TraktEpisode.self, from: Data(json.utf8))
            },
            plexItem: { key, _ in items[key].map(TraktFixtures.plexItem) }
        )
        return TraktResolver(lookup: lookup, storage: nil)
    }

    @Test func aMovieIsMatchedByItsIMDbID() async {
        let resolver = resolver(
            items: ["1": #"{"ratingKey":"1","type":"movie","title":"Halcyon","Guid":[{"id":"imdb://tt100"},{"id":"tmdb://5"}]}"#],
            search: ["imdb/tt100": #"[{"type":"movie","movie":{"title":"Halcyon","ids":{"trakt":9,"imdb":"tt100","tmdb":5}}}]"#]
        )
        let result = await resolver.resolve(ratingKey: "1", server: "s", api: TraktFixtures.api)
        #expect(result == .found(TraktTarget(kind: .movie, ids: TraktIDs(trakt: 9, imdb: "tt100", tmdb: 5))))
    }

    @Test func anAnswerForAnotherIDOrKindIsNotTaken() async {
        let resolver = resolver(
            items: ["1": #"{"ratingKey":"1","type":"movie","title":"Halcyon","Guid":[{"id":"imdb://tt100"}]}"#],
            search: ["imdb/tt100": #"[{"type":"show","show":{"ids":{"trakt":1,"imdb":"tt100"}}},{"type":"movie","movie":{"ids":{"trakt":2,"imdb":"tt999"}}}]"#]
        )
        #expect(await resolver.resolve(ratingKey: "1", server: "s", api: TraktFixtures.api) == .unmatched)
        #expect(resolver.unmatchedTitles == ["Halcyon"])
    }

    @Test func moviesAreNeverLookedUpByTVDB() async {
        let calls = Calls()
        let resolver = resolver(
            items: ["1": #"{"ratingKey":"1","type":"movie","title":"X","Guid":[{"id":"tvdb://77"}]}"#],
            search: [:],
            calls: calls
        )
        #expect(await resolver.resolve(ratingKey: "1", server: "s", api: TraktFixtures.api) == .unmatched)
        #expect(calls.all.isEmpty)
    }

    @Test func anEpisodeIsFoundThroughItsShowAndConfirmedByItsOwnID() async {
        let calls = Calls()
        let resolver = resolver(
            items: [
                "10": #"{"ratingKey":"10","type":"episode","title":"Undertow","grandparentTitle":"The Salt Road","grandparentRatingKey":"20","parentIndex":2,"index":5,"Guid":[{"id":"tvdb://555"}]}"#,
                "20": #"{"ratingKey":"20","type":"show","title":"The Salt Road","Guid":[{"id":"tvdb://81"}]}"#,
            ],
            search: ["tvdb/81": #"[{"type":"show","show":{"ids":{"trakt":300,"tvdb":81}}}]"#],
            episodes: ["300/2/5": #"{"season":2,"number":5,"ids":{"trakt":4000,"tvdb":555}}"#],
            calls: calls
        )
        let result = await resolver.resolve(ratingKey: "10", server: "s", api: TraktFixtures.api)
        #expect(result == .found(TraktTarget(kind: .episode, ids: TraktIDs(trakt: 4000, tvdb: 555), showIDs: TraktIDs(trakt: 300, tvdb: 81), season: 2, number: 5)))
        #expect(calls.all == ["search tvdb/81 show", "episode 300 2x5"])
    }

    @Test func numberingThatDisagreesFallsBackToTheEpisodesOwnID() async {
        let resolver = resolver(
            items: [
                "10": #"{"ratingKey":"10","type":"episode","title":"Ep","grandparentRatingKey":"20","parentIndex":1,"index":1,"Guid":[{"id":"tvdb://555"}]}"#,
                "20": #"{"ratingKey":"20","type":"show","title":"Show","Guid":[{"id":"tvdb://81"}]}"#,
            ],
            search: [
                "tvdb/81": #"[{"type":"show","show":{"ids":{"trakt":300,"tvdb":81}}}]"#,
                "tvdb/555": #"[{"type":"episode","episode":{"season":3,"number":9,"ids":{"trakt":4001,"tvdb":555}},"show":{"ids":{"trakt":300}}}]"#,
            ],
            episodes: ["300/1/1": #"{"season":1,"number":1,"ids":{"trakt":4999,"tvdb":111}}"#]
        )
        let result = await resolver.resolve(ratingKey: "10", server: "s", api: TraktFixtures.api)
        #expect(result.target?.ids.trakt == 4001)
        #expect(result.target?.season == 3)
        #expect(result.target?.number == 9)
    }

    @Test func aLegacyAgentGuidStillMatches() {
        let movie = LegacyGuid("com.plexapp.agents.imdb://tt0111161?lang=en")
        #expect(movie.imdb == "tt0111161")
        let show = LegacyGuid("com.plexapp.agents.thetvdb://81189/1/1?lang=en")
        #expect(show.tvdb == 81189)
        let tmdb = LegacyGuid("com.plexapp.agents.themoviedb://603?lang=en")
        #expect(tmdb.tmdb == 603)
        #expect(LegacyGuid("plex://movie/5d776").imdb == nil)
    }

    @Test func plexOrTraktUnreachableIsNotRememberedAsUnmatched() async {
        let lookup = TraktResolver.Lookup(
            search: { _, _ in throw TraktError.offline },
            episode: { _, _, _ in throw TraktError.offline },
            plexItem: { _, _ in TraktFixtures.plexItem(#"{"ratingKey":"1","type":"movie","title":"X","Guid":[{"id":"imdb://tt1"}]}"#) }
        )
        let resolver = TraktResolver(lookup: lookup, storage: nil)
        #expect(await resolver.resolve(ratingKey: "1", server: "s", api: TraktFixtures.api) == .unknown)
        #expect(resolver.unmatchedTitles.isEmpty)
    }
}

@MainActor
struct TraktOutboxTests {
    private func change(_ key: String, _ action: TraktPendingChange.Action, owner: String = "a", at: Date = Date()) -> TraktPendingChange {
        TraktPendingChange(ratingKey: key, server: "s", owner: owner, action: action, madeAt: at)
    }

    @Test func aNewRatingReplacesTheOneWaiting() {
        let outbox = TraktOutbox(storage: nil)
        outbox.add(change("1", .rated(6)))
        outbox.add(change("1", .rated(9)))
        outbox.add(change("1", .watched(at: Date(timeIntervalSince1970: 1))))
        outbox.add(change("1", .watched(at: Date(timeIntervalSince1970: 2))))
        #expect(outbox.pending.map(\.action) == [.rated(9), .watched(at: Date(timeIntervalSince1970: 1)), .watched(at: Date(timeIntervalSince1970: 2))])
    }

    @Test func drainingStopsAtAPassingFailureAndDropsARefusal() async {
        let outbox = TraktOutbox(storage: nil)
        outbox.add(change("1", .rated(5)))
        outbox.add(change("2", .rated(5)))
        outbox.add(change("3", .rated(5)))
        var sent: [String] = []
        await outbox.drain(server: "s", owner: "a") { change in
            sent.append(change.ratingKey)
            if change.ratingKey == "1" { throw TraktError.invalidItem }
            if change.ratingKey == "2" { throw TraktError.offline }
        }
        #expect(sent == ["1", "2"])
        #expect(outbox.pending.map(\.ratingKey) == ["2", "3"])
    }

    @Test func onlyTheViewersOwnChangesAreSent() async {
        let outbox = TraktOutbox(storage: nil)
        outbox.add(change("1", .rated(5), owner: "kid"))
        outbox.add(change("2", .rated(5), owner: "a"))
        var sent: [String] = []
        await outbox.drain(server: "s", owner: "a") { sent.append($0.ratingKey) }
        #expect(sent == ["2"])
        #expect(outbox.pending.map(\.ratingKey) == ["1"])
    }

    @Test func aMonthOldChangeIsGivenUp() async {
        let outbox = TraktOutbox(storage: nil)
        outbox.add(change("1", .rated(5), at: Date(timeIntervalSince1970: 0)))
        var sent = 0
        await outbox.drain(server: "s", owner: "a", now: Date(timeIntervalSince1970: 40 * 86_400)) { _ in sent += 1 }
        #expect(sent == 0)
        #expect(outbox.pending.isEmpty)
    }

    @Test func aPlayIsRecognisedToTheMinute() {
        let outbox = TraktOutbox(storage: nil)
        let date = Date(timeIntervalSince1970: 1_000_020)
        outbox.noteSent(traktID: 9, at: date)
        #expect(outbox.wasSent(traktID: 9, at: date.addingTimeInterval(10)))
        #expect(!outbox.wasSent(traktID: 9, at: date.addingTimeInterval(120)))
        #expect(!outbox.wasSent(traktID: 8, at: date))
    }
}

@MainActor
struct TraktScrobbleTests {
    @MainActor
    private struct Rig {
        let script = TraktScript()
        let plugin: TraktPlugin
        let account: TraktAccount
        let outbox = TraktOutbox(storage: nil)

        init(matched: Bool = true) async {
            let store = TraktTokenStore(keychain: .memory(), owner: { "test" })
            let client = TraktClient(transport: script.transport, tokens: store, sleep: { _ in }, clientID: { "client" })
            let defaults = UserDefaults(suiteName: "trakt-tests-\(UUID().uuidString)")!
            account = TraktAccount(tokens: store, defaults: defaults, client: client)
            let movie = #"{"ratingKey":"1","type":"movie","title":"Halcyon","Guid":[{"id":"imdb://tt100"}]}"#
            let search = matched ? #"[{"type":"movie","movie":{"ids":{"trakt":9,"imdb":"tt100"}}}]"# : "[]"
            let lookup = TraktResolver.Lookup(
                search: { _, _ in try JSONDecoder().decode([TraktSearchResult].self, from: Data(search.utf8)) },
                episode: { _, _, _ in throw TraktError.notFound },
                plexItem: { _, _ in TraktFixtures.plexItem(movie) }
            )
            plugin = TraktPlugin(account: account, resolver: TraktResolver(lookup: lookup, storage: nil), outbox: outbox, client: client)
            script.queue("/users/settings", 200, "{\"user\":{\"username\":\"sam\"}}")
            await account.connect(with: TraktFixtures.token())
        }

        func watcher(duration: Double = 1_000) -> PlaybackWatching? {
            plugin.makePlaybackWatcher(for: PlaybackSubject(
                ratingKey: "1", mediaType: "movie", showRatingKey: nil, title: "Halcyon", showTitle: nil,
                seasonNumber: nil, episodeNumber: nil, durationSecs: duration, server: "s", api: TraktFixtures.api
            ))
        }

        func settle() async {
            for _ in 0..<50 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func playPauseAndTheEndAreScrobbledInOrder() async throws {
        let rig = await Rig()
        rig.script.queue("/scrobble/start", 201, #"{"action":"start","progress":10}"#)
        rig.script.queue("/scrobble/pause", 201, #"{"action":"pause","progress":50}"#)
        rig.script.queue("/scrobble/start", 201, #"{"action":"start","progress":50}"#)
        rig.script.queue("/scrobble/stop", 201, #"{"action":"scrobble","progress":95}"#)
        let watcher = try #require(rig.watcher())
        watcher.playback(.playing(position: 100))
        watcher.playback(.playing(position: 101))
        watcher.playback(.paused(position: 500))
        watcher.playback(.playing(position: 500))
        watcher.playback(.stopped(position: 950, finished: true, at: Date()))
        await rig.settle()
        #expect(rig.script.paths().filter { $0.hasPrefix("/scrobble") } == ["/scrobble/start", "/scrobble/pause", "/scrobble/start", "/scrobble/stop"])
        #expect(!rig.script.paths().contains("/sync/history"))
    }

    @Test func creditsBeforeEightyPercentStillMarkTheMovieWatched() async throws {
        let rig = await Rig()
        rig.script.queue("/scrobble/start", 201, #"{"action":"start","progress":10}"#)
        rig.script.queue("/scrobble/pause", 201, #"{"action":"pause","progress":75}"#)
        rig.script.queue("/sync/history", 201, "{}")
        let watcher = try #require(rig.watcher())
        watcher.playback(.playing(position: 100))
        watcher.playback(.stopped(position: 750, finished: true, at: Date()))
        await rig.settle()
        #expect(rig.script.paths().suffix(2) == ["/scrobble/pause", "/sync/history"])
    }

    @Test func aFinishedPlayTraktCannotTakeNowWaitsInTheOutbox() async throws {
        let rig = await Rig()
        rig.script.queue("/scrobble/stop", 503)
        rig.script.queue("/scrobble/stop", 503)
        for _ in 0..<4 { rig.script.queue("/sync/history", 503) }
        let watcher = try #require(rig.watcher())
        watcher.playback(.stopped(position: 990, finished: true, at: Date()))
        await rig.settle()
        #expect(rig.outbox.pending.count == 1)
    }

    @Test func aStopShortOfTheEndOnlySavesThePlace() async throws {
        let rig = await Rig()
        rig.script.queue("/scrobble/start", 201, #"{"action":"start","progress":10}"#)
        rig.script.queue("/scrobble/pause", 201, #"{"action":"pause","progress":30}"#)
        let watcher = try #require(rig.watcher())
        watcher.playback(.playing(position: 100))
        watcher.playback(.stopped(position: 300, finished: false, at: Date()))
        await rig.settle()
        #expect(rig.script.paths().filter { $0 != "/users/settings" } == ["/scrobble/start", "/scrobble/pause"])
    }

    @Test func anUnmatchedTitleSendsNothing() async throws {
        let rig = await Rig(matched: false)
        let watcher = try #require(rig.watcher())
        watcher.playback(.playing(position: 100))
        watcher.playback(.stopped(position: 990, finished: true, at: Date()))
        await rig.settle()
        #expect(rig.script.paths() == ["/users/settings"])
        #expect(rig.outbox.pending.isEmpty)
    }

    @Test func noWatcherWhenAnotherAppRecordsPlaysOrScrobblingIsOff() async {
        let rig = await Rig()
        rig.account.update { $0.anotherAppScrobbles = true }
        #expect(rig.watcher() == nil)
        rig.account.update { $0.anotherAppScrobbles = false; $0.scrobbles = false }
        #expect(rig.watcher() == nil)
    }
}

struct TraktScoreTests {
    @Test func scoresComeInStripOrderAndSkipEmptySources() throws {
        let json = #"{"trakt":{"rating":8.71,"votes":12400},"imdb":{"rating":8.1,"votes":212000,"link":"https://www.imdb.com/title/tt1"},"rotten_tomatoes":{"rating":92},"metascore":{"rating":null},"letterboxd":{"rating":4.1},"tmdb":{"rating":0}}"#
        let ratings = try JSONDecoder().decode(TraktRatings.self, from: Data(json.utf8))
        #expect(ratings.scores.map(\.source) == [.trakt, .imdb, .rottenTomatoes, .letterboxd])
        #expect(ratings.scores[1].link?.absoluteString == "https://www.imdb.com/title/tt1")
    }

    @Test func aTraktScoreWithoutVotesIsNotShown() throws {
        let ratings = try JSONDecoder().decode(TraktRatings.self, from: Data(#"{"trakt":{"rating":7,"votes":0}}"#.utf8))
        #expect(ratings.scores.isEmpty)
    }

    @Test func eachSourceIsWrittenItsOwnWay() {
        #expect(TraktCopy.value(TraktScore(source: .trakt, value: 8.71, votes: 10, link: nil)) == "87%")
        #expect(TraktCopy.value(TraktScore(source: .rottenTomatoes, value: 92, votes: nil, link: nil)) == "92%")
        #expect(TraktCopy.value(TraktScore(source: .metascore, value: 78, votes: nil, link: nil)) == "78")
    }

    @Test func aCheckInConflictReadsWhenTheOtherOneEnds() {
        let data = Data(#"{"watched_at":"2026-11-08T20:00:00.000Z","expires_at":"2026-11-08T21:58:00.000Z"}"#.utf8)
        #expect(TraktCheckin.expiry(in: data) == ISO8601DateFormatter().date(from: "2026-11-08T21:58:00Z"))
    }

    @Test func tokensRefreshADayEarly() {
        let created = Date(timeIntervalSince1970: 0)
        let token = TraktFixtures.token(createdAt: created, expiresIn: 7 * 86_400)
        #expect(!token.needsRefresh(now: created.addingTimeInterval(5 * 86_400)))
        #expect(token.needsRefresh(now: created.addingTimeInterval(6 * 86_400 + 1)))
    }
}

/// Choosing Crucible to record plays turns off the plays Trakt's own Plex sync records, and nothing else it syncs.
struct TraktPlexSyncTests {
    @Test func onlyTheSyncsPlaysAreTurnedOff() throws {
        let settings = #"""
        {"connection": {"connected": true}, "sync": {"configured": true,
          "toggles": {"movie": {"watched": true, "collected": true, "rated": false}, "episode": {"watched": true, "collected": false},
                      "show": {"rated": true}}}}
        """#
        let body = try #require(TraktAccount.syncWithoutPlays(Data(settings.utf8)))
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let toggles = try #require((sent["sync"] as? [String: Any])?["toggles"] as? [String: [String: Bool]])
        #expect(sent.keys.sorted() == ["sync"], "only the sync is changed")
        #expect(toggles["movie"] == ["watched": false, "collected": true, "rated": false])
        #expect(toggles["episode"] == ["watched": false, "collected": false])
        #expect(toggles["show"] == ["rated": true])
    }

    @Test func aSyncThatRecordsNoPlaysIsLeftAlone() {
        let notSetUp = #"{"sync": {"configured": false, "toggles": {"movie": {"watched": true}}}}"#
        let noPlays = #"{"sync": {"configured": true, "toggles": {"movie": {"watched": false}, "episode": {"collected": true}}}}"#
        #expect(TraktAccount.syncWithoutPlays(Data(notSetUp.utf8)) == nil)
        #expect(TraktAccount.syncWithoutPlays(Data(noPlays.utf8)) == nil)
    }
}

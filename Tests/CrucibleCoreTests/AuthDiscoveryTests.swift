import Foundation
import Testing
@testable import CrucibleCore

private struct Saved: Sendable, Equatable {
    let uri: URL
    let name: String
    let machineIdentifier: String
    let candidates: [URL]
}

private final class DiscoveryStub: @unchecked Sendable {
    var resources: [PlexResource] = []
    var resourcesError: Error?
    var reachable: Set<URL> = []
    var firstReachableOverride: URL?
    var identified: [URL: String] = [:]
    var latency: [URL: Int] = [:]
    var saveReturnsConnection = true

    let saved = AuthLocked<[Saved]>([])
    let reachabilityQueries = AuthLocked<[[URL]]>([])

    var environment: ServerDiscoveryEnvironment {
        ServerDiscoveryEnvironment(
            resources: { [self] _ in
                if let resourcesError { throw resourcesError }
                return resources
            },
            probe: { [self] url, _ in reachable.contains(url) },
            firstReachable: { [self] urls, _ in
                reachabilityQueries.update { $0.append(urls) }
                return firstReachableOverride ?? urls.first { reachable.contains($0) }
            },
            machineIdentifier: { [self] url, _ in identified[url] },
            measure: { [self] url, _ in latency[url] },
            save: { [self] uri, name, machineIdentifier, candidates in
                saved.update { $0.append(Saved(uri: uri, name: name, machineIdentifier: machineIdentifier, candidates: candidates)) }
                guard saveReturnsConnection else { return nil }
                return PlexConnection(serverURI: uri, serverName: name, machineIdentifier: machineIdentifier, authToken: "tok", clientIdentifier: "client", candidateURIs: [uri] + candidates)
            }
        )
    }
}

private func url(_ string: String) -> URL { URL(string: string)! }

struct AuthDiscoveryTests {
    private let lan = "http://192.168.1.5:32400"
    private let remote = "http://203.0.113.7:32400"

    private func listing(_ stub: DiscoveryStub) async throws -> ServerListing {
        try await ServerDiscovery(token: "tok", environment: stub.environment).listing()
    }

    @Test func listingSeparatesNoneOneAndSeveralServersAndIgnoresPlayers() async throws {
        let stub = DiscoveryStub()
        stub.resources = [AuthFixtures.resource(name: "Phone", id: "p", provides: "client,player", uris: [])]
        guard case .none = try await listing(stub) else { Issue.record("expected none"); return }

        stub.resources.append(AuthFixtures.resource(name: "Home", id: "a", uris: [lan]))
        guard case .single(let only) = try await listing(stub) else { Issue.record("expected single"); return }
        #expect(only.name == "Home")

        stub.resources.append(AuthFixtures.resource(name: "Office", id: "b", uris: [remote]))
        guard case .several(let both) = try await listing(stub) else { Issue.record("expected several"); return }
        #expect(both.map(\.name) == ["Home", "Office"])
    }

    @Test func listingPropagatesPlexTvErrors() async {
        let stub = DiscoveryStub()
        stub.resourcesError = APIError.unauthorized
        await #expect(throws: APIError.self) { _ = try await listing(stub) }
    }

    @Test func aSingleServerPinsTheBestAnsweringRouteAndKeepsTheOthersAsCandidates() async throws {
        let stub = DiscoveryStub()
        let server = AuthFixtures.choice(name: "Home", id: "m1", uris: [remote, lan])
        stub.reachable = [url(lan), url(remote)]
        let log = AuthLocked<[String]>([])

        let outcome = await ServerDiscovery(token: "tok", environment: stub.environment).connect(toOnly: server) { progress in log.update { $0.append(progress.message) } }

        guard case .connected(let connection) = outcome else { Issue.record("expected connected, got \(outcome)"); return }
        #expect(connection.serverURI == url(lan))
        #expect(connection.machineIdentifier == "m1")
        #expect(stub.saved.value == [Saved(uri: url(lan), name: "Home", machineIdentifier: "m1", candidates: [url(remote)])])
        #expect(stub.reachabilityQueries.value == [[url(lan), url(remote)]])
        #expect(log.value == ["Finding the best route to Home…", "Connecting to \(lan)...", "Connected to Home"])
    }

    @Test func aSingleServerWithoutRoutesAsksForAnAddressSilently() async {
        let stub = DiscoveryStub()
        let server = AuthFixtures.choice(name: "Home", id: "m1", uris: [])
        let log = AuthLocked<[String]>([])

        let outcome = await ServerDiscovery(token: "tok", environment: stub.environment).connect(toOnly: server) { progress in log.update { $0.append(progress.message) } }

        guard case .needsAddress(let message) = outcome else { Issue.record("expected needsAddress"); return }
        #expect(message == nil)
        #expect(log.value.isEmpty)
        #expect(stub.saved.value.isEmpty)
    }

    @Test func aSingleServerThatNeverAnswersAsksForAnAddressWithAMessage() async {
        let stub = DiscoveryStub()
        let server = AuthFixtures.choice(name: "Home", id: "m1", uris: [lan])

        let outcome = await ServerDiscovery(token: "tok", environment: stub.environment).connect(toOnly: server) { _ in }

        guard case .needsAddress(let message) = outcome else { Issue.record("expected needsAddress"); return }
        #expect(message == "Could not reach Home. Enter its address instead.")
    }

    @Test func aRouteThatStopsAnsweringBeforeTheSaveFails() async {
        let stub = DiscoveryStub()
        stub.firstReachableOverride = url(lan)
        let server = AuthFixtures.choice(name: "Home", id: "m1", uris: [lan])

        let outcome = await ServerDiscovery(token: "tok", environment: stub.environment).connect(toOnly: server) { _ in }

        guard case .failed(let message) = outcome else { Issue.record("expected failed"); return }
        #expect(message == "Could not reach server at \(lan)")
        #expect(stub.saved.value.isEmpty)
    }

    @Test func aSaveThatYieldsNoConnectionFails() async {
        let stub = DiscoveryStub()
        stub.reachable = [url(lan)]
        stub.saveReturnsConnection = false
        let server = AuthFixtures.choice(name: "Home", id: "m1", uris: [lan])

        let outcome = await ServerDiscovery(token: "tok", environment: stub.environment).connect(toOnly: server) { _ in }

        guard case .failed(let message) = outcome else { Issue.record("expected failed"); return }
        #expect(message == "Failed to save connection")
    }

    @Test func connectingToAChosenRouteSavesTheOtherRoutesAsCandidates() async throws {
        let stub = DiscoveryStub()
        stub.reachable = [url(remote)]
        let choice = AuthFixtures.choice(name: "Office", id: "m2", uris: [lan, remote])
        let route = try #require(choice.routes.first { $0.uri == remote })

        let outcome = await ServerDiscovery(token: "tok", environment: stub.environment).connect(to: choice, route: route) { _ in }

        guard case .connected(let connection) = outcome else { Issue.record("expected connected"); return }
        #expect(connection.serverURI == url(remote))
        #expect(stub.saved.value.first?.candidates == [url(lan)])
    }

    @Test func aChosenRouteWithoutAUsableAddressIsRejected() async {
        let stub = DiscoveryStub()
        let choice = AuthFixtures.choice(name: "Office", id: "m2", uris: [""])

        let outcome = await ServerDiscovery(token: "tok", environment: stub.environment).connect(to: choice, route: choice.routes[0]) { _ in }

        guard case .failed(let message) = outcome else { Issue.record("expected failed"); return }
        #expect(message == "Invalid server address")
    }

    @Test func aTypedAddressIsIdentifiedAndNamedFromPlexTv() async throws {
        let stub = DiscoveryStub()
        let address = try #require(ServerAddress.parse("192.168.1.5"))
        stub.reachable = [url("https://192.168.1.5:32400"), url(lan)]
        stub.identified = [url("https://192.168.1.5:32400"): "m1"]
        stub.resources = [AuthFixtures.resource(name: "Home", id: "m1", uris: [lan])]
        let log = AuthLocked<[String]>([])

        let outcome = await ServerDiscovery(token: "tok", environment: stub.environment).connect(toAddress: address, known: nil) { progress in log.update { $0.append(progress.message) } }

        guard case .connected(let connection) = outcome else { Issue.record("expected connected"); return }
        #expect(connection.serverName == "Home")
        #expect(connection.machineIdentifier == "m1")
        #expect(stub.reachabilityQueries.value == [[url("https://192.168.1.5:32400"), url("http://192.168.1.5:32400")]])
        #expect(log.value.first == "Connecting to 192.168.1.5…")
    }

    @Test func anUnidentifiedAddressFallsBackToItsHost() async throws {
        let stub = DiscoveryStub()
        let address = try #require(ServerAddress.parse("http://nas.local:32500"))
        stub.reachable = [url("http://nas.local:32500")]

        let outcome = await ServerDiscovery(token: "tok", environment: stub.environment).connect(toAddress: address, known: nil) { _ in }

        guard case .connected(let connection) = outcome else { Issue.record("expected connected"); return }
        #expect(connection.serverName == "nas.local")
        #expect(connection.machineIdentifier == "nas.local")
    }

    @Test func aTypedAddressForAKnownServerKeepsItsIdentityAndRoutes() async throws {
        let stub = DiscoveryStub()
        let address = try #require(ServerAddress.parse("10.0.0.9"))
        stub.reachable = [url("https://10.0.0.9:32400")]
        let known = AuthFixtures.choice(name: "Home", id: "m1", uris: [lan, remote])

        let outcome = await ServerDiscovery(token: "tok", environment: stub.environment).connect(toAddress: address, known: known) { _ in }

        guard case .connected = outcome else { Issue.record("expected connected"); return }
        #expect(stub.saved.value == [Saved(uri: url("https://10.0.0.9:32400"), name: "Home", machineIdentifier: "m1", candidates: [url(lan), url(remote)])])
    }

    @Test func aTypedAddressThatNeverAnswersFailsWithAdvice() async throws {
        let stub = DiscoveryStub()
        let address = try #require(ServerAddress.parse("10.0.0.9"))

        let outcome = await ServerDiscovery(token: "tok", environment: stub.environment).connect(toAddress: address, known: nil) { _ in }

        guard case .failed(let message) = outcome else { Issue.record("expected failed"); return }
        #expect(message == "Couldn't reach 10.0.0.9. Check the address and that the server is online.")
    }

    @Test func routeMeasurementsStreamInAsEveryProbeSettles() async {
        let stub = DiscoveryStub()
        stub.latency = [url(lan): 12, url(remote): 80]
        let targets = [
            RouteProbeTarget(serverID: "a", routeIndex: 0, url: url(lan)),
            RouteProbeTarget(serverID: "a", routeIndex: 1, url: url(remote)),
            RouteProbeTarget(serverID: "b", routeIndex: 0, url: url("http://dead:1")),
        ]

        let measurements = await authCollect(ServerDiscovery(token: "tok", environment: stub.environment).measureRoutes(targets))

        func milliseconds(_ server: String, _ route: Int) -> Int? {
            measurements.first { $0.serverID == server && $0.routeIndex == route }.flatMap(\.milliseconds)
        }
        #expect(milliseconds("a", 0) == 12)
        #expect(milliseconds("a", 1) == 80)
        #expect(milliseconds("b", 0) == nil)
        #expect(measurements.count == 3)
    }

    @Test func rememberedAddressesDropTheDefaultPort() throws {
        let plain = try #require(ServerAddress.parse("192.168.1.5"))
        let custom = try #require(ServerAddress.parse("https://nas.local:8443"))
        #expect(RememberedServerAddress.displayText(for: plain) == "192.168.1.5")
        #expect(RememberedServerAddress.displayText(for: custom) == "nas.local:8443")

        let suite = "auth-remembered-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        RememberedServerAddress.remember(custom, in: defaults)
        #expect(defaults.string(forKey: "last_server_ip") == "nas.local:8443")
    }
}

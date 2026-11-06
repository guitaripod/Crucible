import Foundation
import Testing
@testable import CrucibleCore

@MainActor
struct SettingsServerConnectionTests {
    private static let local = URL(string: "http://192.168.1.10:32400")!
    private static let remote = URL(string: "https://203-0-113-7.abc.plex.direct:32400")!
    private static let relay = URL(string: "https://203-0-113-7.abc.plex.direct:8443")!
    private static let tailscale = URL(string: "http://100.64.0.9:32400")!

    private static func connection(active: URL = local, candidates: [URL]? = nil) -> PlexConnection {
        PlexConnection(serverURI: active, serverName: "Marcus-PC", machineIdentifier: "machine-1", authToken: "token", clientIdentifier: "client", candidateURIs: candidates)
    }

    private static func resource(owned: Bool = true) throws -> PlexResource {
        let json = """
        {"name":"Marcus-PC","provides":"server","clientIdentifier":"machine-1","owned":\(owned),
         "connections":[
           {"uri":"\(local.absoluteString)","address":"192.168.1.10","port":32400,"protocol":"http","local":true,"relay":false},
           {"uri":"\(relay.absoluteString)","address":"203.0.113.7","port":8443,"protocol":"https","local":false,"relay":true}
         ]}
        """
        return try JSONDecoder().decode(PlexResource.self, from: Data(json.utf8))
    }

    private static func environment(
        connection: PlexConnection?,
        probes: [URL: ConnectionProbe?],
        resource: PlexResource? = nil
    ) -> ServerConnectionModel.Environment {
        ServerConnectionModel.Environment(
            connection: { connection },
            probe: { url, _ in probes[url] ?? nil },
            serverResource: { _ in resource }
        )
    }

    private func finish(_ model: ServerConnectionModel) async {
        await withCheckedContinuation { continuation in
            model.onFinish = { continuation.resume() }
            model.runTest()
        }
    }

    @Test func routesStartWithTheActiveURLWhenItIsNotAdvertised() {
        let model = ServerConnectionModel(environment: Self.environment(connection: Self.connection(active: Self.local, candidates: [Self.remote]), probes: [:]))
        #expect(model.routes == [Self.local, Self.remote])

        let pinnedElsewhere = PlexConnection(serverURI: Self.tailscale, serverName: "x", machineIdentifier: "m", authToken: "t", clientIdentifier: "c", candidateURIs: [Self.remote])
        let other = ServerConnectionModel(environment: Self.environment(connection: pinnedElsewhere, probes: [:]))
        #expect(other.routes == [Self.tailscale, Self.remote])
    }

    @Test func withoutAConnectionTheRouteListIsTheLocalhostFallback() {
        let model = ServerConnectionModel(environment: Self.environment(connection: nil, probes: [:]))
        #expect(model.routes == [URL(string: "http://localhost:32400")!])
        #expect(model.card.name == "Plex Server")
        #expect(model.authToken == nil)
    }

    @Test func beforeAnyProbeTheCardIsCheckingAndRowsShowAnEllipsis() {
        let model = ServerConnectionModel(environment: Self.environment(connection: Self.connection(candidates: [Self.local, Self.remote]), probes: [:]))
        #expect(model.card.status == "Checking connection…")
        #expect(model.card.tone == .neutral)
        #expect(model.card.subtitle == "Plex Media Server")
        #expect(model.routeRows.map(\.latencyText) == ["…", "…"])
        #expect(!model.isTesting)
    }

    @Test func aFullRunFillsTheCardAndRows() async throws {
        let probes: [URL: ConnectionProbe?] = [
            Self.local: ConnectionProbe(latencyMs: 12, version: "1.41.0", machineIdentifier: "machine-1"),
            Self.relay: ConnectionProbe(latencyMs: 180, version: "1.41.0", machineIdentifier: "machine-1"),
            Self.remote: nil,
        ]
        let model = ServerConnectionModel(environment: Self.environment(
            connection: Self.connection(candidates: [Self.local, Self.relay, Self.remote]),
            probes: probes,
            resource: try Self.resource()
        ))
        await finish(model)

        #expect(!model.isTesting)
        #expect(model.card.status == "Connected · Local · HTTP · 12 ms")
        #expect(model.card.tone == .ok)
        #expect(model.card.subtitle == "Plex Media Server 1.41.0 · Owned by you")

        let rows = model.routeRows
        #expect(rows.map(\.kind) == [.local, .remote, .relay])
        #expect(rows.map(\.kindTitle) == ["Local", "Remote", "Plex Relay"])
        #expect(rows.map(\.latencyText) == ["12 ms", "Unreachable", "180 ms"])
        #expect(rows.map(\.isInUse) == [true, false, false])
        #expect(rows.map(\.showsWarning) == [false, false, true])
        #expect(rows.map(\.isDimmed) == [false, true, true])
        #expect(rows[0].detail == Self.local.absoluteString)
        #expect(rows[0].detailIsMonospaced)
        #expect(rows[2].detail == "Bandwidth limited, may force transcoding")
        #expect(!rows[2].detailIsMonospaced)
    }

    @Test func sharedServersAreLabelledAsSuch() async throws {
        let model = ServerConnectionModel(environment: Self.environment(
            connection: Self.connection(),
            probes: [Self.local: ConnectionProbe(latencyMs: 5, version: nil, machineIdentifier: nil)],
            resource: try Self.resource(owned: false)
        ))
        await finish(model)
        #expect(model.card.subtitle == "Plex Media Server · Shared with you")
    }

    @Test func anUnreachableActiveRouteIsAFailureWithItsKind() async {
        let model = ServerConnectionModel(environment: Self.environment(connection: Self.connection(), probes: [Self.local: nil]))
        await finish(model)
        #expect(model.card.status == "Unreachable · Local")
        #expect(model.card.tone == .failure)
    }

    @Test func httpsRoutesAreCalledOutOnTheCard() async {
        let secure = Self.connection(active: Self.remote, candidates: [Self.remote])
        let model = ServerConnectionModel(environment: Self.environment(
            connection: secure,
            probes: [Self.remote: ConnectionProbe(latencyMs: 40, version: nil, machineIdentifier: nil)]
        ))
        await finish(model)
        #expect(model.card.status == "Connected · Remote · HTTPS · 40 ms")
    }

    @Test func theVersionComesFromTheActiveRouteWhenSeveralAnswer() async {
        let model = ServerConnectionModel(environment: Self.environment(
            connection: Self.connection(candidates: [Self.local, Self.tailscale]),
            probes: [
                Self.tailscale: ConnectionProbe(latencyMs: 30, version: "1.40.0", machineIdentifier: nil),
                Self.local: ConnectionProbe(latencyMs: 4, version: "1.41.0", machineIdentifier: nil),
            ]
        ))
        await finish(model)
        #expect(model.card.subtitle == "Plex Media Server 1.41.0")
    }

    @Test func changeFiresAtTheStartOnEveryProbeAndAtTheEnd() async {
        let model = ServerConnectionModel(environment: Self.environment(
            connection: Self.connection(candidates: [Self.local, Self.remote]),
            probes: [Self.local: ConnectionProbe(latencyMs: 4, version: nil, machineIdentifier: nil)]
        ))
        var changes = 0
        model.onChange = { changes += 1 }
        await finish(model)
        #expect(changes == 4)
    }

    @Test func startIfNeededProbesOnlyOnce() async {
        let model = ServerConnectionModel(environment: Self.environment(
            connection: Self.connection(),
            probes: [Self.local: ConnectionProbe(latencyMs: 4, version: nil, machineIdentifier: nil)]
        ))
        var finished = 0
        await withCheckedContinuation { continuation in
            model.onFinish = {
                finished += 1
                continuation.resume()
            }
            model.startIfNeeded()
        }
        model.startIfNeeded()
        #expect(finished == 1)
        #expect(!model.isTesting)
    }

    @Test func testingFlagIsRaisedWhileProbesRun() {
        let model = ServerConnectionModel(environment: Self.environment(connection: Self.connection(), probes: [:]))
        model.runTest()
        #expect(model.isTesting)
        #expect(model.probeState(for: Self.local) == .probing)
        model.stop()
    }

    @Test func containerNetworkRoutesStayHiddenUnlessTheyAnswer() async {
        let bridge = URL(string: "https://172-17-0-1.abc.plex.direct:32400")!
        let answering = URL(string: "http://172.18.0.1:32400")!
        #expect(ConnectionRoute.isContainerBridge(bridge))
        #expect(!ConnectionRoute.isContainerBridge(URL(string: "http://172.16.0.4:32400")!))
        #expect(!ConnectionRoute.isContainerBridge(Self.local))
        let model = ServerConnectionModel(environment: Self.environment(
            connection: Self.connection(candidates: [bridge, Self.remote, answering]),
            probes: [Self.local: ConnectionProbe(latencyMs: 4, version: nil, machineIdentifier: "machine-1"), answering: ConnectionProbe(latencyMs: 9, version: nil, machineIdentifier: "machine-1")]
        ))
        #expect(!model.routes.contains(bridge))
        await finish(model)
        #expect(model.routes == [Self.local, answering, Self.remote], "an answering container route is listed, one that does not is not")
    }

    @Test func theListKeepsItsOrderWhicheverRouteIsInUse() {
        let atHome = ServerConnectionModel(environment: Self.environment(connection: Self.connection(active: Self.local, candidates: [Self.remote, Self.tailscale]), probes: [:]))
        let away = ServerConnectionModel(environment: Self.environment(connection: Self.connection(active: Self.tailscale, candidates: [Self.local, Self.remote]), probes: [:]))
        #expect(atHome.routes == away.routes)
        #expect(atHome.routes == [Self.local, Self.tailscale, Self.remote])
    }
}

import Foundation
import Testing
@testable import CrucibleCore

/// Which route the app takes as the network changes: home when it answers, the tailnet or a remote route when home is gone, never
/// the relay when a direct route answers, and a route the viewer picked until the network changes.
@MainActor
@Suite(.serialized)
struct ServerRouteMonitorTests {
    private nonisolated static let local = URL(string: "http://192.168.77.10:32400")!
    private nonisolated static let localHTTPS = URL(string: "https://192-168-77-10.abc123.plex.direct:32400")!
    private nonisolated static let tailscale = URL(string: "http://100.88.7.9:32400")!
    private nonisolated static let remote = URL(string: "https://203-0-113-77.abc123.plex.direct:32400")!
    private nonisolated static let relay = URL(string: "https://203-0-113-77.abc123.plex.direct:8443")!
    private nonisolated static let machine = "route-tests-machine"

    private nonisolated static func kind(_ url: URL) -> ConnectionKind {
        url == relay ? .relay : ConnectionRoute.kind(of: url)
    }

    @Test func aLostRouteMovesToTheBestRouteThatAnswers() {
        let routes = [Self.local, Self.tailscale, Self.remote]
        #expect(RoutePlan.decide(current: Self.local, routes: routes, answering: [Self.tailscale, Self.remote], kind: Self.kind, preferLocal: true)
            == .move(to: Self.tailscale, because: .lost))
        #expect(RoutePlan.decide(current: Self.local, routes: routes, answering: [], kind: Self.kind, preferLocal: true) == .unreachable)
    }

    @Test func homeTakesOverWhenItAnswersAndLocalIsPreferred() {
        let routes = [Self.local, Self.tailscale, Self.remote]
        #expect(RoutePlan.decide(current: Self.tailscale, routes: routes, answering: Set(routes), kind: Self.kind, preferLocal: true)
            == .move(to: Self.local, because: .better))
        #expect(RoutePlan.decide(current: Self.remote, routes: routes, answering: [Self.tailscale, Self.remote], kind: Self.kind, preferLocal: true)
            == .move(to: Self.tailscale, because: .better))
        #expect(RoutePlan.decide(current: Self.tailscale, routes: routes, answering: Set(routes), kind: Self.kind, preferLocal: false) == .stay)
    }

    @Test func aDirectRouteAlwaysReplacesTheRelay() {
        let routes = [Self.remote, Self.relay]
        #expect(RoutePlan.decide(current: Self.relay, routes: routes, answering: Set(routes), kind: Self.kind, preferLocal: false)
            == .move(to: Self.remote, because: .better))
    }

    @Test func aRouteOfTheSameTierOrAPickedRouteStays() {
        let routes = [Self.localHTTPS, Self.local, Self.remote]
        #expect(RoutePlan.decide(current: Self.local, routes: routes, answering: Set(routes), kind: Self.kind, preferLocal: true) == .stay)
        #expect(RoutePlan.decide(current: Self.remote, routes: routes, answering: Set(routes), kind: Self.kind, preferLocal: true, chosen: Self.remote) == .stay)
        #expect(RoutePlan.decide(current: Self.remote, routes: routes, answering: [Self.local], kind: Self.kind, preferLocal: true, chosen: Self.remote)
            == .move(to: Self.local, because: .lost))
    }

    @Test func routesAreOrderedByTierKeepingTheirOrderWithinOne() {
        let mixed = [Self.relay, Self.remote, Self.tailscale, Self.localHTTPS, Self.local, Self.local]
        #expect(RoutePlan.ordered(mixed, kind: Self.kind, allowRelay: false) == [Self.localHTTPS, Self.local, Self.tailscale, Self.remote])
        #expect(RoutePlan.ordered(mixed, kind: Self.kind, allowRelay: true).last == Self.relay)
        #expect(RoutePlan.ordered([Self.relay], kind: Self.kind, allowRelay: false) == [Self.relay], "a relay is kept when it is all there is")
    }

    private final class Recorder: @unchecked Sendable {
        var pinned: URL
        var saved: [URL] = []
        var answering: Set<URL>
        var tailnet: [URL] = []
        var preferLocal = true
        var isDemo = false

        init(pinned: URL, answering: Set<URL>) {
            self.pinned = pinned
            self.answering = answering
        }
    }

    private func makeMonitor(_ recorder: Recorder, candidates: [URL]) -> ServerRouteMonitor {
        ServerRouteMonitor(environment: ServerRouteMonitor.Environment(
            connection: {
                PlexConnection(serverURI: recorder.pinned, serverName: "Route Tests", machineIdentifier: Self.machine, authToken: "token", clientIdentifier: "client", candidateURIs: candidates)
            },
            probe: { url, _, machine, _ in machine == Self.machine && recorder.answering.contains(url) },
            advertised: { _ in (candidates, [Self.relay]) },
            tailnet: { _ in recorder.tailnet },
            preferences: { (recorder.preferLocal, false) },
            isDemo: { recorder.isDemo },
            save: { pinned, routes in
                if let pinned { recorder.pinned = pinned }
                recorder.saved = routes
            },
            now: Date.init
        ))
    }

    @Test func comingHomeMovesEveryClientToTheHomeRoute() async {
        let recorder = Recorder(pinned: Self.remote, answering: [Self.local, Self.remote])
        let monitor = makeMonitor(recorder, candidates: [Self.local, Self.remote, Self.relay])
        let client = APIClient(baseURL: Self.remote, token: "token")
        var heard: [ServerRouteMonitor.Move] = []
        monitor.observe { heard.append($0) }

        let decision = await monitor.checkNow(reason: "test")

        #expect(decision == .move(to: Self.local, because: .better))
        #expect(recorder.pinned == Self.local)
        #expect(recorder.saved == [Self.local, Self.remote])
        #expect(await client.baseURL == Self.local)
        #expect(heard.map(\.route) == [Self.local])
        #expect(monitor.lastMove?.reason == .better)
    }

    @Test func leavingHomeMovesToTheTailnetRouteFoundThere() async {
        let recorder = Recorder(pinned: Self.local, answering: [Self.tailscale])
        recorder.tailnet = [Self.tailscale]
        let monitor = makeMonitor(recorder, candidates: [Self.local, Self.remote])

        #expect(await monitor.checkNow(reason: "test") == .move(to: Self.tailscale, because: .lost))
        #expect(recorder.pinned == Self.tailscale)
        #expect(recorder.saved.contains(Self.tailscale), "the tailnet route is remembered with the others")
    }

    @Test func aRoutePickedByTheViewerHoldsUntilTheNetworkChanges() async {
        let recorder = Recorder(pinned: Self.local, answering: [Self.local, Self.remote])
        let monitor = makeMonitor(recorder, candidates: [Self.local, Self.remote])

        #expect(await monitor.use(Self.remote))
        #expect(recorder.pinned == Self.remote)
        #expect(await monitor.checkNow(reason: "test") == .stay)

        monitor.networkChanged("wifi-a")
        monitor.networkChanged("wifi-b")
        #expect(await monitor.checkNow(reason: "test") == .move(to: Self.local, because: .better))
        #expect(!(await monitor.use(Self.tailscale)), "a route that does not answer is not taken")
        #expect(recorder.pinned == Self.local)
    }

    @Test func theDemoIsLeftAlone() async {
        let recorder = Recorder(pinned: Self.remote, answering: [Self.local, Self.remote])
        recorder.isDemo = true
        let monitor = makeMonitor(recorder, candidates: [Self.local, Self.remote])
        #expect(await monitor.checkNow(reason: "test") == .stay)
        #expect(recorder.pinned == Self.remote)
    }

    @Test func aClientOfAnotherServerDoesNotFollowAMove() async {
        let elsewhere = URL(string: "http://10.55.0.3:32400")!
        let other = APIClient(baseURL: elsewhere, token: "token")
        let follower = APIClient(baseURL: URL(string: "http://10.55.0.4:32400")!, token: "token")
        APIClient.move(to: URL(string: "http://10.55.0.5:32400")!, replacing: [URL(string: "http://10.55.0.4:32400")!])
        #expect(await other.baseURL == elsewhere)
        #expect(await follower.baseURL == URL(string: "http://10.55.0.5:32400")!)
    }
}

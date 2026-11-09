import Foundation
import Testing
@testable import CrucibleCore

/// Seerr follows the Plex server between the home network and the tailnet, and the client moves to an address that
/// answers when the one in use stops, keeping the session.
struct SeerrRoutesTests {
    private let lan = URL(string: "http://192.168.1.20:32400")!
    private let lanDirect = URL(string: "https://192-168-1-20.0123abcd.plex.direct:32400")!
    private let tailnet = URL(string: "http://100.91.211.44:32400")!
    private let magicDNS = URL(string: "http://arch.tail1234.ts.net:32400")!
    private let publicDirect = URL(string: "https://84-12-3-4.0123abcd.plex.direct:32400")!
    private let bridge = URL(string: "http://172.17.0.2:32400")!

    @Test func aSeerrOnThePlexComputerIsTriedAtEveryHomeAndTailnetAddressOfTheServer() {
        let ordered = SeerrRoutes.ordered(
            address: URL(string: "http://192.168.1.20:5055")!,
            remembered: [],
            serverRoutes: [lanDirect, publicDirect, bridge, tailnet, magicDNS],
            serverInUse: lanDirect
        ).map(\.absoluteString)
        #expect(ordered == ["http://192.168.1.20:5055", "http://100.91.211.44:5055", "http://arch.tail1234.ts.net:5055"])
    }

    @Test func awayFromHomeTheAddressOfTheRoutePlexUsesLeads() {
        let ordered = SeerrRoutes.ordered(
            address: URL(string: "http://192.168.1.20:5055")!,
            remembered: [],
            serverRoutes: [lan, tailnet],
            serverInUse: tailnet
        ).map(\.absoluteString)
        #expect(ordered.first == "http://100.91.211.44:5055")
        #expect(ordered.contains("http://192.168.1.20:5055"))
    }

    @Test func overTheInternetAnAddressTheViewerGaveLeadsAndHomeOnesFollow() {
        let ordered = SeerrRoutes.ordered(
            address: URL(string: "http://192.168.1.20:5055")!,
            remembered: [URL(string: "https://requests.example.com")!],
            serverRoutes: [lan, tailnet, publicDirect],
            serverInUse: publicDirect
        ).map(\.absoluteString)
        #expect(ordered.first == "https://requests.example.com")
        #expect(!ordered.contains { $0.contains("84.12.3.4") }, "a public plain-HTTP address is never derived")
    }

    @Test func aSeerrOnAnotherComputerKeepsItsOwnAddresses() {
        let nas = URL(string: "http://192.168.1.50:5055")!
        #expect(!SeerrRoutes.followsServer(nas, serverRoutes: [lan, tailnet]))
        let ordered = SeerrRoutes.ordered(address: nas, remembered: [nas], serverRoutes: [lan, tailnet], serverInUse: tailnet)
        #expect(ordered == [nas])
    }

    @Test func discoveryLooksOnTheTailnetToo() {
        let candidates = SeerrDiscovery.candidates(serverRoutes: [tailnet, magicDNS, publicDirect, bridge]).map(\.absoluteString)
        #expect(candidates == ["http://100.91.211.44:5055", "http://arch.tail1234.ts.net:5055"])
    }

    @Test func rememberedAddressesStayFewAndUnrepeated() {
        let a = URL(string: "http://a:5055")!, b = URL(string: "http://b:5055")!
        let kept = (0..<6).reduce([URL]()) { list, index in SeerrRoutes.remembering(URL(string: "http://h\(index):5055")!, in: list) }
        #expect(kept.count == SeerrRoutes.rememberedLimit)
        #expect(SeerrRoutes.remembering(a, in: [b, a]) == [a, b])
    }

    @Test func aConnectionSavedBeforeRoutesRemembersItsOwnAddress() throws {
        let json = #"{"address":"http:\/\/192.168.1.20:5055","auth":"plex","partialRequests":true}"#
        let connection = try JSONDecoder().decode(SeerrConnection.self, from: Data(json.utf8))
        #expect(connection.remembered == [URL(string: "http://192.168.1.20:5055")!])
    }

    @Test func theClientMovesToAnAddressThatAnswersAndKeepsTheSession() async throws {
        let home = URL(string: "http://192.168.1.20:5055")!
        let away = URL(string: "http://100.91.211.44:5055")!
        let moves = Moves()
        let transport = SeerrTransport { request in
            guard request.url?.host == "100.91.211.44" else { throw SeerrError.unreachable }
            let path = request.url?.path ?? ""
            let body = path.hasSuffix("/status") ? #"{"version":"2.7.0"}"# : SeerrFixtures.user
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
        }
        let vault = SeerrVault.memory()
        let target = SeerrTarget(address: home, auth: .plex, secretKey: "seerr.routes")
        vault.save(target.sessionKey, "abc")
        let client = SeerrClient(transport: transport, vault: vault, plexToken: { "t" }, isAwayFromHome: { false })
        await client.use(target, alternates: [home, away])
        await client.onAddressMove { moves.add($0) }
        let user = try await client.send(.me, as: SeerrUser.self)
        #expect(user.id == 7)
        #expect(await client.current?.address == away)
        #expect(moves.all == [away])
    }

    @Test func withNowhereElseToGoAwayFromHomeSaysTailscaleIsTheWay() async {
        let transport = SeerrTransport { _ in throw SeerrError.unreachable }
        let client = SeerrClient(transport: transport, vault: .memory(), plexToken: { "t" }, isAwayFromHome: { true })
        await client.use(SeerrFixtures.target(), alternates: [SeerrFixtures.base])
        await #expect(throws: SeerrError.awayFromHome) { try await client.send(.me, as: SeerrUser.self) }
    }

    @Test func aPublicAddressThatIsDownIsNotBlamedOnBeingAwayFromHome() async {
        let transport = SeerrTransport { _ in throw SeerrError.unreachable }
        let client = SeerrClient(transport: transport, vault: .memory(), plexToken: { "t" }, isAwayFromHome: { true })
        let target = SeerrTarget(address: URL(string: "https://requests.example.com")!, auth: .plex, secretKey: "seerr.public")
        await client.use(target, alternates: [target.address])
        await #expect(throws: SeerrError.unreachable) { try await client.send(.me, as: SeerrUser.self) }
    }

    @Test func discoveryPrefersAFinishedSeerrOverAnUnfinishedOne() async {
        let unfinished = URL(string: "http://192.168.1.20:5055")!
        let finished = URL(string: "http://192.168.1.21:5055")!
        let transport = SeerrTransport { request in
            let done = request.url?.host == "192.168.1.21"
            let body = request.url?.path.hasSuffix("/status") == true ? #"{"version":"3.5.1"}"# : #"{"initialized":\#(done),"mediaServerType":\#(done ? 1 : 4)}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
        }
        let client = SeerrClient(transport: transport, vault: .memory(), plexToken: { "t" }, isAwayFromHome: { false })
        let survey = await SeerrDiscovery.survey([unfinished, finished], client: client)
        guard case .ready(let address, _) = survey else { return #expect(Bool(false), "a finished Seerr was not preferred: \(survey)") }
        #expect(address == finished)
        #expect(await SeerrDiscovery.survey([unfinished], client: client) == .needsSetup(unfinished))
    }
}

private final class Moves: @unchecked Sendable {
    private let lock = NSLock()
    private var moves: [URL] = []
    func add(_ url: URL) { lock.withLock { moves.append(url) } }
    var all: [URL] { lock.withLock { moves } }
}

import Foundation
import Testing
@testable import CrucibleCore

struct SettingsAddServerTests {
    private static let secure = URL(string: "https://192.168.1.20:32400")!
    private static let plain = URL(string: "http://192.168.1.20:32400")!
    private static let tailscale = URL(string: "http://100.64.0.9:32400")!

    private static func resources(_ json: String = "[]") throws -> [PlexResource] {
        try JSONDecoder().decode([PlexResource].self, from: Data(json.utf8))
    }

    private static let knownServer = """
    [{"name":"Marcus-PC","provides":"server,player","clientIdentifier":"machine-1","owned":true,
      "connections":[
        {"uri":"\(plain.absoluteString)","address":"192.168.1.20","port":32400,"protocol":"http","local":true,"relay":false},
        {"uri":"\(tailscale.absoluteString)","address":"100.64.0.9","port":32400,"protocol":"http","local":false,"relay":false},
        {"uri":"\(tailscale.absoluteString)","address":"100.64.0.9","port":32400,"protocol":"http","local":false,"relay":false}
      ]},
     {"name":"Marcus-iPhone","provides":"player","clientIdentifier":"machine-1","owned":true,"connections":[]}]
    """

    private static func environment(
        answering: [URL: String?],
        resources: [PlexResource] = [],
        existing: PlexConnection? = nil
    ) -> AddServerLookup.Environment {
        AddServerLookup.Environment(
            probe: { url, _ in
                guard let entry = answering[url] else { return nil }
                return ConnectionProbe(latencyMs: 3, version: "1.41", machineIdentifier: entry)
            },
            resources: { _ in resources },
            existingConnection: { existing }
        )
    }

    @Test func theFirstCandidateThatAnswersWins() async {
        let found = await AddServerLookup.find(
            among: [Self.secure, Self.plain],
            token: "t",
            environment: Self.environment(answering: [Self.plain: "machine-1"])
        )
        #expect(found?.url == Self.plain)
        #expect(found?.machineIdentifier == "machine-1")
    }

    @Test func aRouteThatAnswersWithoutAMachineIdentifierIsSkipped() async {
        let found = await AddServerLookup.find(
            among: [Self.secure, Self.plain],
            token: "t",
            environment: Self.environment(answering: [Self.secure: nil, Self.plain: "machine-1"])
        )
        #expect(found?.url == Self.plain)
    }

    @Test func nothingAnsweringFindsNothing() async {
        let found = await AddServerLookup.find(among: [Self.secure, Self.plain], token: "t", environment: Self.environment(answering: [:]))
        #expect(found == nil)
    }

    @Test func plexTVSuppliesTheNameAndOtherRoutesWithoutDuplicates() async throws {
        let found = await AddServerLookup.find(
            among: [Self.plain],
            token: "t",
            environment: Self.environment(answering: [Self.plain: "machine-1"], resources: try Self.resources(Self.knownServer))
        )
        #expect(found?.name == "Marcus-PC")
        #expect(found?.candidates == [Self.tailscale])
    }

    @Test func aKnownConnectionLendsItsNameAndRoutesWhenPlexTVDoesNotKnowTheServer() async {
        let existing = PlexConnection(serverURI: Self.tailscale, serverName: "Den Server", machineIdentifier: "machine-1", authToken: "t", clientIdentifier: "c", candidateURIs: [Self.tailscale, Self.secure])
        let found = await AddServerLookup.find(
            among: [Self.plain],
            token: "t",
            environment: Self.environment(answering: [Self.plain: "machine-1"], existing: existing)
        )
        #expect(found?.name == "Den Server")
        #expect(found?.candidates == [Self.tailscale, Self.secure])
    }

    @Test func aConnectionToADifferentServerIsIgnored() async {
        let existing = PlexConnection(serverURI: Self.tailscale, serverName: "Other", machineIdentifier: "machine-9", authToken: "t", clientIdentifier: "c")
        let found = await AddServerLookup.find(
            among: [Self.plain],
            token: "t",
            environment: Self.environment(answering: [Self.plain: "machine-1"], existing: existing)
        )
        #expect(found?.name == "192.168.1.20")
        #expect(found?.candidates.isEmpty == true)
    }

    @Test func candidatesTryHTTPSFirstUnlessTheSchemeIsTyped() {
        #expect(AddServerLookup.candidates(from: "192.168.1.20")?.map(\.absoluteString) == ["https://192.168.1.20:32400", "http://192.168.1.20:32400"])
        #expect(AddServerLookup.candidates(from: "http://nas.local:1234")?.map(\.absoluteString) == ["http://nas.local:1234"])
        #expect(AddServerLookup.candidates(from: "not a server") == nil)
        #expect(AddServerLookup.candidates(from: "") == nil)
    }

    @Test func notFoundMessageTrimsTheInput() {
        #expect(AddServerLookup.notFoundMessage(for: "  10.0.0.5 \n").hasPrefix("Couldn't find a Plex server at 10.0.0.5."))
    }
}

import Foundation
import Testing
@testable import CrucibleCore

struct CompanionTests {
    private static let secret = Data(repeating: 1, count: 16)

    @Test func proofsMatchWhatTheServerComputes() {
        #expect(CompanionProof.server(secret: Self.secret, fingerprint: "ab12", deviceNonce: "dn", serverNonce: "sn") == "52332ef92a0c052dc12c4aa512604632136ebd2dd837fe4d0a3eb56c0b788336")
        #expect(CompanionProof.device(secret: Self.secret, fingerprint: "ab12", deviceNonce: "dn", serverNonce: "sn") == "476d5e66beda9d7f2bd25fb30fc206e259411d14a04e81b7054535544d1e51c1")
        #expect(CompanionProof.matches("abc", "abc"))
        #expect(!CompanionProof.matches("abc", "abd"))
        #expect(!CompanionProof.matches("abc", "ab"))
    }

    @Test func aQRCodeLinkBecomesAnInvite() throws {
        let fingerprint = String(repeating: "c0", count: 32)
        let url = try #require(URL(string: "crucible://pair?v=1&name=arch%20box&hosts=192.168.1.5:32500,100.64.0.2:32500&secret=AEAQCAIBAEAQCAIBAEAQCAIBAE&fp=\(fingerprint)"))
        let invite = try #require(CompanionInvite(url: url))
        #expect(invite.name == "arch box")
        #expect(invite.hosts == ["192.168.1.5:32500", "100.64.0.2:32500"])
        #expect(invite.secret == Self.secret)
        #expect(invite.fingerprint == fingerprint)
        #expect(invite.secretID == "31d9e8154cbc91a2")
        #expect(CompanionInvite(url: URL(string: "crucible://pair?hosts=a:1&secret=SHORT")!) == nil)
        #expect(CompanionInvite(url: URL(string: "crucible://pair?hosts=evil.com/x?y&secret=AEAQCAIBAEAQCAIBAEAQCAIBAE")!) == nil)
        #expect(CompanionInvite(url: URL(string: "crucible://item/12")!) == nil)
    }

    @Test func aTypedCodeIgnoresDashesAndCase() throws {
        let invite = try #require(CompanionInvite(code: "aeaq-caib-aeaq-caib-aeaq-caib-ae", hosts: ["arch:32500"]))
        #expect(invite.secret == Self.secret)
        #expect(invite.fingerprint == nil)
        #expect(CompanionInvite(code: "ABCD", hosts: ["arch:32500"]) == nil)
    }

    @Test func theCompanionListensBesidePlex() {
        #expect(CompanionPairing.hostBesidePlex(URL(string: "http://192.168.1.5:32400")) == "192.168.1.5:32500")
        #expect(CompanionPairing.hostBesidePlex(URL(string: "https://192-168-1-5.abc.plex.direct:32400")) == "192-168-1-5.abc.plex.direct:32500")
        #expect(CompanionPairing.hostBesidePlex(URL(string: "http://[fd00::5]:32400")) == "[fd00::5]:32500")
        #expect(CompanionPairing.hostBesidePlex(nil) == nil)
    }

    @Test func aRecapDrawsOnlyOnWatchedEpisodesBeforeTheNextOne() throws {
        let json = #"[{"ratingKey":"1","type":"episode","title":"a","parentIndex":1,"index":1,"viewCount":1},{"ratingKey":"2","type":"episode","title":"b","parentIndex":1,"index":2,"viewCount":1},{"ratingKey":"3","type":"episode","title":"c","parentIndex":1,"index":3},{"ratingKey":"4","type":"episode","title":"d","parentIndex":1,"index":4,"viewCount":2}]"#
        let episodes = try JSONDecoder().decode([PlexMetadata].self, from: Data(json.utf8))
        #expect(PreviouslyOn.finished(in: episodes, before: episodes[2]) == ["1", "2"])
        #expect(PreviouslyOn.finished(in: episodes, before: nil) == ["1", "2", "4"])
    }
}

/// Pairs with a running `crucible-server` and asks it for a recap; runs only when `CRUCIBLE_SERVER_E2E_CODE`,
/// `CRUCIBLE_SERVER_E2E_HOST`, `CRUCIBLE_SERVER_E2E_PLEX_TOKEN` and `CRUCIBLE_SERVER_E2E_FINISHED` are set.
struct CompanionLiveTests {
    private static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: environment["CRUCIBLE_SERVER_E2E_CODE"] != nil))
    func pairsAndGetsARecapFromARunningServer() async throws {
        let environment = Self.environment
        let invite = try #require(CompanionInvite(code: environment["CRUCIBLE_SERVER_E2E_CODE"] ?? "", hosts: ["10.255.255.1:32500", environment["CRUCIBLE_SERVER_E2E_HOST"] ?? ""]))
        let server = try await CompanionPairing.pair(invite, deviceName: "Core Tests", platform: "test", machineIdentifier: nil)
        #expect(server.fingerprint.count == 64)
        let client = CompanionClient(server: server, plexToken: environment["CRUCIBLE_SERVER_E2E_PLEX_TOKEN"] ?? "")
        let hello = try await client.hello()
        #expect(hello.fingerprint == server.fingerprint)
        let finished = (environment["CRUCIBLE_SERVER_E2E_FINISHED"] ?? "").split(separator: ",").map(String.init)
        let recap = try await client.recap(finished: finished)
        #expect(!recap.text.isEmpty)
        print("RECAP", recap.text, recap.basedOn)
        let impostor = CompanionClient(server: CompanionServer(name: server.name, hosts: server.hosts, fingerprint: String(repeating: "0", count: 64), token: server.token, deviceID: server.deviceID), plexToken: client.plexToken)
        await #expect(throws: CompanionError.self) { try await impostor.hello() }
    }
}

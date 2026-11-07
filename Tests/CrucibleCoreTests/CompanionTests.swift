import Foundation
import Network
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

    @Test func aLinkOnlyNamesHostsOnTheHomeNetworkOrTailnet() throws {
        for host in ["192.168.1.5:32500", "10.0.0.2:32500", "172.20.0.5:32500", "100.64.0.2:32500", "169.254.1.1:32500", "[fd7a:115c:a1e0::1]:32500", "[fe80::1]:32500", "arch.local:32500", "192-168-1-5.abc.plex.direct:32500"] {
            #expect(CompanionInvite.isNearby(host), "\(host)")
        }
        for host in ["evil.example:32500", "8.8.8.8:32500", "172.32.0.1:32500", "100.128.0.1:32500", "[2001:db8::1]:32500", "8-8-8-8.abc.plex.direct:32500", "arch.tail1234.ts.net:32500"] {
            #expect(!CompanionInvite.isNearby(host), "\(host)")
        }
        let mixed = try #require(URL(string: "crucible://pair?v=1&hosts=evil.example:32500,192.168.1.5:32500&secret=AEAQCAIBAEAQCAIBAEAQCAIBAE"))
        #expect(CompanionInvite(url: mixed)?.hosts == ["192.168.1.5:32500"])
        #expect(CompanionInvite(url: URL(string: "crucible://pair?v=1&hosts=evil.example:32500&secret=AEAQCAIBAEAQCAIBAEAQCAIBAE")!) == nil)
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
        let shown = CompanionInvite(name: "Crucible Server", hosts: server.hosts, secret: CompanionInvite.newSecret(), fingerprint: nil)
        let television = Task { () async throws -> CompanionServer in
            try await CompanionPairing.waitForHandOff(shown, deviceName: "Living Room", platform: "tvos", machineIdentifier: nil, plexToken: client.plexToken, until: Date().addingTimeInterval(60))
        }
        try await Task.sleep(for: .seconds(3))
        try await client.addDevice(secret: shown.secret)
        let fromCode = try await television.value
        #expect(fromCode.fingerprint == server.fingerprint)
        #expect(fromCode.token != server.token)
        let handOn = { () async throws -> CompanionInvite in
            let secret = CompanionInvite.newSecret()
            try await client.addDevice(secret: secret)
            return CompanionInvite(name: server.name, hosts: server.hosts, secret: secret, fingerprint: server.fingerprint)
        }
        let nearby = try await handOn()
        await #expect(throws: CompanionError.self) {
            try await CompanionPairing.pair(nearby, deviceName: "No Plex", platform: "tvos", machineIdentifier: nil)
        }
        let fromPhone = try await CompanionPairing.pair(nearby, deviceName: "Bedroom", platform: "tvos", machineIdentifier: hello.plexMachineIdentifier, plexToken: client.plexToken)
        #expect(fromPhone.fingerprint == server.fingerprint)
        await #expect(throws: CompanionError.codeRefused) {
            try await CompanionPairing.pair(nearby, deviceName: "Again", platform: "tvos", machineIdentifier: nil, plexToken: client.plexToken)
        }
        #expect(hello.plexMachineIdentifier?.isEmpty == false)
        await #expect(throws: CompanionError.otherPlexServer) {
            try await CompanionPairing.pair(try await handOn(), deviceName: "Elsewhere", platform: "tvos", machineIdentifier: "another-plex-server", plexToken: client.plexToken)
        }
        let impostor = CompanionClient(server: CompanionServer(name: server.name, hosts: server.hosts, fingerprint: String(repeating: "0", count: 64), token: server.token, deviceID: server.deviceID), plexToken: client.plexToken)
        await #expect(throws: CompanionError.self) { try await impostor.hello() }
    }
}

/// The Apple TV hand-off: the add-device link, the one-line messages, and the channel over a real loopback connection.
struct CompanionHandOffTests {
    @Test func anAppleTVsCodeRoundTrips() throws {
        let invite = CompanionDeviceInvite(name: "Living Room", secret: Data(repeating: 7, count: 16))
        #expect(CompanionDeviceInvite(url: invite.link) == invite)
        #expect(CompanionDeviceInvite(url: URL(string: "crucible://add-device?secret=SHORT")!) == nil)
        #expect(CompanionDeviceInvite(url: URL(string: "crucible://pair?secret=AEAQCAIBAEAQCAIBAEAQCAIBAE")!) == nil)
        #expect(Base32.encode(Data(repeating: 1, count: 16)) == "AEAQCAIBAEAQCAIBAEAQCAIBAE")
    }

    @Test func aNearbyDeviceIsOnlyHandedHostsItCanReach() async {
        let server = CompanionServer(name: "arch", hosts: ["127.0.0.1:32500", "8.8.8.8:32500"], fingerprint: String(repeating: "ab", count: 32), token: "t", deviceID: "d")
        await #expect(throws: CompanionError.notNearby) {
            try await CompanionClient(server: server, plexToken: "p").inviteForNearbyDevice()
        }
    }

    @Test func anAppleTVsCodeExpiresWhenItStopsWaiting() throws {
        let deadline = Date(timeIntervalSince1970: 1_800_000_000.75)
        let invite = CompanionDeviceInvite(name: "Living Room", secret: Data(repeating: 7, count: 16), expires: deadline)
        let parsed = try #require(CompanionDeviceInvite(url: invite.link))
        #expect(parsed == invite)
        #expect(parsed.expires == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(!parsed.isExpired(now: deadline.addingTimeInterval(-60)))
        #expect(parsed.isExpired(now: deadline.addingTimeInterval(1)))
        #expect(!CompanionDeviceInvite(name: "Den", secret: Data(repeating: 7, count: 16)).isExpired())
    }

    @Test func aPairLinkRoundTripsWithItsFingerprint() throws {
        let invite = CompanionInvite(name: "arch", hosts: ["192.168.1.5:32500", "100.64.0.2:32500"], secret: Data(repeating: 1, count: 16), fingerprint: String(repeating: "ab", count: 32))
        #expect(CompanionInvite(url: invite.link) == invite)
    }

    @Test func helloAndAnswersSayOneLineEach() throws {
        let hello = String(decoding: CompanionHandOff.helloLine(deviceName: "Living\nRoom"), as: UTF8.self)
        #expect(hello.filter { $0 == "\n" }.count == 1)
        #expect(CompanionHandOff.deviceName(inHello: try #require(CompanionHandOff.firstLine(in: Data(hello.utf8)))) == "LivingRoom")
        #expect(CompanionHandOff.deviceName(inHello: "GET / HTTP/1.1") == nil)
        let invite = CompanionInvite(name: "arch", hosts: ["192.168.1.5:32500"], secret: Data(repeating: 2, count: 16), fingerprint: String(repeating: "cd", count: 32))
        let line = try #require(CompanionHandOff.firstLine(in: CompanionHandOff.answerLine(.invite(invite))))
        #expect(CompanionHandOff.answer(inLine: line) == .invite(invite))
        #expect(CompanionHandOff.answer(inLine: try #require(CompanionHandOff.firstLine(in: CompanionHandOff.answerLine(.declined)))) == .declined)
        #expect(CompanionHandOff.answer(inLine: "nonsense") == nil)
    }

    @Test func theChannelCarriesALineEachWayAndTimesOut() async throws {
        let queue = DispatchQueue(label: "handoff-test")
        let listener = try NWListener(using: .tcp, on: .any)
        let accepted = AsyncStream<NWConnection> { continuation in
            listener.newConnectionHandler = { continuation.yield($0) }
            listener.start(queue: queue)
        }
        var port: NWEndpoint.Port?
        for _ in 0..<100 {
            port = listener.port
            if let port, port.rawValue != 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let client = NWConnection(host: "127.0.0.1", port: try #require(port), using: .tcp)
        try await CompanionHandOffChannel.ready(client, queue: queue)
        var iterator = accepted.makeAsyncIterator()
        let server = try #require(await iterator.next())
        try await CompanionHandOffChannel.ready(server, queue: queue)
        try await CompanionHandOffChannel.send(CompanionHandOff.helloLine(deviceName: "Living Room"), on: client)
        let hello = try await CompanionHandOffChannel.readLine(from: server, timeout: .seconds(5))
        #expect(CompanionHandOff.deviceName(inHello: hello) == "Living Room")
        await #expect(throws: CompanionHandOffChannel.Failure.timedOut) {
            try await CompanionHandOffChannel.readLine(from: client, timeout: .milliseconds(300))
        }
        server.cancel()
        listener.cancel()
    }
}

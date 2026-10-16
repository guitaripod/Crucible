import Foundation
import Testing
@testable import CrucibleCore

private func url(_ string: String) -> URL { URL(string: string)! }

private final class TailnetStub: @unchecked Sendable {
    var onTailnet = true
    var names: [String: [String]] = [:]
    var identities: [URL: String] = [:]
    var devices: [TailscaleDevice] = []
    var deviceError: TailscaleAPIError?
    var token: String?

    let resolved = AuthLocked<[String]>([])
    let probed = AuthLocked<[URL]>([])
    let rejections = AuthLocked<Int>(0)

    var finder: TailnetServerFinder {
        TailnetServerFinder(environment: TailnetServerFinder.Environment(
            localAddress: { [self] in onTailnet ? "100.75.22.54" : nil },
            resolve: { [self] name in
                resolved.update { $0.append(name) }
                return names[name] ?? []
            },
            machineIdentifier: { [self] url in
                probed.update { $0.append(url) }
                return identities[url]
            },
            devices: { [self] _ in
                if let deviceError { throw deviceError }
                return devices
            },
            token: { [self] in token },
            tokenRejected: { [self] in rejections.update { $0 += 1 } }
        ))
    }
}

private func target(_ name: String, id: String, urls: [String] = []) -> TailnetTarget {
    TailnetTarget(id: id, name: name, knownURLs: urls.map(url))
}

struct TailnetAddressTests {
    @Test func theCarrierGradeNATRangeIsTheTailnet() {
        #expect(TailnetPresence.isTailnetAddress("100.64.0.1"))
        #expect(TailnetPresence.isTailnetAddress("100.91.211.44"))
        #expect(TailnetPresence.isTailnetAddress("100.127.255.255"))
        #expect(!TailnetPresence.isTailnetAddress("100.63.255.255"))
        #expect(!TailnetPresence.isTailnetAddress("100.128.0.1"))
        #expect(!TailnetPresence.isTailnetAddress("192.168.1.197"))
        #expect(!TailnetPresence.isTailnetAddress("100.91.211"))
        #expect(!TailnetPresence.isTailnetAddress("arch"))
    }
}

struct MagicDNSNameTests {
    @Test func aPlainNameIsItsOwnLabel() {
        #expect(MagicDNSName.candidates(forServerNamed: "Arch") == ["arch"])
        #expect(MagicDNSName.candidates(forServerNamed: "  arch  ") == ["arch"])
    }

    @Test func spacesBecomeHyphensOrNothingAndPunctuationIsDropped() {
        #expect(MagicDNSName.candidates(forServerNamed: "Marcus's Server") == ["marcuss-server", "marcussserver", "marcuss"])
        #expect(MagicDNSName.candidates(forServerNamed: "Plex Media Server") == ["plex-media-server", "plexmediaserver", "plex"])
        #expect(MagicDNSName.candidates(forServerNamed: "home_nas.local") == ["home-nas-local", "homenaslocal", "home"])
    }

    @Test func aNameWithNothingUsableYieldsNoCandidates() {
        #expect(MagicDNSName.candidates(forServerNamed: "   ").isEmpty)
        #expect(MagicDNSName.candidates(forServerNamed: "'''").isEmpty)
    }

    @Test func aLabelLongerThanDNSAllowsIsDropped() {
        #expect(MagicDNSName.candidates(forServerNamed: String(repeating: "a", count: 64)).isEmpty)
    }
}

struct TailscaleDeviceTests {
    private func decode(_ json: String) throws -> [TailscaleDevice] {
        struct Body: Decodable { let devices: [TailscaleDevice] }
        return try JSONDecoder().decode(Body.self, from: Data(json.utf8)).devices
    }

    @Test func theApiListingDecodesWithMissingFields() throws {
        let devices = try decode("""
        {"devices": [
          {"name": "arch.tail1.ts.net", "hostname": "arch", "addresses": ["100.91.211.44", "fd7a:115c::1"], "os": "linux", "connectedToControl": true, "lastSeen": "2026-10-17T00:00:00Z"},
          {"hostname": "bare"}
        ]}
        """)
        #expect(devices.count == 2)
        #expect(devices[0].tailnetIPv4 == "100.91.211.44")
        #expect(devices[1].addresses.isEmpty)
        #expect(devices[1].tailnetIPv4 == nil)
    }

    @Test func clientOnlyAndOfflineDevicesAreNotWorthProbing() {
        let now = Date()
        #expect(!TailscaleDevice(addresses: ["100.64.0.2"], os: "iOS").isWorthProbing(now: now))
        #expect(!TailscaleDevice(addresses: ["100.64.0.2"], os: "tvOS").isWorthProbing(now: now))
        #expect(!TailscaleDevice(addresses: ["100.64.0.2"], os: "linux", connectedToControl: false).isWorthProbing(now: now))
        #expect(TailscaleDevice(addresses: ["100.64.0.2"], os: "linux", connectedToControl: true).isWorthProbing(now: now))
        #expect(TailscaleDevice(addresses: ["100.64.0.2"], os: "macOS").isWorthProbing(now: now))
    }

    @Test func withoutAControlFlagRecentSightingDecides() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let iso = ISO8601DateFormatter()
        let recent = iso.string(from: now.addingTimeInterval(-60))
        let stale = iso.string(from: now.addingTimeInterval(-3600))
        #expect(TailscaleDevice(addresses: [], os: "linux", lastSeen: recent).isWorthProbing(now: now))
        #expect(!TailscaleDevice(addresses: [], os: "linux", lastSeen: stale).isWorthProbing(now: now))
    }
}

struct TailnetTargetTests {
    @Test func theDefaultPortComesFirstAndRelayPortsAreIgnored() {
        let server = target("Arch", id: "m1", urls: [
            "http://192.168.1.197:32401",
            "https://203-0-113-7.abc123.plex.direct:8443",
            "http://192.168.1.197:32400",
        ])
        #expect(server.ports == [32400, 32401])
    }

    @Test func thePlexDirectHashBuildsAnHTTPSNameForAnyAddress() {
        let server = target("Arch", id: "m1", urls: ["https://192-168-1-197.deadbeef.plex.direct:32400"])
        #expect(server.plexDirectHash == "deadbeef")
        #expect(server.plexDirectURL(address: "100.91.211.44", port: 32400) == url("https://100-91-211-44.deadbeef.plex.direct:32400"))
        #expect(target("Arch", id: "m1").plexDirectURL(address: "100.91.211.44", port: 32400) == nil)
    }
}

struct TailnetServerFinderTests {
    private let arch = url("http://100.91.211.44:32400")

    @Test func nothingIsAttemptedOffTheTailnet() async {
        let stub = TailnetStub()
        stub.onTailnet = false
        stub.names["arch"] = ["100.91.211.44"]
        stub.identities[arch] = "m1"
        stub.token = "tskey"

        let found = await stub.finder.routes(for: [target("Arch", id: "m1")])

        #expect(found.isEmpty)
        #expect(stub.resolved.value.isEmpty)
        #expect(stub.probed.value.isEmpty)
    }

    @Test func aServerIsFoundByItsNameAndVerifiedByItsIdentifier() async {
        let stub = TailnetStub()
        stub.names["arch"] = ["100.91.211.44"]
        stub.identities[arch] = "m1"

        let found = await stub.finder.routes(for: [target("Arch", id: "m1")])

        #expect(found == ["m1": [arch]])
    }

    @Test func aNameThatLeavesTheTailnetIsNotProbed() async {
        let stub = TailnetStub()
        stub.names["arch"] = ["192.168.1.197"]
        stub.identities[url("http://192.168.1.197:32400")] = "m1"

        let found = await stub.finder.routes(for: [target("Arch", id: "m1")])

        #expect(found.isEmpty)
        #expect(stub.probed.value.isEmpty)
    }

    @Test func aDifferentServerAtTheGuessedNameIsNotTrusted() async {
        let stub = TailnetStub()
        stub.names["arch"] = ["100.91.211.44"]
        stub.identities[arch] = "someone-elses"

        let found = await stub.finder.routes(for: [target("Arch", id: "m1")])

        #expect(found.isEmpty)
    }

    @Test func aServerThatInsistsOnHTTPSIsReachedByItsPlexDirectName() async {
        let stub = TailnetStub()
        stub.names["arch"] = ["100.91.211.44"]
        let secure = url("https://100-91-211-44.deadbeef.plex.direct:32400")
        stub.identities[secure] = "m1"

        let found = await stub.finder.routes(for: [target("Arch", id: "m1", urls: ["https://192-168-1-197.deadbeef.plex.direct:32400"])])

        #expect(found == ["m1": [secure]])
        #expect(stub.probed.value == [arch, secure])
    }

    @Test func anOddPortFromTheAdvertisedRoutesIsTriedToo() async {
        let stub = TailnetStub()
        stub.names["arch"] = ["100.91.211.44"]
        let odd = url("http://100.91.211.44:32401")
        stub.identities[odd] = "m1"

        let found = await stub.finder.routes(for: [target("Arch", id: "m1", urls: ["http://192.168.1.197:32401"])])

        #expect(found == ["m1": [odd]])
    }

    @Test func theDeviceListFindsAServerWhoseNameDoesNotMatch() async {
        let stub = TailnetStub()
        stub.token = "tskey"
        stub.devices = [
            TailscaleDevice(hostname: "phone", addresses: ["100.75.22.54"], os: "iOS", connectedToControl: true),
            TailscaleDevice(hostname: "old", addresses: ["100.98.10.97"], os: "linux", connectedToControl: false),
            TailscaleDevice(hostname: "box", addresses: ["100.91.211.44"], os: "linux", connectedToControl: true),
        ]
        stub.identities[arch] = "m1"

        let found = await stub.finder.routes(for: [target("Marcus Plex", id: "m1")])

        #expect(found == ["m1": [arch]])
        #expect(!stub.probed.value.contains(url("http://100.75.22.54:32400")))
        #expect(!stub.probed.value.contains(url("http://100.98.10.97:32400")))
    }

    @Test func oneDeviceListFindsEveryServerAtOnce() async {
        let stub = TailnetStub()
        stub.token = "tskey"
        stub.devices = [
            TailscaleDevice(hostname: "a", addresses: ["100.64.0.10"], os: "linux", connectedToControl: true),
            TailscaleDevice(hostname: "b", addresses: ["100.64.0.11"], os: "macOS", connectedToControl: true),
        ]
        stub.identities[url("http://100.64.0.10:32400")] = "m1"
        stub.identities[url("http://100.64.0.11:32400")] = "m2"

        let found = await stub.finder.routes(for: [target("One", id: "m1"), target("Two", id: "m2")])

        #expect(found["m1"] == [url("http://100.64.0.10:32400")])
        #expect(found["m2"] == [url("http://100.64.0.11:32400")])
    }

    @Test func aRejectedTokenIsReportedAndTheNameSearchStillWorks() async {
        let stub = TailnetStub()
        stub.token = "stale"
        stub.deviceError = .tokenRejected
        stub.names["arch"] = ["100.91.211.44"]
        stub.identities[arch] = "m1"

        let found = await stub.finder.routes(for: [target("Arch", id: "m1")])

        #expect(found == ["m1": [arch]])
        #expect(stub.rejections.value <= 1)
    }

    @Test func aRejectedTokenWithNoNameMatchFindsNothingAndSaysSo() async {
        let stub = TailnetStub()
        stub.token = "stale"
        stub.deviceError = .tokenRejected

        let found = await stub.finder.routes(for: [target("Arch", id: "m1")])

        #expect(found.isEmpty)
        #expect(stub.rejections.value == 1)
    }

    @Test func withoutATokenTheDeviceListIsNeverAsked() async {
        let stub = TailnetStub()
        stub.devices = [TailscaleDevice(hostname: "box", addresses: ["100.91.211.44"], os: "linux", connectedToControl: true)]
        stub.identities[arch] = "m1"

        let found = await stub.finder.routes(for: [target("Marcus Plex", id: "m1")])

        #expect(found.isEmpty)
    }
}

struct TailnetRouteOrderTests {
    @Test func tailnetRoutesSitBetweenLocalAndRemote() {
        var server = AuthFixtures.choice(name: "Home", id: "m1", uris: ["http://192.168.1.5:32400", "http://203.0.113.7:32400"])
        server.addTailnetRoutes([url("http://100.91.211.44:32400")])

        #expect(server.routes.map(\.kind) == [.local, .tailscale, .remote])
        #expect(server.routes[1].uri == "http://100.91.211.44:32400")
        #expect(server.routes[1].state == .probing)
    }

    @Test func aRouteAlreadyListedIsNotAddedTwice() {
        var server = AuthFixtures.choice(name: "Home", id: "m1", uris: ["http://100.91.211.44:32400"])
        server.addTailnetRoutes([url("http://100.91.211.44:32400")])

        #expect(server.routes.count == 1)
    }

    @Test func aServerWithNoOtherRoutesGetsTheTailnetRoute() {
        var server = AuthFixtures.choice(name: "Home", id: "m1", uris: [])
        server.addTailnetRoutes([url("http://100.91.211.44:32400")])

        #expect(server.routes.map(\.kind) == [.tailscale])
    }
}

struct TailnetListingTests {
    private let lan = "http://192.168.1.5:32400"

    private func environment(
        resources: [PlexResource],
        onTailnet: Bool,
        found: [String: [URL]],
        asked: AuthLocked<[[String]]>
    ) -> ServerDiscoveryEnvironment {
        ServerDiscoveryEnvironment(
            resources: { _ in resources },
            probe: { _, _ in false },
            firstReachable: { _, _ in nil },
            machineIdentifier: { _, _ in nil },
            measure: { _, _ in nil },
            save: { _, _, _, _ in nil },
            isOnTailnet: { onTailnet },
            tailnetRoutes: { targets in
                asked.update { $0.append(targets.map(\.id)) }
                return found
            }
        )
    }

    @Test func serversGainTheRoutesFoundOnTheTailnetAndTheSearchIsAnnounced() async throws {
        let asked = AuthLocked<[[String]]>([])
        let messages = AuthLocked<[String]>([])
        let tailnet = url("http://100.91.211.44:32400")
        let environment = environment(
            resources: [AuthFixtures.resource(name: "Arch", id: "m1", uris: [lan])],
            onTailnet: true,
            found: ["m1": [tailnet]],
            asked: asked
        )

        let listing = try await ServerDiscovery(token: "tok", environment: environment).listing { progress in
            messages.update { $0.append(progress.message) }
        }

        guard case .single(let server) = listing else { Issue.record("expected single"); return }
        #expect(server.routes.map(\.kind) == [.local, .tailscale])
        #expect(asked.value == [["m1"]])
        #expect(messages.value == ["Looking for your server on your tailnet…"])
    }

    @Test func offTheTailnetNothingIsSearchedOrAnnounced() async throws {
        let asked = AuthLocked<[[String]]>([])
        let messages = AuthLocked<[String]>([])
        let environment = environment(
            resources: [AuthFixtures.resource(name: "Arch", id: "m1", uris: [lan])],
            onTailnet: false,
            found: ["m1": [url("http://100.91.211.44:32400")]],
            asked: asked
        )

        let listing = try await ServerDiscovery(token: "tok", environment: environment).listing { progress in
            messages.update { $0.append(progress.message) }
        }

        guard case .single(let server) = listing else { Issue.record("expected single"); return }
        #expect(server.routes.map(\.kind) == [.local])
        #expect(asked.value.isEmpty)
        #expect(messages.value.isEmpty)
    }

    @Test func onlyOnlineServersAreSearchedFor() async throws {
        let asked = AuthLocked<[[String]]>([])
        let environment = environment(
            resources: [
                AuthFixtures.resource(name: "Arch", id: "m1", uris: [lan]),
                AuthFixtures.resource(name: "Asleep", id: "m2", online: false, uris: []),
            ],
            onTailnet: true,
            found: [:],
            asked: asked
        )

        _ = try await ServerDiscovery(token: "tok", environment: environment).listing()

        #expect(asked.value == [["m1"]])
    }
}

struct ConnectRecoveryTests {
    @Test func offTheTailnetTheAdviceIsToTurnTailscaleOn() {
        let recovery = ConnectRecovery(serverName: "Arch", advertisesLocalRoute: false, tailnetConnected: false, access: .none)
        #expect(recovery.steps == [.connectTailscale])
    }

    @Test func onTheTailnetWithoutATokenTheAdviceIsToSearchIt() {
        let recovery = ConnectRecovery(serverName: "Arch", advertisesLocalRoute: false, tailnetConnected: true, access: .none)
        #expect(recovery.steps == [.findOnTailnet])
        #expect(recovery.actionTitle(of: .findOnTailnet) == "Search My Tailnet")
    }

    @Test func aRejectedTokenAsksForANewOne() {
        let recovery = ConnectRecovery(serverName: "Arch", advertisesLocalRoute: false, tailnetConnected: true, access: .rejected)
        #expect(recovery.steps == [.replaceTailnetToken])
    }

    @Test func aWorkingTokenThatFoundNothingSaysSoWithoutAnAction() {
        let recovery = ConnectRecovery(serverName: "Arch", advertisesLocalRoute: false, tailnetConnected: true, access: .saved)
        #expect(recovery.steps == [.notOnTailnet])
        #expect(recovery.actionTitle(of: .notOnTailnet) == nil)
    }

    @Test func aServerWithALocalRouteAlsoPointsAtLocalNetworkAccess() {
        let recovery = ConnectRecovery(serverName: "Arch", advertisesLocalRoute: true, tailnetConnected: false, access: .none)
        #expect(recovery.steps == [.connectTailscale, .allowLocalNetwork])
    }

    @Test func theHeadlineNamesTheServerWhenItIsKnown() {
        #expect(ConnectRecovery(serverName: "Arch", advertisesLocalRoute: false, tailnetConnected: false, access: .none).headline == "Crucible couldn't reach Arch.")
        #expect(ConnectRecovery(serverName: nil, advertisesLocalRoute: false, tailnetConnected: false, access: .none).headline == "Crucible couldn't connect automatically.")
    }

    @Test func theServerInitReadsLocalRoutesFromTheChoice() {
        let server = AuthFixtures.choice(name: "Home", id: "m1", uris: ["http://192.168.1.5:32400"])
        let recovery = ConnectRecovery(server: server, tailnetConnected: false, access: .none)
        #expect(recovery.serverName == "Home")
        #expect(recovery.steps == [.connectTailscale, .allowLocalNetwork])
    }
}

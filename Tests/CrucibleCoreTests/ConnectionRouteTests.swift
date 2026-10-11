import Foundation
import Testing
@testable import CrucibleCore

struct ConnectionRouteTests {
    private func kind(_ string: String) -> ConnectionKind {
        ConnectionRoute.kind(of: URL(string: string)!)
    }

    @Test func privateAndLoopbackAddressesAreLocal() {
        #expect(kind("http://192.168.1.10:32400") == .local)
        #expect(kind("http://10.0.0.5:32400") == .local)
        #expect(kind("http://172.16.0.1:32400") == .local)
        #expect(kind("http://172.31.255.1:32400") == .local)
        #expect(kind("http://127.0.0.1:32400") == .local)
        #expect(kind("http://169.254.3.4:32400") == .local)
    }

    @Test func addressesOutsidePrivateRangesAreRemote() {
        #expect(kind("http://172.32.0.1:32400") == .remote)
        #expect(kind("http://8.8.8.8:32400") == .remote)
        #expect(kind("https://plex.example.com:32400") == .remote)
    }

    @Test func carrierGradeNatRangeIsTailscale() {
        #expect(kind("http://100.64.1.1:32400") == .tailscale)
        #expect(kind("http://100.127.255.1:32400") == .tailscale)
        #expect(kind("http://100.128.0.1:32400") == .remote)
        #expect(kind("https://nas.tail1234.ts.net:32400") == .tailscale)
    }

    @Test func bareAndMulticastNamesAreLocal() {
        #expect(kind("http://localhost:32400") == .local)
        #expect(kind("http://nas.local:32400") == .local)
        #expect(kind("http://plexserver:32400") == .local)
    }

    @Test func ipv6ClassificationFollowsPrefix() {
        #expect(kind("http://[::1]:32400") == .local)
        #expect(kind("http://[fe80::1]:32400") == .local)
        #expect(kind("http://[fd12::1]:32400") == .local)
        #expect(kind("http://[2001:db8::1]:32400") == .remote)
    }

    @Test func plexDirectNamesEmbedTheirAddress() {
        #expect(kind("https://192-168-1-5.abc123.plex.direct:32400") == .local)
        #expect(kind("https://100-64-1-1.abc123.plex.direct:32400") == .tailscale)
        #expect(kind("https://203-0-113-9.abc123.plex.direct:32400") == .remote)
    }

    @Test func plexDirectOnNonDefaultPublicPortIsRelay() {
        #expect(kind("https://203-0-113-9.abc123.plex.direct:8443") == .relay)
        #expect(kind("https://203-0-113-9.abc123.plex.direct") == .remote)
        #expect(kind("https://192-168-1-5.abc123.plex.direct:8443") == .local)
    }

    @Test func httpsDetectionIgnoresCase() {
        #expect(ConnectionRoute.isHTTPS(URL(string: "HTTPS://example.com")!))
        #expect(!ConnectionRoute.isHTTPS(URL(string: "http://example.com")!))
    }

    @Test func connectionKindTitles() {
        #expect(ConnectionKind.local.title == "Local")
        #expect(ConnectionKind.tailscale.title == "Tailscale")
        #expect(ConnectionKind.remote.title == "Remote")
        #expect(ConnectionKind.relay.title == "Plex Relay")
    }

    @Test func bareHostTriesHttpsThenHttpOnDefaultPort() {
        let urls = ConnectionRoute.candidates(from: "192.168.1.5")
        #expect(urls?.map(\.absoluteString) == ["https://192.168.1.5:32400", "http://192.168.1.5:32400"])
    }

    @Test func explicitSchemeAndPortAreHonoured() {
        #expect(ConnectionRoute.candidates(from: "http://nas.local:1234/")?.map(\.absoluteString) == ["http://nas.local:1234"])
        #expect(ConnectionRoute.candidates(from: " HTTPS://plex.example.com ")?.map(\.absoluteString) == ["https://plex.example.com:32400"])
    }

    @Test func malformedInputYieldsNoCandidates() {
        let invalid = ["", "   ", "a b", "ftp://nas", "host:99999", "host:0", "host:abc", "host/path", "host?x=1", "host#frag", "-bad.example.com", "bad..example.com", "300.1.1.1", "bad_host.example.com", "http://"]
        for input in invalid {
            #expect(ConnectionRoute.candidates(from: input) == nil, "\(input)")
        }
    }
}

struct ServerAddressTests {
    @Test func bareHostDefaultsToPlexPortAndBothSchemes() {
        let address = ServerAddress.parse("192.168.1.5")
        #expect(address?.host == "192.168.1.5")
        #expect(address?.port == 32400)
        #expect(address?.scheme == nil)
        #expect(address?.candidateURLs.map(\.absoluteString) == ["https://192.168.1.5:32400", "http://192.168.1.5:32400"])
    }

    @Test func schemePortAndPathAreParsed() {
        let address = ServerAddress.parse("  https://nas.example.com:8443/web/index.html ")
        #expect(address?.host == "nas.example.com")
        #expect(address?.port == 8443)
        #expect(address?.scheme == "https")
        #expect(address?.candidateURLs.map(\.absoluteString) == ["https://nas.example.com:8443"])
    }

    @Test func invalidAddressesAreRejected() {
        let invalid = ["", "   ", "ftp://nas", "nas:abc", "nas:0", "nas:70000", "::1", "bad_host", "-nas", "nas-", "256.1.1.1", "1.2.3", "a..b"]
        for input in invalid {
            #expect(ServerAddress.parse(input) == nil, "\(input)")
        }
    }
}

struct ServerChoiceTests {
    private func connection(_ json: String) throws -> PlexResourceConnection {
        try JSONDecoder().decode(PlexResourceConnection.self, from: Data(json.utf8))
    }

    @Test func routesRankLocalDirectHttpsFirstAndRelayLast() throws {
        let relay = try connection(#"{"uri":"https://relay.plex.direct:8443","address":"203.0.113.9","port":8443,"protocol":"https","local":false,"relay":true}"#)
        let remote = try connection(#"{"uri":"https://remote.plex.direct:32400","address":"203.0.113.9","port":32400,"protocol":"https","local":false,"relay":false}"#)
        let localHttp = try connection(#"{"uri":"http://192.168.1.5:32400","address":"192.168.1.5","port":32400,"protocol":"http","local":true,"relay":false}"#)
        let localHttps = try connection(#"{"uri":"https://192-168-1-5.abc.plex.direct:32400","address":"192.168.1.5","port":32400,"protocol":"https","local":true,"relay":false}"#)
        let docker = try connection(#"{"uri":"https://172.17.0.2:32400","address":"172.17.0.2","port":32400,"protocol":"https","local":true,"relay":false}"#)

        let ranked = ServerChoice.ranked([relay, remote, docker, localHttp, localHttps])
        #expect(ranked.map(\.uri) == [localHttps.uri, localHttp.uri, docker.uri, remote.uri, relay.uri])
    }

    @Test func choiceReportsFastestReachableRoute() throws {
        let json = #"""
        {"name":"Home","provides":"server","clientIdentifier":"abc","owned":true,"presence":true,"connections":[
            {"uri":"https://a.plex.direct:32400","address":"192.168.1.5","port":32400,"protocol":"https","local":true,"relay":false},
            {"uri":"https://b.plex.direct:32400","address":"203.0.113.9","port":32400,"protocol":"https","local":false,"relay":false}
        ]}
        """#
        let resource = try JSONDecoder().decode(PlexResource.self, from: Data(json.utf8))
        var choice = ServerChoice(resource: resource)
        #expect(choice.isProbing)
        #expect(choice.detailText == "Owned by you · 2 connections")
        choice.record(routeAt: 0, milliseconds: nil)
        choice.record(routeAt: 1, milliseconds: 42)
        choice.record(routeAt: 9, milliseconds: 1)
        #expect(!choice.isProbing)
        #expect(choice.fastestMilliseconds == 42)
        #expect(choice.bestRoute?.uri == "https://b.plex.direct:32400")
    }

    @Test func offlineServerWithoutLastSeenSaysOffline() throws {
        let json = #"{"name":"Away","provides":"server","clientIdentifier":"xyz","owned":false,"presence":false,"connections":[]}"#
        let resource = try JSONDecoder().decode(PlexResource.self, from: Data(json.utf8))
        let choice = ServerChoice(resource: resource)
        #expect(choice.detailText == "Offline")
        #expect(choice.routes.isEmpty)
    }
}

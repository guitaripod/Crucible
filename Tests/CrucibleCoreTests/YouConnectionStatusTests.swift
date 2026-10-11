import Foundation
import Testing
@testable import CrucibleCore

struct YouRouteKindTests {
    private func kind(_ string: String) -> YouRouteKind {
        YouRouteKind.classify(URL(string: string)!)
    }

    @Test func privateRangesAreLocal() {
        #expect(kind("http://192.168.1.10:32400") == .local)
        #expect(kind("http://10.1.2.3:32400") == .local)
        #expect(kind("http://172.16.0.1:32400") == .local)
        #expect(kind("http://172.31.255.255:32400") == .local)
        #expect(kind("http://169.254.1.1:32400") == .local)
        #expect(kind("http://127.0.0.1:32400") == .local)
    }

    @Test func rangesJustOutsideThePrivateBlocksAreRemote() {
        #expect(kind("http://172.15.0.1:32400") == .remote)
        #expect(kind("http://172.32.0.1:32400") == .remote)
        #expect(kind("http://8.8.8.8:32400") == .remote)
        #expect(kind("http://203.0.113.7:32400") == .remote)
    }

    @Test func tailscaleUsesTheCarrierGradeRangeAndMagicDNS() {
        #expect(kind("http://100.64.0.1:32400") == .tailscale)
        #expect(kind("http://100.127.0.1:32400") == .tailscale)
        #expect(kind("http://100.128.0.1:32400") == .remote)
        #expect(kind("https://nas.tailnet-1234.ts.net:32400") == .tailscale)
    }

    @Test func barePrivateAndMulticastNamesAreLocalAndPublicNamesRemote() {
        #expect(kind("http://plexserver:32400") == .local)
        #expect(kind("http://nas.local:32400") == .local)
        #expect(kind("https://plex.example.com:32400") == .remote)
    }

    @Test func plexDirectNamesAreClassifiedByTheirEmbeddedAddress() {
        #expect(kind("https://192-168-1-5.abcdef.plex.direct:32400") == .local)
        #expect(kind("https://100-100-1-5.abcdef.plex.direct:32400") == .tailscale)
        #expect(kind("https://203-0-113-9.abcdef.plex.direct:32400") == .remote)
        #expect(kind("https://not-an-address.abcdef.plex.direct:32400") == .remote)
    }

    @Test func routeTitlesAreTheRawValues() {
        #expect([YouRouteKind.local, .tailscale, .remote].map(\.rawValue) == ["Local", "Tailscale", "Remote"])
    }
}

@MainActor
struct YouConnectionStatusTests {
    private nonisolated static let home = URL(string: "http://192.168.1.10:32400")!
    private nonisolated static let away = URL(string: "http://203.0.113.7:32400")!

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func next() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var total: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private func run(_ status: YouConnectionStatus, url: URL, reachable: Bool) async {
        status.refresh(baseURL: { url }, identityCheck: { reachable })
        await status.task?.value
    }

    @Test func startsConnecting() {
        #expect(YouConnectionStatus().state == .connecting)
    }

    @Test func reachableRouteReportsKindAndAtLeastOneMillisecond() async {
        let status = YouConnectionStatus()
        await run(status, url: Self.home, reachable: true)
        guard case .reachable(let route, let latency) = status.state else {
            Issue.record("expected reachable, got \(status.state)")
            return
        }
        #expect(route == .local)
        #expect(latency >= 1)
    }

    @Test func failedProbeIsUnreachableAndRetriedOnTheNextRefresh() async {
        let status = YouConnectionStatus()
        await run(status, url: Self.home, reachable: false)
        #expect(status.state == .unreachable)
        await run(status, url: Self.home, reachable: true)
        guard case .reachable = status.state else {
            Issue.record("expected reachable after the retry, got \(status.state)")
            return
        }
    }

    @Test func aReachableRouteIsNotProbedAgainForTheSameURL() async {
        let status = YouConnectionStatus()
        let calls = Calls()
        status.refresh(baseURL: { Self.home }, identityCheck: { calls.next(); return true })
        await status.task?.value
        status.refresh(baseURL: { Self.home }, identityCheck: { calls.next(); return true })
        await status.task?.value
        #expect(calls.total == 1)
    }

    @Test func aNewBaseURLResetsToConnectingAndProbesAgain() async {
        let status = YouConnectionStatus()
        await run(status, url: Self.home, reachable: true)
        var seen: [YouConnectionState] = []
        status.onChange = { seen.append($0) }
        await run(status, url: Self.away, reachable: true)
        #expect(seen.first == .connecting)
        guard case .reachable(let route, _) = status.state else {
            Issue.record("expected reachable, got \(status.state)")
            return
        }
        #expect(route == .remote)
    }

    @Test func refreshWhileAProbeIsRunningIsIgnored() async {
        let status = YouConnectionStatus()
        let calls = Calls()
        status.refresh(baseURL: { Self.home }, identityCheck: { calls.next(); return true })
        status.refresh(baseURL: { Self.away }, identityCheck: { calls.next(); return true })
        await status.task?.value
        #expect(calls.total == 1)
    }

    @Test func observersAreOnlyToldAboutRealChanges() async {
        let status = YouConnectionStatus()
        var count = 0
        status.onChange = { _ in count += 1 }
        await run(status, url: Self.home, reachable: false)
        await run(status, url: Self.home, reachable: false)
        #expect(count == 1)
    }
}

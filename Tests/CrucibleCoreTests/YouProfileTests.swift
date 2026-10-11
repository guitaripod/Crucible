import Foundation
import Testing
@testable import CrucibleCore

struct YouProfileTests {
    @Test func connectingShowsTheServerAndAQuietTone() {
        let profile = YouProfile.make(accountName: "Marcus", serverName: "Marcus-PC", state: .connecting)
        #expect(profile == YouProfile(name: "Marcus", statusText: "Marcus-PC · Connecting…", tone: .neutral))
    }

    @Test func reachableShowsRouteAndLatency() {
        let profile = YouProfile.make(accountName: "Marcus", serverName: "Marcus-PC", state: .reachable(route: .tailscale, latencyMs: 42))
        #expect(profile.statusText == "Marcus-PC · Tailscale · 42 ms")
        #expect(profile.tone == .ok)
    }

    @Test func unreachableIsAFailure() {
        let profile = YouProfile.make(accountName: "Marcus", serverName: "Marcus-PC", state: .unreachable)
        #expect(profile.statusText == "Marcus-PC · Unreachable")
        #expect(profile.tone == .failure)
    }

    @Test func serverRowValueFollowsTheConnectionState() {
        #expect(YouConnectionState.connecting.routeSummary == nil)
        #expect(YouConnectionState.reachable(route: .remote, latencyMs: 9).routeSummary == "Remote")
        #expect(YouConnectionState.unreachable.routeSummary == "Unreachable")
    }
}

@Suite(.serialized)
struct PlexAccountNameStoredTests {
    private let key = PlexAccountName.defaultsKey

    private func withStored(_ value: String?, _ body: () -> Void) {
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        body()
    }

    @Test func fallsBackBeforeTheNameIsKnown() {
        withStored(nil) { #expect(PlexAccountName.stored == "Plex User") }
    }

    @Test func blankNamesFallBack() {
        withStored("  \n ") { #expect(PlexAccountName.stored == "Plex User") }
    }

    @Test func storedNameIsTrimmed() {
        withStored("  Marcus ") { #expect(PlexAccountName.stored == "Marcus") }
    }
}

struct YouHistoryHeadlineTests {
    @Test func prefersTheShowTitleOverTheEpisodeTitle() {
        #expect(YouHistoryHeadline.headline(title: "Low Tide", grandparentTitle: "The Show", viewedAt: nil) == "The Show")
    }

    @Test func usesTheItemTitleForMovies() {
        #expect(YouHistoryHeadline.headline(title: "Dune", grandparentTitle: nil, viewedAt: nil) == "Dune")
    }

    @Test func emptyTitlesProduceNoHeadline() {
        #expect(YouHistoryHeadline.headline(title: "", grandparentTitle: nil, viewedAt: 100) == nil)
    }

    @Test func appendsHowLongAgoWhenKnown() throws {
        let hourAgo = Int(Date().timeIntervalSince1970) - 3600
        let text = try #require(YouHistoryHeadline.headline(title: "Dune", grandparentTitle: nil, viewedAt: hourAgo))
        #expect(text.hasPrefix("Dune · "))
        #expect(text.count > "Dune · ".count)
    }
}

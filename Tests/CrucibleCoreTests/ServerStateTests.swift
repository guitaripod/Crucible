import Foundation
import Testing
@testable import CrucibleCore

@MainActor
struct ServerStateTests {
    @Test func onlyPausesAndStopsElsewhereAndLibraryChangesMoveState() {
        let other = "living-room"
        #expect(ServerEvent.playback(ratingKey: "7", state: "stopped", clientIdentifier: other).stateChange == .titles(["7"]))
        #expect(ServerEvent.playback(ratingKey: "7", state: "paused", clientIdentifier: other).stateChange == .titles(["7"]))
        #expect(ServerEvent.playback(ratingKey: "7", state: "playing", clientIdentifier: other).stateChange == nil)
        #expect(ServerEvent.playback(ratingKey: "7", state: "stopped", clientIdentifier: PlexHeaders.clientIdentifier).stateChange == nil)
        #expect(ServerEvent.playback(ratingKey: nil, state: "stopped", clientIdentifier: other).stateChange == ServerStateChange(movesWatchState: true))
        #expect(ServerEvent.activity(type: "library.update.section", event: "ended", progress: 100).stateChange == nil)
        #expect(ServerEvent.library(sectionID: nil, ratingKey: nil).stateChange == .everything, "a scan of an unnamed library may have changed any")
        let added = ServerEvent.library(sectionID: "2", ratingKey: "9001").stateChange
        #expect(added == ServerStateChange(ratingKeys: ["9001"], sectionIDs: ["2"]))
        #expect(added?.movesWatchState == false)
        #expect(ServerEvent.playback(ratingKey: "7", state: "paused", clientIdentifier: other).changesHome)
    }

    @Test func aChangeTouchesTheScreensShowingItsTitlesOrItsLibrary() {
        let stop = ServerStateChange.titles(["e12", nil, ""])
        #expect(stop.ratingKeys == ["e12"])
        #expect(stop.touches(["show", "s1", "e12"]))
        #expect(!stop.touches(["show", "s1", "e13"], sectionID: "2"))
        #expect(stop.touchesLibrary("5"))
        let scan = ServerStateChange(ratingKeys: ["9001"], sectionIDs: ["2"])
        #expect(scan.touches(["show"], sectionID: "2"))
        #expect(!scan.touches(["show"], sectionID: "3"))
        #expect(scan.touchesLibrary("2"))
        #expect(!scan.touchesLibrary("3"))
        #expect(ServerStateChange.everything.touches([]))
        #expect(ServerStateChange.everything.touchesLibrary("3"))
        #expect(ServerStateChange().isEmpty)
        #expect(!ServerStateChange(movesWatchState: true).isEmpty)
        #expect(ServerStateChange(movesWatchState: true).touchesLibrary("3"))
        #expect(!ServerStateChange(movesWatchState: true).touches(["a"]))
        var merged = scan
        merged.merge(stop)
        #expect(merged == ServerStateChange(ratingKeys: ["9001", "e12"], sectionIDs: ["2"], movesWatchState: true))
    }

    @Test func changesPostedTogetherReachObserversOnceAndEmptyOnesNever() async throws {
        let center = ServerStateSync(hub: ServerEventHub())
        var heard: [ServerStateChange] = []
        let token = center.addObserver { heard.append($0) }
        center.post(.titles(["1"]))
        center.post(.titles(["2"]))
        center.post(ServerStateChange())
        #expect(heard.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        #expect(heard == [.titles(["1", "2"])])
        center.post(.titles(["3"]), gathering: .milliseconds(300))
        center.post(.titles(["4"]))
        try await Task.sleep(for: .milliseconds(50))
        #expect(heard.last == .titles(["3", "4"]))
        center.removeObserver(token)
        center.post(.everything)
        try await Task.sleep(for: .milliseconds(400))
        #expect(heard.count == 2)
    }

    @Test func aFollowerRefreshesOnScreenAndRemembersChangesOffScreen() async throws {
        let center = ServerStateSync(hub: ServerEventHub())
        var onScreen = true
        var refreshes = 0
        let follower = ServerStateFollower(center: center, every: .milliseconds(200), matching: { $0.touches(["a"]) }, isOnScreen: { onScreen }, refresh: {
            refreshes += 1
        })
        center.post(.titles(["b"]))
        try await Task.sleep(for: .milliseconds(30))
        #expect(refreshes == 0)
        center.post(.titles(["a"]))
        try await Task.sleep(for: .milliseconds(30))
        #expect(refreshes == 1)
        center.post(.titles(["a"]))
        try await Task.sleep(for: .milliseconds(30))
        #expect(refreshes == 1, "a second change inside the interval waits for it")
        try await Task.sleep(for: .milliseconds(250))
        #expect(refreshes == 2)
        onScreen = false
        try await Task.sleep(for: .milliseconds(250))
        center.post(.everything)
        try await Task.sleep(for: .milliseconds(30))
        #expect(refreshes == 2)
        #expect(follower.takeStale())
        #expect(!follower.takeStale())
        follower.cancel()
        onScreen = true
        center.post(.everything)
        try await Task.sleep(for: .milliseconds(30))
        #expect(refreshes == 2)
    }

    @Test func theHubHandsEveryEventToAFollowerAndCanBeSuspended() async throws {
        let server = DetailStubServer()
        let hub = ServerEventHub()
        var events: [ServerEvent] = []
        let listening = hub.follow(api: server.client) { events.append($0) }
        hub.suspend()
        #expect(!hub.isConnected)
        hub.receive(.activity(type: nil, event: nil, progress: nil))
        hub.receive(.library(sectionID: "1", ratingKey: "9"))
        #expect(events == [.activity(type: nil, event: nil, progress: nil), .library(sectionID: "1", ratingKey: "9")])
        hub.resume()
        #expect(hub.isConnected)
        listening.cancel()
        #expect(!hub.isConnected)
    }

    @Test func onlyAConnectionAfterADropAsksForAResync() async throws {
        let server = DetailStubServer()
        server.reply(path: "/:/eventsource/notifications", body: [:])
        let hub = ServerEventHub()
        var resyncs = 0
        let token = hub.onResync { resyncs += 1 }
        let listening = hub.follow(api: server.client) { _ in }
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.requests == ["/:/eventsource/notifications"])
        #expect(resyncs == 0, "the first connection follows no drop")
        try await Task.sleep(for: ServerEventStream.backoff(after: 1) + .milliseconds(600))
        #expect(server.requests.count == 2)
        #expect(resyncs == 1, "the stream ended, so the next connection may have missed events")
        listening.cancel()
        hub.removeResyncHandler(token)
    }

    @Test func anAnswerFromBeforeAChangeIsNeitherKeptNorServed() async throws {
        let server = DetailStubServer()
        let api = server.client
        server.reply(path: "/library/metadata/1", items: [DetailFixtures.episode(1, offsetMs: 1_000)])
        _ = try await api.requestContainer(.metadata(ratingKey: "1"))
        _ = try await api.requestContainer(.metadata(ratingKey: "1"))
        #expect(server.requests.filter { $0 == "/library/metadata/1" }.count == 1)
        APIClient.invalidateCaches(token: api.token)
        server.reply(path: "/library/metadata/1", items: [DetailFixtures.episode(1, offsetMs: 9_000)])
        let fresh = try await api.requestContainer(.metadata(ratingKey: "1"))
        #expect(fresh.Metadata?.first?.viewOffset == 9_000)
        #expect(server.requests.filter { $0 == "/library/metadata/1" }.count == 2)
    }
}

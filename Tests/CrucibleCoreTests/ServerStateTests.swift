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

    @Test func aStartTakenFromAScreenFollowsTheServer() throws {
        let stale = DetailFixtures.episode(3, offsetMs: 600_000)
        let request = PlaybackRequest(item: stale)
        #expect(request.serverStart == .resume)
        #expect(request.resumePosition == 600)

        let movedOn = DetailFixtures.episode(3, offsetMs: 1_800_000)
        let followed = try #require(request.followingServer(movedOn))
        #expect(followed.resumePosition == 1_800)
        #expect(followed.serverStart == nil)
        #expect(followed.ratingKey == request.ratingKey)

        let finishedElsewhere = DetailFixtures.episode(3, watched: true, offsetMs: 2_390_000)
        #expect(request.followingServer(finishedElsewhere)?.resumePosition == 0)
        #expect(request.followingServer(DetailFixtures.episode(3, offsetMs: 601_000)) == nil, "within the report tolerance")
        #expect(PlaybackRequest(item: stale, resumePosition: 0).followingServer(movedOn) == nil, "a chosen start stays")

        let nearEnd = DetailFixtures.episode(3, offsetMs: 2_350_000)
        let continuing = PlaybackRequest(ratingKey: "e13", mediaType: "episode", showRatingKey: nil, seasonRatingKey: nil, resumePosition: 600, serverStart: .continueWatching)
        #expect(continuing.followingServer(nearEnd)?.resumePosition == 0)
    }

    @Test func aRunTheServerHasNotHeardOfYetIsWhereTheTitleStarts() throws {
        let saved = Date(timeIntervalSince1970: 1_800_000_000)
        let server = DetailFixtures.item(["ratingKey": "e13", "type": "episode", "viewOffset": 600_000, "duration": 2_400_000, "lastViewedAt": 1_799_999_000])
        let request = PlaybackRequest(item: DetailFixtures.item(["ratingKey": "e13", "type": "episode", "viewOffset": 300_000, "duration": 2_400_000]))
        func point(_ secs: Double, reported: Double? = nil, finished: Bool = false, ratingKey: String = "e13") -> ResumePoint {
            ResumePoint(server: "s", ratingKey: ratingKey, positionSecs: secs, durationSecs: 2_400, savedAt: saved, reportedSecs: reported, finished: finished)
        }
        #expect(request.followingServer(server, devicePoint: point(900))?.resumePosition == 900, "the stop report is still on its way")
        #expect(request.followingServer(server, devicePoint: point(900, reported: 900))?.resumePosition == 600, "the server already has it")
        #expect(request.followingServer(server, devicePoint: point(900, ratingKey: "other"))?.resumePosition == 600)
        #expect(request.followingServer(server, devicePoint: point(2_390, finished: true))?.resumePosition == 0, "a finished run starts over")
        let watchedSince = DetailFixtures.item(["ratingKey": "e13", "type": "episode", "viewCount": 1, "duration": 2_400_000, "lastViewedAt": 1_800_000_500])
        #expect(request.followingServer(watchedSince, devicePoint: point(900))?.resumePosition == 0, "another device finished it since")
        let playedSince = DetailFixtures.item(["ratingKey": "e13", "type": "episode", "viewOffset": 1_500_000, "duration": 2_400_000, "lastViewedAt": 1_800_000_600])
        #expect(request.followingServer(playedSince, devicePoint: point(900))?.resumePosition == 1_500, "another device watched further since")
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

    // MARK: - Entering the app

    /// Every entry hands the server what this device still owes before any screen reads it, so nothing on screen can be older
    /// than what this device did.
    @Test func anEntryReportsWhatTheDeviceOwesBeforeScreensReadAgain() async throws {
        let server = DetailStubServer()
        server.reply(path: "/library/metadata/7", items: [DetailFixtures.item(["ratingKey": "7", "duration": 2_400_000, "viewOffset": 12_000])])
        server.reply(path: "/:/timeline")
        let store = PlaybackResumeStore(defaults: resumeDefaults())
        let center = ServerStateSync(hub: ServerEventHub(), resumeStore: store)
        center.attach(api: server.client, server: "srv")
        var heard: [ServerStateChange] = []
        let token = center.addObserver { heard.append($0) }
        store.save(server: "srv", ratingKey: "7", positionSecs: 1_312.6, durationSecs: 2_400)

        center.enteredForeground()

        try await settle(until: { server.requests.contains("/:/timeline") }, timeout: .seconds(10))
        #expect(server.requestedURLs.first { $0.contains("/:/timeline") }?.contains("time=1312600") == true)
        #expect(store.pendingReports(server: "srv").isEmpty)
        try await settle(until: { heard.contains { $0.everything } }, timeout: .seconds(10))
        center.removeObserver(token)
        center.detach()
    }

    /// A wake from sleep often finds the network not back yet: the position is tried again until the server takes it, and the
    /// screens read once more when it does, since what they read the first time was before the report landed.
    @Test func aPositionTheServerCouldNotTakeIsSentAgainWhileTheAppStaysInFront() async throws {
        let server = DetailStubServer()
        server.failTransport(path: "/library/metadata/7")
        let store = PlaybackResumeStore(defaults: resumeDefaults())
        let center = ServerStateSync(hub: ServerEventHub(), resumeStore: store)
        center.attach(api: server.client, server: "srv")
        var heard: [ServerStateChange] = []
        let token = center.addObserver { heard.append($0) }
        store.save(server: "srv", ratingKey: "7", positionSecs: 1_312.6, durationSecs: 2_400)

        center.enteredForeground()
        try await Task.sleep(for: .milliseconds(400))
        #expect(store.pendingReports(server: "srv").count == 1, "the server was not there for the first pass")

        server.reply(path: "/library/metadata/7", items: [DetailFixtures.item(["ratingKey": "7", "duration": 2_400_000, "viewOffset": 12_000])])
        server.reply(path: "/:/timeline")
        try await settle(until: { server.requests.contains("/:/timeline") }, timeout: .seconds(20))
        #expect(store.pendingReports(server: "srv").isEmpty)
        try await settle(until: { heard.filter { $0.everything }.count >= 2 }, timeout: .seconds(10))
        center.removeObserver(token)
        center.detach()
    }

    /// Leaving the app stops the retries: a position still owed waits for the next entry instead of being sent from the
    /// background, where the system may cut the request and no screen is there to read what landed.
    @Test func aPositionStillOwedWaitsForTheNextEntryWhenTheAppLeavesTheFront() async throws {
        let server = DetailStubServer()
        server.failTransport(path: "/library/metadata/7")
        let store = PlaybackResumeStore(defaults: resumeDefaults())
        let center = ServerStateSync(hub: ServerEventHub(), resumeStore: store)
        center.attach(api: server.client, server: "srv")
        store.save(server: "srv", ratingKey: "7", positionSecs: 1_312.6, durationSecs: 2_400)

        center.enteredForeground()
        try await Task.sleep(for: .milliseconds(400))
        center.enteredBackground()
        server.reply(path: "/library/metadata/7", items: [DetailFixtures.item(["ratingKey": "7", "duration": 2_400_000, "viewOffset": 12_000])])
        server.reply(path: "/:/timeline")
        try await Task.sleep(for: .seconds(2))
        #expect(!server.requests.contains("/:/timeline"), "nothing is sent while the app is away")
        #expect(store.pendingReports(server: "srv").count == 1)

        center.enteredForeground()
        try await settle(until: { server.requests.contains("/:/timeline") }, timeout: .seconds(10))
        #expect(store.pendingReports(server: "srv").isEmpty)
        center.detach()
    }

    private func resumeDefaults() -> UserDefaults {
        let suite = "server-state-entry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Waits for `condition`, polling, and fails the test when it never holds.
    private func settle(until condition: () -> Bool, timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("condition not met within \(timeout)")
    }
}

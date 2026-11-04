@testable import CrucibleCore
import Foundation
import Testing
@testable import CrucibleDemo

/// The demo server's notification stream: the app connects to it like to a real server's, and scans and playback announce
/// themselves on it.
@MainActor
struct DemoEventsTests {
    @MainActor
    private final class Counts {
        var activity = 0
        var library = 0
        var playback = 0
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func scansAndPlaybackElsewhereArriveOnTheEventStream() async throws {
        let demo = try await DemoHarness.start()
        let hub = ServerEventHub()
        let counts = Counts()
        let listenings = [
            hub.listen(api: demo.api, every: .milliseconds(100), matching: \.isActivity) { counts.activity += 1 },
            hub.listen(api: demo.api, every: .milliseconds(100), matching: \.isLibraryChange) { counts.library += 1 },
            hub.listen(api: demo.api, every: .milliseconds(100), matching: \.isStopElsewhere) { counts.playback += 1 },
        ]
        let events = await demo.provider.library?.events
        try await waitUntil { events?.listenerCount == 1 }
        #expect(events?.listenerCount == 1, "one stream serves every listener")

        try await LibraryManagement.scan(sectionId: "1", force: false, api: demo.api)
        try await waitUntil { counts.activity == 1 }
        #expect(counts.activity == 1)
        let scan = try #require(try await LibraryManagement.activities(api: demo.api).first)
        try await LibraryManagement.cancel(scan, api: demo.api)
        try await waitUntil { counts.library == 1 }
        #expect(counts.library == 1, "the end of a scan is a library change")

        _ = try await demo.get("/:/timeline?ratingKey=1001&state=stopped&time=60000&duration=8040000", headers: ["X-Plex-Client-Identifier": "living-room"])
        try await waitUntil { counts.playback == 1 }
        #expect(counts.playback == 1, "playback stopped on another device arrives")

        listenings.forEach { $0.cancel() }
        try await waitUntil { events?.listenerCount == 0 }
        #expect(events?.listenerCount == 0, "the last listener to leave closes the stream")
        await demo.stop()
    }
}

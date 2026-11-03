import Foundation
import Testing
@testable import CrucibleCore

struct ServerEventsTests {
    private func parse(_ text: String) -> [(type: String?, data: String)] {
        var parser = ServerEventParser()
        return text.components(separatedBy: "\n").compactMap { parser.feed($0) }
    }

    @Test func eventsEndAtABlankLineAndCommentsAreSkipped() {
        let events = parse(": keep-alive\nevent: playing\ndata: {\"a\":1}\n\nevent: ping\n\ndata: one\ndata: two\n\n")
        #expect(events.count == 2)
        #expect(events[0].type == "playing")
        #expect(events[0].data == "{\"a\":1}")
        #expect(events[1].type == nil)
        #expect(events[1].data == "one\ntwo")
    }

    @Test func aPlaybackEventNamesTheTitleAndTheDevice() {
        let data = #"{"PlaySessionStateNotification":[{"sessionKey":"7","clientIdentifier":"tv-1","ratingKey":"4013","viewOffset":12000,"state":"stopped"}]}"#
        #expect(ServerEventDecoder.events(type: "playing", data: data) == [.playback(ratingKey: "4013", state: "stopped", clientIdentifier: "tv-1")])
        let wrapped = #"{"NotificationContainer":{"type":"playing","size":1,"PlaySessionStateNotification":{"ratingKey":4013,"state":"paused"}}}"#
        #expect(ServerEventDecoder.events(type: nil, data: wrapped) == [.playback(ratingKey: "4013", state: "paused", clientIdentifier: nil)])
    }

    @Test func theEndOfALibraryScanIsAlsoALibraryChange() {
        let data = #"{"ActivityNotification":[{"event":"ended","uuid":"u1","Activity":{"uuid":"u1","type":"library.update.section","progress":100,"Context":{"librarySectionID":"2"}}}]}"#
        #expect(ServerEventDecoder.events(type: "activity", data: data) == [
            .activity(type: "library.update.section", event: "ended", progress: 100),
            .library(sectionID: "2", ratingKey: nil),
        ])
        let progress = #"{"ActivityNotification":[{"event":"updated","Activity":{"type":"media.generate.bif","progress":"42"}}]}"#
        #expect(ServerEventDecoder.events(type: "activity", data: progress) == [.activity(type: "media.generate.bif", event: "updated", progress: 42)])
    }

    @Test func onlySettledVideoTitlesOfALibraryCountAsChanges() {
        let entries = #"""
        {"TimelineEntry":[
         {"identifier":"com.plexapp.plugins.library","sectionID":"1","itemID":"9001","type":1,"state":5},
         {"identifier":"com.plexapp.plugins.library","sectionID":"1","itemID":"9002","type":1,"state":0},
         {"identifier":"com.plexapp.plugins.library","sectionID":"3","itemID":"9003","type":8,"state":5},
         {"identifier":"com.plexapp.plugins.library","sectionID":"2","itemID":"9004","type":"4","state":"9"},
         {"identifier":"com.plexapp.system","sectionID":"1","itemID":"9005","type":1,"state":5}
        ]}
        """#
        #expect(ServerEventDecoder.events(type: "timeline", data: entries) == [
            .library(sectionID: "1", ratingKey: "9001"),
            .library(sectionID: "2", ratingKey: "9004"),
        ])
    }

    @Test func unknownKindsAndBrokenBodiesAreIgnored() {
        #expect(ServerEventDecoder.events(type: "reachability", data: #"{"ReachabilityNotification":[{}]}"#).isEmpty)
        #expect(ServerEventDecoder.events(type: "playing", data: "not json").isEmpty)
        #expect(ServerEventDecoder.events(type: "playing", data: #"{"PlaySessionStateNotification":[{"ratingKey":"1"}]}"#).isEmpty)
    }

    @Test func playbackOnThisDeviceIsNotPlaybackElsewhere() {
        let own = ServerEvent.playback(ratingKey: "1", state: "stopped", clientIdentifier: PlexHeaders.clientIdentifier)
        let other = ServerEvent.playback(ratingKey: "1", state: "stopped", clientIdentifier: "living-room")
        #expect(!own.isPlaybackElsewhere)
        #expect(other.isPlaybackElsewhere && other.isStopElsewhere)
        #expect(!ServerEvent.playback(ratingKey: "1", state: "playing", clientIdentifier: "living-room").isStopElsewhere)
        #expect(ServerEvent.library(sectionID: nil, ratingKey: nil).isLibraryChange)
        #expect(ServerEvent.activity(type: nil, event: nil, progress: nil).isActivity)
    }

    @Test func refusalsStopTheRetriesAndFailuresWaitLonger() {
        #expect(ServerEventStream.isRefusal(404))
        #expect(ServerEventStream.isRefusal(401))
        #expect(!ServerEventStream.isRefusal(429))
        #expect(!ServerEventStream.isRefusal(503))
        #expect(ServerEventStream.backoff(after: 0) == .seconds(1))
        #expect(ServerEventStream.backoff(after: 1) == .seconds(4))
        #expect(ServerEventStream.backoff(after: 3) == .seconds(16))
        #expect(ServerEventStream.backoff(after: 9) == .seconds(60))
    }

    @MainActor
    @Test func aBurstOfEventsRunsTheActionOnceAndARefusingServerIsLeftAlone() async throws {
        let server = DetailStubServer()
        let hub = ServerEventHub()
        var runs = 0
        let listening = hub.listen(api: server.client, every: .milliseconds(200), matching: \.isLibraryChange) { runs += 1 }
        for _ in 0..<5 { hub.receive(.library(sectionID: "1", ratingKey: nil)) }
        hub.receive(.activity(type: nil, event: nil, progress: nil))
        try await Task.sleep(for: .milliseconds(600))
        #expect(runs == 1)
        hub.receive(.library(sectionID: "1", ratingKey: nil))
        try await Task.sleep(for: .milliseconds(600))
        #expect(runs == 2)
        #expect(server.requests == ["/:/eventsource/notifications"])
        #expect(!hub.isConnected)
        listening.cancel()
        hub.receive(.library(sectionID: "1", ratingKey: nil))
        try await Task.sleep(for: .milliseconds(400))
        #expect(runs == 2)
    }
}

import Foundation
import Testing
@testable import CrucibleCore

struct WarmStartTests {
    private func stream(directPlay: Bool, video: String? = nil) -> ResolvedStream {
        ResolvedStream(
            url: URL(string: "http://server.test/stream")!,
            isDirectPlay: directPlay,
            sessionId: "s",
            subtitles: [],
            audioTracks: [],
            markers: [],
            decision: video.map { PlaybackDecision(generalCode: nil, generalText: nil, videoDecision: $0) }
        )
    }

    private func request(
        ratingKey: String = "42",
        resume: Double = 0,
        subtitle: Int? = nil,
        audio: Int? = nil,
        offline: OfflinePlaybackSource? = nil,
        serverStart: ServerStart? = nil
    ) -> PlaybackRequest {
        PlaybackRequest(
            ratingKey: ratingKey,
            mediaType: "movie",
            showRatingKey: nil,
            seasonRatingKey: nil,
            resumePosition: resume,
            selectedSubtitleId: subtitle,
            selectedAudioStreamId: audio,
            offline: offline,
            serverStart: serverStart
        )
    }

    @Test func aStreamCostsTheServerWhatItHasToDoForIt() {
        #expect(StreamCost(stream(directPlay: true)) == .file)
        #expect(StreamCost(stream(directPlay: false, video: "copy")) == .remux)
        #expect(StreamCost(stream(directPlay: false, video: "transcode")) == .encode)
    }

    @Test func aStreamServedFromTheDeviceItselfCostsNothing() {
        let demo = ResolvedStream(url: URL(string: "http://127.0.0.1:59298/video/start.m3u8")!, isDirectPlay: false, sessionId: "s",
                                  subtitles: [], audioTracks: [], markers: [])
        #expect(StreamCost(demo) == .file)
    }

    @Test func theLogIsToldWhyNothingIsMadeReady() {
        #expect(WarmConditions().refusal == nil)
        #expect(WarmConditions(isEnabled: false).refusal == "switched off")
        #expect(WarmConditions(isHot: true).refusal == "the device is hot")
        #expect(WarmConditions(isCellular: true, savesPower: true).refusal == nil)
    }

    @Test func aConvertedStreamTheServerSaidNothingAboutIsTakenForAnEncode() {
        #expect(StreamCost(stream(directPlay: false)) == .encode)
    }

    @Test func aFileIsLoadedForAnyoneWhoRestsOnIt() {
        #expect(WarmStartRule.depth(intent: .browsing, cost: .file, conditions: WarmConditions()) == .loaded)
        #expect(WarmStartRule.depth(intent: .poised, cost: .file, conditions: WarmConditions()) == .loaded)
    }

    @Test func aRemuxOnlyStartsOnTheServerOnceTheViewerIsPoisedToPlay() {
        #expect(WarmStartRule.depth(intent: .browsing, cost: .remux, conditions: WarmConditions()) == .resolved)
        #expect(WarmStartRule.depth(intent: .poised, cost: .remux, conditions: WarmConditions()) == .loaded)
    }

    @Test func theServersEncoderIsNeverSpentAheadOfPlay() {
        #expect(WarmStartRule.depth(intent: .poised, cost: .encode, conditions: WarmConditions()) == .resolved)
    }

    @Test func nothingIsLoadedOnMobileDataALowBatteryOrBesideAPlayingStream() {
        for conditions in [WarmConditions(isCellular: true), WarmConditions(savesPower: true), WarmConditions(isPlaying: true)] {
            #expect(WarmStartRule.depth(intent: .poised, cost: .file, conditions: conditions) == .resolved)
        }
    }

    @Test func switchedOffOrOnAHotDeviceNothingIsMadeReady() {
        for conditions in [WarmConditions(isEnabled: false), WarmConditions(isHot: true)] {
            #expect(!WarmStartRule.allows(conditions))
            #expect(WarmStartRule.depth(intent: .poised, cost: .file, conditions: conditions) == .none)
        }
    }

    @Test func aStartThatFollowsTheServerMatchesWhateverSecondTheScreenRead() {
        let warmed = WarmKey(request(resume: 610, serverStart: .resume))
        let played = WarmKey(request(resume: 0, serverStart: .resume))
        #expect(warmed != nil)
        #expect(warmed == played)
    }

    @Test func aStartTheViewerChoseOnlyMatchesTheSameSecond() {
        #expect(WarmKey(request(resume: 0)) == WarmKey(request(resume: 0.3)))
        #expect(WarmKey(request(resume: 0)) != WarmKey(request(resume: 610)))
        #expect(WarmKey(request(resume: 610)) != WarmKey(request(resume: 610, serverStart: .resume)))
        #expect(WarmKey(request(serverStart: .resume)) != WarmKey(request(serverStart: .continueWatching)))
    }

    @Test func otherTracksOrAnotherTitleAreAnotherPlayback() {
        let base = WarmKey(request(serverStart: .resume))
        #expect(base != WarmKey(request(subtitle: 7, serverStart: .resume)))
        #expect(base != WarmKey(request(audio: 3, serverStart: .resume)))
        #expect(base != WarmKey(request(ratingKey: "43", serverStart: .resume)))
    }

    @Test func aDownloadedTitleHasNothingToMakeReady() {
        let offline = OfflinePlaybackSource(fileURL: URL(fileURLWithPath: "/tmp/a.mp4"), markers: [], durationSecs: 60)
        #expect(WarmKey(request(offline: offline)) == nil)
    }

    @MainActor @Test func instantStartIsOnUntilSwitchedOff() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "instantStart")
        defer {
            if let previous { defaults.set(previous, forKey: "instantStart") } else { defaults.removeObject(forKey: "instantStart") }
        }
        defaults.removeObject(forKey: "instantStart")
        #expect(Preferences.instantStart)
        #expect(PreferenceSetting.instantStart.control == .toggle(isOn: true))
        PreferenceSetting.instantStart.setOn(false)
        #expect(!Preferences.instantStart)
    }
}

@MainActor
struct RestWatchTests {
    private final class Log {
        var rested: [String] = []
        var left: [String] = []
    }

    /// Waits until `done` holds, for as long as a loaded test run may need.
    private func settled(_ done: () -> Bool) async {
        for _ in 0..<500 where !done() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func watch(_ log: Log) -> RestWatch {
        RestWatch(rest: .milliseconds(40), settle: .milliseconds(120)) { log.left.append($0) }
    }

    @Test func aViewerWhoStopsIsBrowsingAndThenPoised() async throws {
        let log = Log()
        let watch = watch(log)
        watch.moved(onto: "a") { log.rested.append("a \($0)") }
        await settled { log.rested.count == 2 }
        #expect(log.rested == ["a browsing", "a poised"])
        #expect(log.left.isEmpty)
    }

    @Test func aViewerPassingThroughSetsNothingOff() async throws {
        let log = Log()
        let watch = watch(log)
        watch.moved(onto: "a") { log.rested.append("a \($0)") }
        watch.moved(onto: "b") { log.rested.append("b \($0)") }
        watch.moved(onto: nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(log.rested.isEmpty)
        #expect(log.left == ["a", "b"])
    }

    @Test func stayingOnTheSameThingDoesNotStartOver() async throws {
        let log = Log()
        let watch = watch(log)
        watch.moved(onto: "a") { log.rested.append("first \($0)") }
        watch.moved(onto: "a") { log.rested.append("second \($0)") }
        await settled { log.rested.count == 2 }
        #expect(log.rested == ["first browsing", "first poised"])
    }
}

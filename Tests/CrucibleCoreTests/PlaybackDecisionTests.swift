import Foundation
import Testing
@testable import CrucibleCore

struct PlaybackDecisionTests {
    private func data(_ json: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: json)
    }

    @Test func aConversionDecisionReadsItsCodesAndStreamDecisions() throws {
        let decision = try #require(PlaybackDecision.parse(data(["MediaContainer": [
            "generalDecisionCode": 1001, "generalDecisionText": "Direct play not available; Conversion OK.",
            "transcodeDecisionText": "Video codec not supported",
            "Metadata": [["Media": [["Part": [["Stream": [
                ["streamType": 1, "decision": "transcode"], ["streamType": 2, "decision": "copy"], ["streamType": 3, "decision": "burn"],
            ]]]]]]],
        ]])))
        #expect(decision.generalCode == 1001)
        #expect(!decision.isRefusal)
        #expect(decision.videoDecision == "transcode")
        #expect(decision.audioDecision == "copy")
        #expect(decision.subtitleDecision == "burn")
        #expect(decision.transcodeText == "Video codec not supported")
    }

    @Test func codesWrittenAsStringsStillCount() throws {
        let decision = try #require(PlaybackDecision.parse(data(["MediaContainer": ["generalDecisionCode": "2001", "generalDecisionText": "Not enough bandwidth"]])))
        #expect(decision.generalCode == 2001)
        #expect(decision.isRefusal)
    }

    @Test func aRefusalForThePassSaysWhatToDoAndAnyOtherQuotesTheServer() {
        let pass = PlaybackDecision(generalCode: 2000, generalText: "Remote streaming requires a Plex Pass or a Remote Watch Pass.")
        #expect(PlaybackDecisionCopy.refusalMessage(pass) == PlaybackDecisionCopy.remotePass)
        let bandwidth = PlaybackDecision(generalCode: 2001, generalText: "Not enough bandwidth for any playback of this item.")
        #expect(PlaybackDecisionCopy.refusalMessage(bandwidth) == "The server says: Not enough bandwidth for any playback of this item.")
        #expect(PlaybackDecisionCopy.refusalMessage(PlaybackDecision(generalCode: 2000, generalText: nil)) == "The server refused to play this title.")
        #expect(PlaybackDecision.parse(Data("not json".utf8)) == nil)
    }

    @Test func theDecisionAsksWithTheStartQuery() throws {
        let start = try #require(URL(string: "http://pms.test:32400/video/:/transcode/universal/start.m3u8?path=/library/metadata/5&session=abc"))
        let decision = try #require(StreamResolver.decisionURL(for: start))
        #expect(decision.path == "/video/:/transcode/universal/decision")
        #expect(decision.query == start.query)
        #expect(StreamResolver.decisionURL(for: URL(string: "http://pms.test/library/parts/1/file.mkv")!) == nil)
    }

    @Test func streamInfoNamesTheMethodTheRouteAndTheTracks() throws {
        let audio = try JSONDecoder().decode(PlexStream.self, from: Data(#"{"id": 11, "streamType": 2, "displayTitle": "English (EAC3 5.1)", "default": true}"#.utf8))
        let subtitle = try JSONDecoder().decode(PlexStream.self, from: Data(#"{"id": 21, "streamType": 3, "displayTitle": "Finnish (SRT)"}"#.utf8))
        let media = try JSONDecoder().decode(PlexMedia.self, from: Data(#"{"videoCodec": "hevc", "width": 3840, "height": 2160, "container": "mkv", "bitrate": 24500}"#.utf8))
        let stream = ResolvedStream(
            url: URL(string: "http://192.168.1.5:32400/video/:/transcode/universal/start.m3u8")!,
            isDirectPlay: false,
            sessionId: "s",
            subtitles: [subtitle],
            audioTracks: [audio],
            markers: [],
            media: media,
            decision: PlaybackDecision(generalCode: 1001, generalText: nil, transcodeText: "Subtitles must be burned in", videoDecision: "transcode", audioDecision: "copy", subtitleDecision: "burn")
        )
        let lines = StreamInfo.lines(stream: stream, route: .local, quality: .original, audioId: nil, subtitleId: 21)
        let byLabel = Dictionary(uniqueKeysWithValues: lines.map { ($0.label, $0.value) })
        #expect(byLabel["Playback"] == "Converting Video, Subtitles Burned In")
        #expect(byLabel["Connection"] == "Local")
        #expect(byLabel["Video"] == "HEVC · 4K")
        #expect(byLabel["File"] == "MKV")
        #expect(byLabel["Audio"] == "English (EAC3 5.1)")
        #expect(byLabel["Subtitles"] == "Finnish (SRT)")
        #expect(byLabel["Server"] == "Subtitles must be burned in")
        let direct = ResolvedStream(url: stream.url, isDirectPlay: true, sessionId: "s", subtitles: [], audioTracks: [audio], markers: [], media: media)
        let directLines = StreamInfo.lines(stream: direct, route: .remote, quality: .low, audioId: nil, subtitleId: nil)
        #expect(directLines.first?.value == "Direct Play")
        #expect(!directLines.contains { $0.label == "Quality" })
        #expect(directLines.contains { $0.label == "Subtitles" && $0.value == "Off" })
    }
}

@MainActor
struct SleepTimerTests {
    @Test func aTimedTimerCountsDownFadesAndComesDue() {
        let start = Date(timeIntervalSince1970: 1_000)
        let timer = SleepTimer(choice: .minutes(15), now: start)
        #expect(timer.remaining(now: start) == 900)
        #expect(!timer.startsFading(now: start.addingTimeInterval(890)))
        #expect(timer.startsFading(now: start.addingTimeInterval(893)))
        #expect(!timer.isDue(now: start.addingTimeInterval(899)))
        #expect(timer.isDue(now: start.addingTimeInterval(900)))
        #expect(timer.menuTitle(isEpisode: true, now: start.addingTimeInterval(61)) == "Sleep Timer · 14 min left")
    }

    @Test func endOfItemNeverRunsOutOnTheClockAndNamesWhatEnds() {
        let timer = SleepTimer(choice: .endOfItem, now: Date())
        #expect(timer.stopsAtEndOfItem)
        #expect(timer.remaining() == nil)
        #expect(!timer.isDue(now: .distantFuture))
        #expect(timer.menuTitle(isEpisode: true) == "Sleep Timer · End of Episode")
        #expect(SleepTimerChoice.endOfItem.title(isEpisode: false) == "End of Movie")
        #expect(SleepTimerChoice.all.first?.title(isEpisode: true) == "15 Minutes")
    }

    @Test func anOfferWithoutAutoplayKeepsEverythingElse() {
        let episode = HomeFixtures.item("9", type: "episode")
        let offer = UpNextOffer(episode: episode, seasonRatingKey: "3", reason: .credits, autoplays: true)
        let quiet = offer.withoutAutoplay()
        #expect(!quiet.autoplays)
        #expect(quiet.episode.id == "9")
        #expect(quiet.seasonRatingKey == "3")
        #expect(quiet.reason == .credits)
    }
}

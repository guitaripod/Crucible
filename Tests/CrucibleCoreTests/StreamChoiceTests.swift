import Foundation
import Testing
@testable import CrucibleCore

struct StreamChoiceTests {
    private func stream(_ delivery: SubtitleDelivery, subtitle: Int?) -> ResolvedStream {
        let audio = [(2, true), (3, false)].map { id, isDefault in
            try! JSONDecoder().decode(PlexStream.self, from: JSONSerialization.data(withJSONObject: ["id": id, "streamType": 2, "default": isDefault]))
        }
        return ResolvedStream(
            url: URL(string: "http://server/start.m3u8")!, isDirectPlay: false, sessionId: "s", subtitles: [], audioTracks: audio, markers: [],
            chosenSubtitleId: subtitle, subtitleDelivery: delivery
        )
    }

    @Test func showingOrHidingTheSubtitleInTheStreamKeepsTheStream() {
        let track = stream(.track, subtitle: 9)
        #expect(StreamChoice(subtitleId: nil, audioStreamId: nil).keepsStream(of: track, playingAudio: nil))
        #expect(StreamChoice(subtitleId: 9, audioStreamId: 2).keepsStream(of: track, playingAudio: nil))
        #expect(!StreamChoice(subtitleId: 10, audioStreamId: nil).keepsStream(of: track, playingAudio: nil))
    }

    @Test func anotherAudioTrackNeedsANewStream() {
        #expect(!StreamChoice(subtitleId: 9, audioStreamId: 3).keepsStream(of: stream(.track, subtitle: 9), playingAudio: nil))
        #expect(StreamChoice(subtitleId: 9, audioStreamId: 3).keepsStream(of: stream(.track, subtitle: 9), playingAudio: 3))
    }

    @Test func aBurnedSubtitleCanOnlyStayAsItIs() {
        let burned = stream(.burned, subtitle: 9)
        #expect(!StreamChoice(subtitleId: nil, audioStreamId: nil).keepsStream(of: burned, playingAudio: nil))
        #expect(StreamChoice(subtitleId: 9, audioStreamId: nil).keepsStream(of: burned, playingAudio: nil))
    }

    @Test func aStreamWithoutSubtitlesNeedsANewOneForAnySubtitle() {
        let plain = stream(.none, subtitle: nil)
        #expect(StreamChoice(subtitleId: nil, audioStreamId: nil).keepsStream(of: plain, playingAudio: nil))
        #expect(!StreamChoice(subtitleId: 9, audioStreamId: nil).keepsStream(of: plain, playingAudio: nil))
    }
}

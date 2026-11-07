import Foundation
import Testing
@testable import CrucibleCore

struct TrackLanguagesTests {
    private func stream(_ id: Int, _ type: Int, _ code: String?, title: String? = nil, channels: Int? = nil, isDefault: Bool = false, forced: Bool = false, codec: String? = nil) -> PlexStream {
        var fields: [String: Any] = ["id": id, "streamType": type, "default": isDefault, "forced": forced]
        if let code { fields["languageCode"] = code }
        if let codec { fields["codec"] = codec }
        if let title { fields["title"] = title }
        if let channels { fields["channels"] = channels }
        let data = try! JSONSerialization.data(withJSONObject: fields)
        return try! JSONDecoder().decode(PlexStream.self, from: data)
    }

    private var audio: [PlexStream] {
        [
            stream(2, 2, "eng", title: "Surround", channels: 6, isDefault: true),
            stream(3, 2, "jpn", channels: 6),
            stream(4, 2, "eng", title: "Commentary", channels: 2),
        ]
    }

    private var subtitles: [PlexStream] {
        [
            stream(10, 3, "eng", title: "Signs & Songs", forced: true),
            stream(11, 3, "eng"),
            stream(12, 3, "eng", title: "SDH"),
            stream(13, 3, "fin"),
        ]
    }

    @Test func theDefaultAudioWithoutSubtitlesToChooseAsksForNothing() {
        #expect(TrackLanguages(subtitleId: nil, audioStreamId: 2, subtitles: [], audioTracks: audio).isDefault)
        #expect(TrackLanguages(subtitleId: nil, audioStreamId: nil, subtitles: [], audioTracks: audio).isDefault)
    }

    @Test func subtitlesTurnedOffAreAChoiceButNoneEverPickedIsNot() {
        let off = TrackLanguages(subtitleId: nil, audioStreamId: 2, subtitles: subtitles, audioTracks: audio, subtitlesOff: true)
        #expect(off.subtitlesOff)
        #expect(!off.isDefault)
        #expect(off.streamIds(subtitles: subtitles, audioTracks: audio) == (nil, nil))
        #expect(TrackLanguages(subtitleId: nil, audioStreamId: 2, subtitles: subtitles, audioTracks: audio).isDefault)
        #expect(!TrackLanguages(subtitleId: 11, audioStreamId: 2, subtitles: subtitles, audioTracks: audio, subtitlesOff: true).subtitlesOff)
        #expect(!TrackLanguages(subtitleId: nil, audioStreamId: 2, subtitles: [], audioTracks: audio, subtitlesOff: true).subtitlesOff)
        #expect(!TrackLanguages(audio: nil, subtitle: .init(language: "eng"), subtitlesOff: true).subtitlesOff)
    }

    @Test func languagesSavedBeforeSubtitlesOffExistedStillDecode() throws {
        let old = Data(#"{"subtitle":{"language":"eng","forced":false}}"#.utf8)
        let decoded = try JSONDecoder().decode(TrackLanguages.self, from: old)
        #expect(decoded.subtitle == .init(language: "eng"))
        #expect(!decoded.subtitlesOff)
        let off = TrackLanguages(audio: nil, subtitle: nil, subtitlesOff: true)
        #expect(try JSONDecoder().decode(TrackLanguages.self, from: JSONEncoder().encode(off)) == off)
    }

    @Test func anImageSubtitleIsNeverPickedForARememberedLanguage() {
        let image = stream(40, 3, "eng", codec: "hdmv_pgs_subtitle")
        let text = stream(41, 3, "eng", codec: "srt")
        let english = TrackLanguages(audio: nil, subtitle: .init(language: "eng"))
        #expect(english.streamIds(subtitles: [image, text], audioTracks: audio) == (41, nil))
        #expect(english.streamIds(subtitles: [image], audioTracks: audio) == (nil, nil))
    }

    @Test func choicesBecomeLanguagesWithTheKindOfTrack() {
        let languages = TrackLanguages(subtitleId: 12, audioStreamId: 4, subtitles: subtitles, audioTracks: audio)
        #expect(languages.audio == .init(language: "eng", title: "Commentary", forced: false, channels: 2))
        #expect(languages.subtitle == .init(language: "eng", title: "SDH", forced: false, channels: nil))
    }

    @Test func anotherEpisodeFindsTheSameKindOfTrackAmongItsOwnStreams() {
        let next = (
            audio: [stream(102, 2, "eng", title: "Surround", channels: 6, isDefault: true), stream(103, 2, "eng", title: "Commentary", channels: 2), stream(104, 2, "jpn", channels: 6)],
            subtitles: [stream(110, 3, "eng"), stream(111, 3, "eng", title: "SDH"), stream(112, 3, "eng", title: "Signs & Songs", forced: true)]
        )
        let commentary = TrackLanguages(subtitleId: 12, audioStreamId: 4, subtitles: subtitles, audioTracks: audio)
        #expect(commentary.streamIds(subtitles: next.subtitles, audioTracks: next.audio) == (111, 103))
        let japanese = TrackLanguages(subtitleId: 10, audioStreamId: 3, subtitles: subtitles, audioTracks: audio)
        #expect(japanese.streamIds(subtitles: next.subtitles, audioTracks: next.audio) == (112, 104))
    }

    @Test func aForcedSubtitleIsNeverSwappedForAFullOne() {
        let forced = TrackLanguages(audio: nil, subtitle: .init(language: "eng", forced: true))
        let onlyFull = [stream(20, 3, "eng"), stream(21, 3, "fin")]
        #expect(forced.streamIds(subtitles: onlyFull, audioTracks: audio) == (nil, nil))
        let full = TrackLanguages(audio: nil, subtitle: .init(language: "eng"))
        #expect(full.streamIds(subtitles: [stream(22, 3, "eng", forced: true), stream(23, 3, "eng")], audioTracks: audio) == (23, nil))
    }

    @Test func aLanguageTheEpisodeLacksFallsBackToItsDefaults() {
        let korean = TrackLanguages(audio: .init(language: "kor"), subtitle: .init(language: "kor"))
        #expect(korean.streamIds(subtitles: subtitles, audioTracks: audio) == (nil, nil))
    }

    @Test func audioMatchingTheDefaultNeedsNoSelection() {
        let english = TrackLanguages(audio: .init(language: "eng", channels: 6), subtitle: nil)
        #expect(english.streamIds(subtitles: subtitles, audioTracks: audio) == (nil, nil))
    }

    @Test func streamsWithoutALanguageAreNotRemembered() {
        let unknown = [stream(30, 2, nil, isDefault: true), stream(31, 2, nil)]
        #expect(TrackLanguages(subtitleId: nil, audioStreamId: 31, subtitles: [], audioTracks: unknown).isDefault)
    }
}

struct ShowTrackMemoryTests {
    private func defaults() -> UserDefaults {
        let suite = "show-track-memory-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private let japanese = TrackLanguages(audio: .init(language: "jpn"), subtitle: .init(language: "eng"))

    @Test func aShowRemembersItsLanguagesPerServer() {
        let store = defaults()
        ShowTrackMemory.remember(japanese, forShow: "2001", server: "a", defaults: store)
        #expect(ShowTrackMemory.languages(forShow: "2001", server: "a", defaults: store) == japanese)
        #expect(ShowTrackMemory.languages(forShow: "2001", server: "b", defaults: store) == nil)
        #expect(ShowTrackMemory.languages(forShow: "2002", server: "a", defaults: store) == nil)
        #expect(ShowTrackMemory.languages(forShow: nil, server: "a", defaults: store) == nil)
    }

    @Test func turningSubtitlesOffIsRemembered() {
        let store = defaults()
        let off = TrackLanguages(audio: nil, subtitle: nil, subtitlesOff: true)
        ShowTrackMemory.remember(off, forShow: "2001", server: "a", defaults: store)
        #expect(ShowTrackMemory.languages(forShow: "2001", server: "a", defaults: store) == off)
    }

    @Test func goingBackToTheDefaultsForgetsTheShow() {
        let store = defaults()
        ShowTrackMemory.remember(japanese, forShow: "2001", server: "a", defaults: store)
        ShowTrackMemory.remember(TrackLanguages(audio: nil, subtitle: nil), forShow: "2001", server: "a", defaults: store)
        #expect(ShowTrackMemory.languages(forShow: "2001", server: "a", defaults: store) == nil)
    }

    @Test func onlyTheMostRecentlyChangedShowsAreKept() {
        let store = defaults()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for index in 0...ShowTrackMemory.limit {
            ShowTrackMemory.remember(japanese, forShow: "\(index)", server: "a", now: start.addingTimeInterval(Double(index)), defaults: store)
        }
        #expect(ShowTrackMemory.languages(forShow: "0", server: "a", defaults: store) == nil)
        #expect(ShowTrackMemory.languages(forShow: "1", server: "a", defaults: store) == japanese)
        #expect(ShowTrackMemory.languages(forShow: "\(ShowTrackMemory.limit)", server: "a", defaults: store) == japanese)
    }

    @Test func signingOutForgetsEveryShow() {
        let store = defaults()
        ShowTrackMemory.remember(japanese, forShow: "2001", server: "a", defaults: store)
        ShowTrackMemory.forgetAll(defaults: store)
        #expect(ShowTrackMemory.languages(forShow: "2001", server: "a", defaults: store) == nil)
    }
}

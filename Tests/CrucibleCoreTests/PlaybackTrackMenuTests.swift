import Foundation
import Testing
@testable import CrucibleCore

struct PlaybackTrackMenuTests {
    private func streams(_ json: String) throws -> [PlexStream] {
        try JSONDecoder().decode([PlexStream].self, from: Data(json.utf8))
    }

    private func audio() throws -> [PlexStream] {
        try streams("""
        [{"id":2,"streamType":2,"codec":"aac","language":"English","channels":2,"default":true,"displayTitle":"English (AAC Stereo)"},
         {"id":3,"streamType":2,"codec":"eac3","language":"Spanish","channels":6,"displayTitle":"Spanish (EAC3 5.1)"}]
        """)
    }

    private func subtitles() throws -> [PlexStream] {
        try streams("""
        [{"id":5,"streamType":3,"codec":"srt","language":"English","displayTitle":"English (SRT)"},
         {"id":6,"streamType":3,"codec":"pgssub","language":"French","displayTitle":"French (PGS)"}]
        """)
    }

    @Test func theDefaultAudioTrackIsMarkedWhenNothingWasPicked() throws {
        let options = PlaybackTrackMenu.audioOptions(try audio(), selectedId: nil)
        #expect(options.map(\.isSelected) == [true, false])
        #expect(options.map(\.title) == ["English (AAC Stereo)", "Spanish (EAC3 5.1)"])
        #expect(!options.contains { !$0.isEnabled })
    }

    @Test func thePickedAudioTrackIsMarked() throws {
        let options = PlaybackTrackMenu.audioOptions(try audio(), selectedId: 3)
        #expect(options.map(\.isSelected) == [false, true])
    }

    @Test func anUnknownPickFallsBackToTheDefaultAudioTrack() throws {
        let tracks = try audio()
        #expect(PlaybackTrackMenu.playingAudioId(tracks, selectedId: 99) == 2)
        #expect(PlaybackTrackMenu.playingAudioId([], selectedId: nil) == nil)
    }

    @Test func withoutADefaultTheFirstAudioTrackPlays() throws {
        let tracks = try streams(#"[{"id":7,"streamType":2,"codec":"aac"},{"id":8,"streamType":2,"codec":"aac"}]"#)
        #expect(PlaybackTrackMenu.playingAudioId(tracks, selectedId: nil) == 7)
    }

    @Test func subtitlesStartWithOffSelectedWhenNoneIsPicked() throws {
        let options = PlaybackTrackMenu.subtitleOptions(try subtitles(), selectedId: nil)
        #expect(options.map(\.title) == ["Off", "English (SRT)", "French (PGS)"])
        #expect(options.map(\.isSelected) == [true, false, false])
    }

    @Test func aPickedSubtitleReplacesOffAsTheSelection() throws {
        let options = PlaybackTrackMenu.subtitleOptions(try subtitles(), selectedId: 5)
        #expect(options.map(\.isSelected) == [false, true, false])
    }

    @Test func imageBasedSubtitlesAreListedButDisabled() throws {
        let options = PlaybackTrackMenu.subtitleOptions(try subtitles(), selectedId: 6)
        #expect(options[2].isEnabled == false)
        #expect(options[2].isSelected == false)
        #expect(options[2].detail == "Image-based")
        #expect(options[1].isEnabled)
    }
}

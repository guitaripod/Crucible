import Foundation
import Testing
@testable import CrucibleCore

struct PlaybackLifecycleTests {
    @Test func theCardCountsDownInDigitsAndSpeaksInWords() {
        #expect(UpNextText.secondary(code: "S02E06", remaining: 7, counting: true) == "S02E06 · Playing in 7 s")
        #expect(UpNextText.spokenSecondary(code: "S02E06", remaining: 7, counting: true) == "S02E06, Playing in 7 seconds")
        #expect(UpNextText.spokenSecondary(code: nil, remaining: 1, counting: true) == "Playing in 1 second")
    }

    @Test func withoutACountdownTheCardJustNamesTheNextEpisode() {
        #expect(UpNextText.secondary(code: "S02E06", remaining: 10, counting: false) == "S02E06 · Next episode")
        #expect(UpNextText.spokenSecondary(code: nil, remaining: 10, counting: false) == "Next episode")
    }

    @Test func theAnnouncementSaysWhenTheNextEpisodeStarts() {
        #expect(UpNextText.announcement(code: "S02E06", title: "The Long Ebb", seconds: 10) == "Next episode in 10 seconds: S02E06 The Long Ebb")
        #expect(UpNextText.announcement(code: nil, title: "Pilot", seconds: nil) == "Up next: Pilot")
    }

    @Test func aRunningEndOfItemLookupIsNotReplaced() {
        var gate = UpNextLookupGate()
        let first = gate.begin(.playbackEnded)
        let requested = gate.begin(.requested)
        let credits = gate.begin(.credits)
        let again = gate.begin(.playbackEnded)
        #expect(first)
        #expect(!requested)
        #expect(!credits)
        #expect(again)
    }

    @Test func otherLookupsReplaceEachOther() {
        var gate = UpNextLookupGate()
        let credits = gate.begin(.credits)
        let requested = gate.begin(.requested)
        let ended = gate.begin(.playbackEnded)
        #expect(credits && requested && ended)
    }

    @Test func aFinishedEndOfItemLookupNoLongerBlocksLaterOnes() {
        var gate = UpNextLookupGate()
        _ = gate.begin(.playbackEnded)
        gate.end(.playbackEnded)
        let credits = gate.begin(.credits)
        #expect(credits)
    }

    @Test func aStaleLookupCannotClearALaterOne() {
        var gate = UpNextLookupGate()
        _ = gate.begin(.credits)
        _ = gate.begin(.requested)
        gate.end(.credits)
        #expect(gate.running == .requested)
    }

    @Test func onlyAPausedTranscodeIsRestartedOnForeground() {
        #expect(PlaybackLifecyclePolicy.restartsTranscodeOnForeground(isDirectPlay: false, isPaused: true, isRestarting: false))
        #expect(!PlaybackLifecyclePolicy.restartsTranscodeOnForeground(isDirectPlay: true, isPaused: true, isRestarting: false))
        #expect(!PlaybackLifecyclePolicy.restartsTranscodeOnForeground(isDirectPlay: false, isPaused: false, isRestarting: false))
        #expect(!PlaybackLifecyclePolicy.restartsTranscodeOnForeground(isDirectPlay: false, isPaused: true, isRestarting: true))
    }

    @Test func aRetryKeepsTheViewersSwitchedStreams() {
        let request = PlaybackRequest(
            ratingKey: "5", mediaType: "episode", showRatingKey: "1", seasonRatingKey: "2",
            resumePosition: 10, selectedSubtitleId: 4, selectedAudioStreamId: 3
        )
        let switched = request.resuming(at: 90, selectedSubtitleId: .some(nil), selectedAudioStreamId: .some(8))
        let unchanged = request.resuming(at: 90)
        #expect(switched.selectedSubtitleId == nil)
        #expect(switched.selectedAudioStreamId == 8)
        #expect(unchanged.selectedSubtitleId == 4)
        #expect(unchanged.selectedAudioStreamId == 3)
    }
}

import Foundation
import Testing
@testable import CrucibleCore

struct PlaybackMarkerTrackerTests {
    private static let intro = PlexMarker(type: "intro", startTimeOffset: 12_000, endTimeOffset: 58_000, final: nil)
    private static let credits = PlexMarker(type: "credits", startTimeOffset: 2_000_000, endTimeOffset: 2_100_000, final: true)

    private func makeTracker(_ markers: [PlexMarker] = [PlaybackMarkerTrackerTests.intro, PlaybackMarkerTrackerTests.credits]) -> MarkerTracker {
        MarkerTracker(markers: markers)
    }

    private func introMarker() -> SkipMarker {
        SkipMarker(kind: .intro, startSecs: 12, endSecs: 58)
    }

    @Test func markerIsActiveFromItsStartUntilOneSecondBeforeItsEnd() {
        var tracker = makeTracker()
        #expect(tracker.evaluate(absolute: 11.99, mode: .button, upNextVisible: false, undoVisible: false) == .none)
        #expect(tracker.evaluate(absolute: 12, mode: .button, upNextVisible: false, undoVisible: false) == .showSkip(introMarker(), progress: 0))
        #expect(tracker.evaluate(absolute: 56.99, mode: .button, upNextVisible: false, undoVisible: false) != .hideSkip)
        #expect(tracker.evaluate(absolute: 57, mode: .button, upNextVisible: false, undoVisible: false) == .hideSkip)
    }

    @Test func buttonModeReportsProgressThroughTheMarker() {
        var tracker = makeTracker()
        let action = tracker.evaluate(absolute: 35, mode: .button, upNextVisible: false, undoVisible: false)
        #expect(action == .showSkip(introMarker(), progress: 0.5))
    }

    @Test func leavingTheWindowHidesTheControlExactlyOnce() {
        var tracker = makeTracker()
        _ = tracker.evaluate(absolute: 20, mode: .button, upNextVisible: false, undoVisible: false)
        #expect(tracker.evaluate(absolute: 90, mode: .button, upNextVisible: false, undoVisible: false) == .hideSkip)
        #expect(tracker.evaluate(absolute: 91, mode: .button, upNextVisible: false, undoVisible: false) == .none)
    }

    @Test func offModeNeverOffersAnything() {
        var tracker = makeTracker()
        #expect(tracker.evaluate(absolute: 20, mode: .off, upNextVisible: false, undoVisible: false) == .none)
    }

    @Test func switchingToOffHidesAControlThatWasShown() {
        var tracker = makeTracker()
        _ = tracker.evaluate(absolute: 20, mode: .button, upNextVisible: false, undoVisible: false)
        #expect(tracker.evaluate(absolute: 21, mode: .off, upNextVisible: false, undoVisible: false) == .hideSkip)
    }

    @Test func automaticModeSkipsAnIntroOncePerMarkerStart() {
        var tracker = makeTracker()
        #expect(tracker.evaluate(absolute: 13, mode: .automatic, upNextVisible: false, undoVisible: false) == .autoSkip(introMarker()))
        #expect(tracker.evaluate(absolute: 14, mode: .automatic, upNextVisible: false, undoVisible: false) == .showSkip(introMarker(), progress: 2.0 / 46.0))
    }

    @Test func automaticModeNeverSkipsCredits() {
        var tracker = makeTracker()
        let action = tracker.evaluate(absolute: 2_010, mode: .automatic, upNextVisible: false, undoVisible: false)
        #expect(action == .showSkip(SkipMarker(kind: .credits, startSecs: 2_000, endSecs: 2_100), progress: 0.1))
    }

    @Test func theUndoConfirmationSuppressesTheControlButNotTheSkipItself() {
        var tracker = makeTracker()
        #expect(tracker.evaluate(absolute: 13, mode: .automatic, upNextVisible: false, undoVisible: true) == .autoSkip(introMarker()))
        #expect(tracker.evaluate(absolute: 14, mode: .automatic, upNextVisible: false, undoVisible: true) == .none)
        #expect(tracker.evaluate(absolute: 15, mode: .automatic, upNextVisible: false, undoVisible: false) != .none)
    }

    @Test func theUndoConfirmationHidesAControlAlreadyShown() {
        var tracker = makeTracker()
        _ = tracker.evaluate(absolute: 20, mode: .button, upNextVisible: false, undoVisible: false)
        #expect(tracker.evaluate(absolute: 21, mode: .button, upNextVisible: false, undoVisible: true) == .hideSkip)
    }

    @Test func theUpNextCardHidesTheControlAndHoldsBackAutomaticSkips() {
        var tracker = makeTracker()
        _ = tracker.evaluate(absolute: 12, mode: .button, upNextVisible: false, undoVisible: false)
        #expect(tracker.evaluate(absolute: 13, mode: .automatic, upNextVisible: true, undoVisible: false) == .hideSkip)
        #expect(tracker.evaluate(absolute: 14, mode: .automatic, upNextVisible: true, undoVisible: false) == .none)
        #expect(tracker.evaluate(absolute: 15, mode: .automatic, upNextVisible: false, undoVisible: false) == .autoSkip(introMarker()))
    }

    @Test func aSeekBackIntoAnAlreadySkippedIntroOnlyOffersTheControl() {
        var tracker = makeTracker()
        _ = tracker.evaluate(absolute: 13, mode: .automatic, upNextVisible: false, undoVisible: false)
        _ = tracker.evaluate(absolute: 60, mode: .automatic, upNextVisible: false, undoVisible: false)
        let action = tracker.evaluate(absolute: 13, mode: .automatic, upNextVisible: false, undoVisible: false)
        #expect(action == .showSkip(introMarker(), progress: 1.0 / 46.0))
    }

    @Test func unknownMarkerTypesBehaveLikeIntros() {
        var tracker = makeTracker([PlexMarker(type: "commercial", startTimeOffset: 10_000, endTimeOffset: 40_000, final: nil)])
        let action = tracker.evaluate(absolute: 10, mode: .button, upNextVisible: false, undoVisible: false)
        #expect(action == .showSkip(SkipMarker(kind: .intro, startSecs: 10, endSecs: 40), progress: 0))
    }

    @Test func titlesNameTheKindOfMarker() {
        #expect(SkipMarker(kind: .intro, startSecs: 0, endSecs: 10).title == "Skip Intro")
        #expect(SkipMarker(kind: .credits, startSecs: 0, endSecs: 10).title == "Skip Credits")
    }

    @Test func emptyAndDegenerateMarkersNeverActivate() {
        var empty = makeTracker([])
        #expect(empty.evaluate(absolute: 5, mode: .button, upNextVisible: false, undoVisible: false) == .none)
        var collapsed = makeTracker([PlexMarker(type: "intro", startTimeOffset: 10_000, endTimeOffset: 10_500, final: nil)])
        #expect(collapsed.evaluate(absolute: 10, mode: .button, upNextVisible: false, undoVisible: false) == .none)
        #expect(SkipMarker(kind: .intro, startSecs: 5, endSecs: 5).progress(at: 5) == 0)
    }
}

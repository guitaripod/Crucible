import Foundation
import Testing
@testable import CrucibleCore

struct PlaybackContinuityTests {
    private let start = ContinuousClock.now

    @Test func aSteadyHeartbeatIsNoAbsence() {
        var detector = AwayDetector()
        #expect(detector.beat(at: start) == nil)
        #expect(detector.beat(at: start.advanced(by: .seconds(1))) == nil)
        #expect(detector.beat(at: start.advanced(by: .seconds(15))) == nil)
    }

    @Test func aLongGapBetweenBeatsIsAnAbsenceOfThatLength() {
        var detector = AwayDetector()
        _ = detector.beat(at: start)
        #expect(detector.beat(at: start.advanced(by: .seconds(7 * 3600))) == .seconds(7 * 3600))
        #expect(detector.beat(at: start.advanced(by: .seconds(7 * 3600 + 1))) == nil)
    }

    @Test func aResetForgetsTheGapAlreadyDealtWith() {
        var detector = AwayDetector()
        _ = detector.beat(at: start)
        detector.reset(at: start.advanced(by: .seconds(600)))
        #expect(detector.beat(at: start.advanced(by: .seconds(601))) == nil)
    }

    @Test func theRewindGrowsWithTheBreakUpToFifteenSeconds() {
        #expect(BreakRule.rewind(after: .seconds(30)) == 0)
        #expect(BreakRule.rewind(after: .seconds(299)) == 0)
        #expect(BreakRule.rewind(after: .seconds(300)) == 5)
        #expect(BreakRule.rewind(after: .seconds(45 * 60)) == 10)
        #expect(BreakRule.rewind(after: .seconds(7 * 3600)) == 15)
    }

    @Test func aLongAbsenceComesBackPausedAndAShortOnePlaysOn() {
        #expect(BreakRule.resumesPlaying(wasPlaying: true, away: .seconds(20)))
        #expect(!BreakRule.resumesPlaying(wasPlaying: true, away: .seconds(6 * 60)))
        #expect(!BreakRule.resumesPlaying(wasPlaying: false, away: .seconds(20)))
    }

    @Test func theRewindNeverGoesBeforeTheStartOrBackIntoASkippedIntro() {
        let intro = SkipMarker(kind: .intro, startSecs: 60, endSecs: 120)
        #expect(BreakRule.target(snapshot: 8, rewind: 15, markers: []) == 0)
        #expect(BreakRule.target(snapshot: 923, rewind: 15, markers: [intro]) == 908)
        #expect(BreakRule.target(snapshot: 130, rewind: 15, markers: [intro]) == 120)
        #expect(BreakRule.target(snapshot: 100, rewind: 15, markers: [intro]) == 85)
        #expect(BreakRule.target(snapshot: 923.4, rewind: 0, markers: [intro]) == 923.4)
    }

    @Test func theCreditsDoNotCountAsAnIntroToStayOutOf() {
        let credits = SkipMarker(kind: .credits, startSecs: 1_268, endSecs: 1_320)
        #expect(BreakRule.target(snapshot: 1_330, rewind: 15, markers: [credits]) == 1_315)
    }

    @Test func aSessionNobodyHeardFromInTheReapWindowMayBeGone() {
        var liveness = TranscodeLiveness(confirmedAt: start)
        #expect(!liveness.mayBeGone(at: start.advanced(by: .seconds(30))))
        #expect(liveness.mayBeGone(at: start.advanced(by: .seconds(46))))
        liveness.confirm(at: start.advanced(by: .seconds(40)))
        #expect(!liveness.mayBeGone(at: start.advanced(by: .seconds(60))))
    }

    @Test func aSessionTheServerDisownedIsGoneUntilItAnswersAgain() {
        var liveness = TranscodeLiveness(confirmedAt: start)
        liveness.markGone()
        #expect(liveness.mayBeGone(at: start))
        liveness.pinged(at: start)
        #expect(liveness.mayBeGone(at: start), "a ping answer does not bring back a stream a segment found gone")
        liveness.confirm(at: start)
        #expect(!liveness.mayBeGone(at: start))
        #expect(TranscodeLiveness.isGoneStatus(404))
        #expect(TranscodeLiveness.isGoneStatus(410))
        #expect(!TranscodeLiveness.isGoneStatus(500))
    }

    @Test func anEndMidEpisodeIsNotTheEnd() {
        #expect(!ItemEndRule.isGenuineEnd(absolute: 345, duration: 1_330, creditsStart: 1_268))
        #expect(!ItemEndRule.isGenuineEnd(absolute: 923, duration: 1_330, creditsStart: nil))
    }

    @Test func anEndAtTheCreditsOrTheLastSecondsIsTheEnd() {
        #expect(ItemEndRule.isGenuineEnd(absolute: 1_267, duration: 1_330, creditsStart: 1_268))
        #expect(ItemEndRule.isGenuineEnd(absolute: 1_305, duration: 1_330, creditsStart: nil))
        #expect(ItemEndRule.isGenuineEnd(absolute: 7_000, duration: 7_200, creditsStart: nil))
        #expect(!ItemEndRule.isGenuineEnd(absolute: 6_900, duration: 7_200, creditsStart: nil))
        #expect(ItemEndRule.isGenuineEnd(absolute: 10, duration: 0, creditsStart: nil))
    }

    @Test func stillWatchingAsksOnlyOnceTheRunReachesTheLimit() {
        #expect(!StillWatchingRule.asks(unattended: 2, limit: 3))
        #expect(StillWatchingRule.asks(unattended: 3, limit: 3))
        #expect(!StillWatchingRule.asks(unattended: 9, limit: 0))
        #expect(StillWatchingRule.label(for: 0) == "Off")
        #expect(StillWatchingRule.label(for: 5) == "After 5 Episodes")
    }

    @Test func theStillWatchingSettingOnlyTakesTheOfferedChoices() {
        let saved = UserDefaults.standard.object(forKey: "stillWatchingAfterEpisodes")
        defer { UserDefaults.standard.set(saved, forKey: "stillWatchingAfterEpisodes") }
        UserDefaults.standard.removeObject(forKey: "stillWatchingAfterEpisodes")
        #expect(Preferences.stillWatchingAfter == 3)
        Preferences.stillWatchingAfter = 0
        #expect(Preferences.stillWatchingAfter == 0)
        Preferences.stillWatchingAfter = 4
        #expect(Preferences.stillWatchingAfter == 3)
    }

    @Test func healingIsSpacedOutAndGivesUpAfterAHandful() {
        var budget = HealBudget()
        #expect(budget.ask(at: start) == .heal)
        #expect(budget.ask(at: start.advanced(by: .seconds(3))) == .wait)
        #expect(budget.ask(at: start.advanced(by: .seconds(11))) == .heal)
        #expect(budget.ask(at: start.advanced(by: .seconds(22))) == .heal)
        #expect(budget.ask(at: start.advanced(by: .seconds(33))) == .heal)
        #expect(budget.ask(at: start.advanced(by: .seconds(44))) == .giveUp)
        #expect(budget.ask(at: start.advanced(by: .seconds(400))) == .heal)
    }

    @Test func aTranscodeStartsOnTheWholeSecondTheServerUses() {
        #expect(StreamPosition.transcodeStart(1_251.31) == 1_251)
        #expect(StreamPosition.transcodeStart(-3) == 0)
        #expect(ResumeStrategy.streamOffset(resumePosition: 893.519, isDirectPlay: false) == 893)
        #expect(ResumeStrategy.streamOffset(resumePosition: 893.519, isDirectPlay: true) == 0)
    }

    @Test func theStillWatchingCardWordsChange() {
        #expect(UpNextText.eyebrow(asksStillWatching: true) == "STILL WATCHING?")
        #expect(UpNextText.playTitle(asksStillWatching: false) == "Play Now")
        #expect(UpNextText.stillWatchingAnnouncement(code: "S01E04", title: "Ebb") == "Are you still watching? Up next: S01E04 Ebb")
    }

    @Test func whileTheStreamIsRebuiltTheOldClockIsNeitherReadNorKept() {
        var keeper = PlayheadKeeper()
        keeper.observe(absolute: 45, isReady: true)
        keeper.beginRebuild(at: 29)
        keeper.observe(absolute: 44, isReady: true)
        #expect(keeper.position(observed: 44, isReady: true) == 29)
        keeper.endRebuild()
        #expect(keeper.position(observed: 31, isReady: true) == 31)
    }
}

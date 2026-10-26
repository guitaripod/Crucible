import Foundation
import Testing
@testable import CrucibleCore

struct RemoteControlsTests {
    @Test func onlyTheSystemsTenSecondSkipCountsAsAClick() {
        #expect(SkipRule.click(from: 106, to: 96) == .back)
        #expect(SkipRule.click(from: 31, to: 41.2) == .forward)
        #expect(SkipRule.click(from: 100, to: 70) == nil)
        #expect(SkipRule.click(from: 100, to: 103) == nil)
    }

    @Test func aClickLandsTheChosenDistanceAwayInsideTheItem() {
        #expect(SkipRule.target(from: 106, direction: .back, seconds: 30, duration: 2_700) == 76)
        #expect(SkipRule.target(from: 12, direction: .back, seconds: 30, duration: 2_700) == 0)
        #expect(SkipRule.target(from: 2_690, direction: .forward, seconds: 30, duration: 2_700) == 2_699)
        #expect(SkipRule.target(from: 50, direction: .forward, seconds: 45, duration: 0) == 95)
    }

    @Test func skipDistancesReadAsSecondsOrMinutes() {
        #expect(SkipRule.label(for: 10) == "10 Seconds")
        #expect(SkipRule.label(for: 60) == "1 Minute")
    }

    @Test func holdActionsNameTheirSide() {
        #expect(HoldAction.scan.title(forward: false) == "Rewind")
        #expect(HoldAction.scan.title(forward: true) == "Fast Forward")
        #expect(HoldAction.jumpTwoMinutes.title(forward: true) == "Jump Ahead 2 Minutes")
        #expect(HoldAction.jumpOneMinute.title(forward: false) == "Jump Back 1 Minute")
        #expect(HoldAction.edge.title(forward: false) == "Start Over")
        #expect(HoldAction.edge.title(forward: true) == "Next Episode")
        #expect(HoldAction.edge.jumpSeconds == nil)
        #expect(HoldAction.jumpFiveMinutes.jumpSeconds == 300)
    }

    @Test func aTranscodeRestartsOnlyForAJumpAheadOfWhatIsLoaded() {
        let loaded = [0.0...42.0]
        #expect(!TranscodeSeekPolicy.needsRestart(from: 30, to: 20, loaded: loaded))
        #expect(!TranscodeSeekPolicy.needsRestart(from: 30, to: 40, loaded: loaded))
        #expect(TranscodeSeekPolicy.needsRestart(from: 30, to: 75, loaded: loaded))
        #expect(TranscodeSeekPolicy.needsRestart(from: 30, to: 75, loaded: []))
    }

    @Test func skipAndHoldSettingsKeepToTheirChoices() {
        let keys = ["skipBackSeconds", "skipForwardSeconds", "holdLeftAction", "holdRightAction"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        #expect(Preferences.skipBackSeconds == 10)
        #expect(Preferences.holdRightAction == .scan)
        Preferences.skipForwardSeconds = 45
        #expect(Preferences.skipForwardSeconds == 45)
        Preferences.skipBackSeconds = 7
        #expect(Preferences.skipBackSeconds == 10)
        PreferenceSetting.holdLeft.select(SettingChoice(id: HoldAction.edge.rawValue, title: "Start Over", isSelected: false))
        #expect(Preferences.holdLeftAction == .edge)
        #expect(PreferenceSetting.holdLeft.valueLabel == "Start Over")
        #expect(PreferenceSetting.skipForward.valueLabel == "45 Seconds")
        #expect(PreferenceSetting.skipBack.choices.map(\.id) == SkipRule.choices)
    }
}

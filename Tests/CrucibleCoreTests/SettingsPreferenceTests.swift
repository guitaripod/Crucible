import Foundation
import Testing
@testable import CrucibleCore

@Suite(.serialized)
struct SettingsPreferenceTests {
    private static let keys = [
        "skipIntroMode", "autoplayNextEpisode", "rewindAfterBreak", "stillWatchingAfterEpisodes",
        "preferLocalConnection", "allowRelayConnection",
    ]

    private func isolated(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = Self.keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in previous {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for key in Self.keys { defaults.removeObject(forKey: key) }
        try body()
    }

    @Test func titlesMatchTheRowsOnTheIPhone() {
        #expect(PreferenceSetting.allCases.map(\.title) == [
            "Streaming Quality", "Skip Intro", "Autoplay Next Episode", "Rewind After a Break", "Ask If Still Watching",
            "Prefer Local Connection", "Allow Relay",
        ])
    }

    @Test func streamingQualityOffersEveryQualityInOrderWithOneSelected() {
        let choices = PreferenceSetting.streamingQuality.choices
        #expect(choices.map(\.title) == ["Original", "High · 20 Mbps", "Medium · 8 Mbps", "Low · 3 Mbps"])
        #expect(choices.map(\.id) == [0, 20000, 8000, 3000])
        #expect(choices.filter(\.isSelected).count == 1)
    }

    @Test func skipIntroDefaultsToTheButton() {
        isolated {
            let setting = PreferenceSetting.skipIntro
            #expect(setting.valueLabel == "Show Button")
            #expect(setting.choices.map(\.title) == ["Show Button", "Skip Automatically", "Off"])
            #expect(setting.choices.first(where: \.isSelected)?.id == 0)
        }
    }

    @Test func selectingAChoiceWritesThePreference() throws {
        try isolated {
            let setting = PreferenceSetting.skipIntro
            let automatic = try #require(setting.choices.first { $0.title == "Skip Automatically" })
            setting.select(automatic)
            #expect(Preferences.skipIntroMode == .automatic)
            #expect(setting.valueLabel == "Skip Automatically")
            #expect(setting.choices.first(where: \.isSelected)?.id == automatic.id)
        }
    }

    @Test func selectingAnUnknownChoiceChangesNothing() {
        isolated {
            PreferenceSetting.skipIntro.select(SettingChoice(id: 99, title: "Bogus", isSelected: false))
            #expect(Preferences.skipIntroMode == .button)
        }
    }

    @Test func togglesStartAtTheirDefaults() {
        isolated {
            #expect(PreferenceSetting.autoplayNextEpisode.isOn)
            #expect(PreferenceSetting.preferLocalConnection.isOn)
            #expect(!PreferenceSetting.allowRelayConnection.isOn)
            #expect(PreferenceSetting.allowRelayConnection.valueLabel == "Off")
            #expect(PreferenceSetting.autoplayNextEpisode.valueLabel == "On")
        }
    }

    @Test func flippingATogglePersistsIt() {
        isolated {
            PreferenceSetting.autoplayNextEpisode.setOn(false)
            PreferenceSetting.preferLocalConnection.setOn(false)
            PreferenceSetting.allowRelayConnection.setOn(true)
            #expect(!Preferences.autoplayNextEpisode)
            #expect(!Preferences.preferLocalConnection)
            #expect(Preferences.allowRelayConnection)
            #expect(PreferenceSetting.allowRelayConnection.control == .toggle(isOn: true))
        }
    }

    @Test func choiceSettingsIgnoreTogglesAndTheOtherWayRound() {
        isolated {
            PreferenceSetting.skipIntro.setOn(true)
            PreferenceSetting.autoplayNextEpisode.select(SettingChoice(id: 1, title: "x", isSelected: false))
            #expect(Preferences.skipIntroMode == .button)
            #expect(Preferences.autoplayNextEpisode)
            #expect(PreferenceSetting.skipIntro.isOn == false)
            #expect(PreferenceSetting.autoplayNextEpisode.choices.isEmpty)
        }
    }

    @Test func rewindAfterBreakDefaultsOnAndPersistsWhenFlipped() {
        isolated {
            #expect(PreferenceSetting.rewindAfterBreak.isOn)
            #expect(PreferenceSetting.rewindAfterBreak.valueLabel == "On")
            PreferenceSetting.rewindAfterBreak.setOn(false)
            #expect(!Preferences.rewindAfterBreak)
            #expect(PreferenceSetting.rewindAfterBreak.control == .toggle(isOn: false))
            PreferenceSetting.rewindAfterBreak.setOn(true)
            #expect(Preferences.rewindAfterBreak)
        }
    }

    @Test func stillWatchingOffersEveryLimitWithTheDefaultSelected() {
        isolated {
            let setting = PreferenceSetting.stillWatching
            #expect(setting.choices.map(\.title) == ["Off", "After 2 Episodes", "After 3 Episodes", "After 5 Episodes"])
            #expect(setting.choices.map(\.id) == [0, 2, 3, 5])
            #expect(setting.choices.filter(\.isSelected).map(\.id) == [3])
            #expect(setting.valueLabel == "After 3 Episodes")
        }
    }

    @Test func selectingAStillWatchingLimitWritesThePreference() throws {
        try isolated {
            let setting = PreferenceSetting.stillWatching
            let off = try #require(setting.choices.first { $0.title == "Off" })
            setting.select(off)
            #expect(Preferences.stillWatchingAfter == 0)
            #expect(setting.valueLabel == "Off")
            #expect(setting.choices.first(where: \.isSelected)?.id == 0)
        }
    }

    @Test func selectingAnUnlistedStillWatchingLimitChangesNothing() {
        isolated {
            PreferenceSetting.stillWatching.select(SettingChoice(id: 4, title: "Bogus", isSelected: false))
            #expect(Preferences.stillWatchingAfter == StillWatchingRule.defaultLimit)
        }
    }

    @Test func onlyTheSettingsWithCopyExplainThemselves() {
        #expect(PreferenceSetting.allCases.filter { $0.explanation != nil } == [.skipIntro, .rewindAfterBreak, .stillWatching])
    }
}

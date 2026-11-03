import Foundation
import Testing
@testable import CrucibleCore

@Suite(.serialized)
@MainActor
struct SettingsPreferenceTests {
    private static let keys = [
        "skipIntroMode", "skipOutroMode", "autoplayNextEpisode", "rewindAfterBreak", "stillWatchingAfterEpisodes",
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

    @Test func everySettingHasATitleASymbolAndCopy() {
        for setting in PreferenceSetting.allCases {
            #expect(!setting.title.isEmpty)
            #expect(!setting.symbol.isEmpty)
        }
        #expect(PreferenceSetting.streamingQuality.title == "Quality at Home")
        #expect(PreferenceSetting.skipOutro.title == "Skip Credits")
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

    @Test func skipOutroDefaultsToTheButton() {
        isolated {
            let setting = PreferenceSetting.skipOutro
            #expect(setting.valueLabel == "Show Button")
            #expect(setting.choices.map(\.title) == ["Show Button", "Skip Automatically", "Off"])
            #expect(setting.choices.first(where: \.isSelected)?.id == 0)
        }
    }

    @Test func selectingASkipOutroChoiceWritesThePreference() throws {
        try isolated {
            let setting = PreferenceSetting.skipOutro
            let automatic = try #require(setting.choices.first { $0.title == "Skip Automatically" })
            setting.select(automatic)
            #expect(Preferences.skipOutroMode == .automatic)
            #expect(setting.valueLabel == "Skip Automatically")
            PreferenceSetting.skipOutro.select(SettingChoice(id: 99, title: "Bogus", isSelected: false))
            #expect(Preferences.skipOutroMode == .automatic)
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

    @Test func everySettingExplainsItself() {
        #expect(PreferenceSetting.allCases.allSatisfy { $0.explanation?.isEmpty == false })
    }
}

@Suite(.serialized)
@MainActor
struct SettingsCatalogTests {
    private static let keys = [
        "streamingQuality", "streamingQuality.remote", "streamingQuality.cellular", "subtitles.size", "upNext.countdown",
        "notify.ratingReminders", "autoplayNextEpisode",
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

    @Test func eachPlatformGetsItsOwnCategoriesAndEveryEntryOnce() {
        let phone = SettingsCatalog.entries(on: .phone)
        let tv = SettingsCatalog.entries(on: .tv)
        #expect(Set(phone.map(\.id)).count == phone.count)
        #expect(Set(tv.map(\.id)).count == tv.count)
        #expect(SettingsCatalog.categories(on: .phone).contains(.notifications))
        #expect(!SettingsCatalog.categories(on: .tv).contains(.notifications))
        #expect(!SettingsCatalog.categories(on: .tv).contains(.downloads))
        #expect(tv.contains { $0.item == .preference(.holdLeft) })
        #expect(!phone.contains { $0.item == .preference(.holdLeft) })
        #expect(!tv.contains { $0.item == .preference(.cellularQuality) })
    }

    @Test func sectionsKeepTheirOrderAndGroupTheirRows() {
        let sections = SettingsCatalog.sections(of: .playback, on: .phone)
        #expect(sections.map(\.title) == ["Streaming Quality", "Up Next", "Skipping", "Subtitles"])
        #expect(sections.first?.entries.map(\.item) == [.preference(.streamingQuality), .preference(.remoteQuality), .preference(.cellularQuality)])
    }

    @Test func searchFindsSettingsByTitleKeywordAndExplanationBestFirst() {
        #expect(SettingsCatalog.search("subtitle", on: .phone).first?.item == .preference(.subtitleSize))
        #expect(SettingsCatalog.search("captions", on: .phone).first?.item == .preference(.subtitleSize))
        #expect(SettingsCatalog.search("dark", on: .phone).first?.item == .preference(.appearance))
        #expect(SettingsCatalog.search("4k", on: .tv).contains { $0.item == .preference(.streamingQuality) })
        #expect(SettingsCatalog.search("cellular quality", on: .phone).first?.item == .preference(.cellularQuality))
        #expect(SettingsCatalog.search("dark", on: .tv).isEmpty)
        #expect(SettingsCatalog.search("   ", on: .phone).isEmpty)
        #expect(SettingsCatalog.search("zzzz", on: .phone).isEmpty)
        #expect(SettingsCatalog.search("intrö", on: .phone).first?.item == .preference(.skipIntro))
    }

    @Test func awayAndCellularQualityFollowTheOnesAboveUntilSet() throws {
        try isolated {
            Preferences.streamingQuality = .medium
            #expect(QualityPolicy.quality(route: .local, isCellular: false) == .medium)
            #expect(QualityPolicy.quality(route: .remote, isCellular: false) == .medium)
            #expect(QualityPolicy.quality(route: .local, isCellular: true) == .medium)
            let away = try #require(PreferenceSetting.remoteQuality.choices.first { $0.id == Preferences.Quality.low.rawValue })
            PreferenceSetting.remoteQuality.select(away)
            #expect(QualityPolicy.quality(route: .relay, isCellular: false) == .low)
            #expect(QualityPolicy.quality(route: .local, isCellular: true) == .low)
            #expect(QualityPolicy.quality(route: .local, isCellular: false) == .medium)
            #expect(PreferenceSetting.remoteQuality.isChanged)
            PreferenceSetting.remoteQuality.restoreDefault()
            #expect(Preferences.remoteQuality == nil)
            #expect(PreferenceSetting.remoteQuality.valueLabel == "Same as at Home")
        }
    }

    @Test func choicesWriteThroughAndAnnounceTheChange() throws {
        try isolated {
            var changed = [PreferenceSetting]()
            PreferenceSetting.didChange = { changed.append($0) }
            defer { PreferenceSetting.didChange = nil }
            let fifteen = try #require(PreferenceSetting.upNextCountdown.choices.first { $0.id == 15 })
            PreferenceSetting.upNextCountdown.select(fifteen)
            #expect(UpNextOffer.countdownSeconds == 15)
            PreferenceSetting.subtitleSize.select(SettingChoice(id: SubtitleSize.large.rawValue, title: "", isSelected: false))
            #expect(Preferences.subtitleSize == .large)
            PreferenceSetting.notifyRatingReminders.setOn(false)
            #expect(!Preferences.notifies(.ratingReminders))
            PreferenceSetting.upNextCountdown.select(SettingChoice(id: 7, title: "", isSelected: false))
            #expect(Preferences.upNextCountdown == 15)
            #expect(changed == [.upNextCountdown, .subtitleSize, .notifyRatingReminders])
        }
    }

    @Test func restoringDefaultsResetsEveryChangedSettingOfACategory() throws {
        try isolated {
            PreferenceSetting.autoplayNextEpisode.setOn(false)
            PreferenceSetting.subtitleSize.select(SettingChoice(id: SubtitleSize.small.rawValue, title: "", isSelected: false))
            for setting in SettingsCatalog.preferences(in: .playback, on: .phone) where setting.isChanged {
                setting.restoreDefault()
            }
            #expect(Preferences.autoplayNextEpisode)
            #expect(Preferences.subtitleSize == .standard)
            #expect(!SettingsCatalog.preferences(in: .playback, on: .phone).contains { $0.isChanged })
        }
    }
}

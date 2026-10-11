import Foundation

/// One selectable value of a choice setting.
package struct SettingChoice: Hashable, Identifiable, Sendable {
    package let id: Int
    package let title: String
    package let isSelected: Bool
}

/// The playback and connection preferences that both the iPhone and Apple TV settings screens offer.
/// Reads and writes go straight to `Preferences`, so a screen only renders `control` and calls
/// `select` or `setOn`.
package enum PreferenceSetting: CaseIterable, Sendable {
    case streamingQuality
    case skipIntro
    case autoplayNextEpisode
    case preferLocalConnection
    case allowRelayConnection

    package enum Control: Equatable, Sendable {
        case choice([SettingChoice])
        case toggle(isOn: Bool)
    }

    package var title: String {
        switch self {
        case .streamingQuality: return "Streaming Quality"
        case .skipIntro: return "Skip Intro"
        case .autoplayNextEpisode: return "Autoplay Next Episode"
        case .preferLocalConnection: return "Prefer Local Connection"
        case .allowRelayConnection: return "Allow Relay"
        }
    }

    package var explanation: String? {
        switch self {
        case .skipIntro: return "Skip Intro can show a button, skip automatically, or stay out of the way."
        default: return nil
        }
    }

    package var control: Control {
        switch self {
        case .streamingQuality:
            return .choice(Self.choices(Preferences.Quality.allCases, current: Preferences.streamingQuality, rawValue: \.rawValue, title: \.title))
        case .skipIntro:
            return .choice(Self.choices(Preferences.SkipIntroMode.allCases, current: Preferences.skipIntroMode, rawValue: \.rawValue, title: \.title))
        case .autoplayNextEpisode:
            return .toggle(isOn: Preferences.autoplayNextEpisode)
        case .preferLocalConnection:
            return .toggle(isOn: Preferences.preferLocalConnection)
        case .allowRelayConnection:
            return .toggle(isOn: Preferences.allowRelayConnection)
        }
    }

    package var choices: [SettingChoice] {
        if case .choice(let choices) = control { return choices }
        return []
    }

    package var isOn: Bool {
        if case .toggle(let isOn) = control { return isOn }
        return false
    }

    /// The text a value row shows: the selected choice, or On / Off for a toggle.
    package var valueLabel: String {
        switch control {
        case .choice(let choices): return choices.first(where: \.isSelected)?.title ?? ""
        case .toggle(let isOn): return isOn ? "On" : "Off"
        }
    }

    package func select(_ choice: SettingChoice) {
        switch self {
        case .streamingQuality:
            if let quality = Preferences.Quality(rawValue: choice.id) { Preferences.streamingQuality = quality }
        case .skipIntro:
            if let mode = Preferences.SkipIntroMode(rawValue: choice.id) { Preferences.skipIntroMode = mode }
        default:
            break
        }
    }

    package func setOn(_ isOn: Bool) {
        switch self {
        case .autoplayNextEpisode: Preferences.autoplayNextEpisode = isOn
        case .preferLocalConnection: Preferences.preferLocalConnection = isOn
        case .allowRelayConnection: Preferences.allowRelayConnection = isOn
        default: break
        }
    }

    private static func choices<Value: Equatable>(
        _ values: [Value],
        current: Value,
        rawValue: KeyPath<Value, Int>,
        title: KeyPath<Value, String>
    ) -> [SettingChoice] {
        values.map { SettingChoice(id: $0[keyPath: rawValue], title: $0[keyPath: title], isSelected: $0 == current) }
    }
}

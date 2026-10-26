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
    case skipOutro
    case autoplayNextEpisode
    case rewindAfterBreak
    case stillWatching
    case skipBack
    case skipForward
    case holdLeft
    case holdRight
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
        case .skipOutro: return "Skip Outro"
        case .autoplayNextEpisode: return "Autoplay Next Episode"
        case .rewindAfterBreak: return "Rewind After a Break"
        case .stillWatching: return "Ask If Still Watching"
        case .skipBack: return "Skip Back"
        case .skipForward: return "Skip Ahead"
        case .holdLeft: return "Hold Left"
        case .holdRight: return "Hold Right"
        case .preferLocalConnection: return "Prefer Local Connection"
        case .allowRelayConnection: return "Allow Relay"
        }
    }

    package var explanation: String? {
        switch self {
        case .skipIntro: return "Skip Intro can show a button, skip automatically, or stay out of the way."
        case .skipOutro: return "Skip Outro decides what the credits do: show the Up Next card, start the next episode automatically, or stay out of the way."
        case .rewindAfterBreak: return "After a break, playback backs up a few seconds, more the longer you were away."
        case .stillWatching: return "Asks before the next episode once this many have played in a row without the remote."
        case .skipBack, .skipForward: return "How far one skip goes: a click on the left or right of the Siri Remote's clickpad, or the skip buttons on the Lock Screen, in Control Center and on headphones."
        case .holdLeft, .holdRight: return "What holding the left or right of the clickpad does: the system's rewind and fast forward, a jump, or Start Over and Next Episode."
        default: return nil
        }
    }

    package var control: Control {
        switch self {
        case .streamingQuality:
            return .choice(Self.choices(Preferences.Quality.allCases, current: Preferences.streamingQuality, rawValue: \.rawValue, title: \.title))
        case .skipIntro:
            return .choice(Self.choices(Preferences.SkipIntroMode.allCases, current: Preferences.skipIntroMode, rawValue: \.rawValue, title: \.title))
        case .skipOutro:
            return .choice(Self.choices(Preferences.SkipOutroMode.allCases, current: Preferences.skipOutroMode, rawValue: \.rawValue, title: \.title))
        case .autoplayNextEpisode:
            return .toggle(isOn: Preferences.autoplayNextEpisode)
        case .rewindAfterBreak:
            return .toggle(isOn: Preferences.rewindAfterBreak)
        case .stillWatching:
            return .choice(StillWatchingRule.choices.map { limit in
                SettingChoice(id: limit, title: StillWatchingRule.label(for: limit), isSelected: limit == Preferences.stillWatchingAfter)
            })
        case .skipBack:
            return .choice(Self.skipChoices(current: Preferences.skipBackSeconds))
        case .skipForward:
            return .choice(Self.skipChoices(current: Preferences.skipForwardSeconds))
        case .holdLeft:
            return .choice(Self.holdChoices(current: Preferences.holdLeftAction, forward: false))
        case .holdRight:
            return .choice(Self.holdChoices(current: Preferences.holdRightAction, forward: true))
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
        case .skipOutro:
            if let mode = Preferences.SkipOutroMode(rawValue: choice.id) { Preferences.skipOutroMode = mode }
        case .stillWatching:
            if StillWatchingRule.choices.contains(choice.id) { Preferences.stillWatchingAfter = choice.id }
        case .skipBack:
            if SkipRule.choices.contains(choice.id) { Preferences.skipBackSeconds = choice.id }
        case .skipForward:
            if SkipRule.choices.contains(choice.id) { Preferences.skipForwardSeconds = choice.id }
        case .holdLeft:
            if let action = HoldAction(rawValue: choice.id) { Preferences.holdLeftAction = action }
        case .holdRight:
            if let action = HoldAction(rawValue: choice.id) { Preferences.holdRightAction = action }
        default:
            break
        }
    }

    package func setOn(_ isOn: Bool) {
        switch self {
        case .autoplayNextEpisode: Preferences.autoplayNextEpisode = isOn
        case .rewindAfterBreak: Preferences.rewindAfterBreak = isOn
        case .preferLocalConnection: Preferences.preferLocalConnection = isOn
        case .allowRelayConnection: Preferences.allowRelayConnection = isOn
        default: break
        }
    }

    private static func skipChoices(current: Int) -> [SettingChoice] {
        SkipRule.choices.map { SettingChoice(id: $0, title: SkipRule.label(for: $0), isSelected: $0 == current) }
    }

    private static func holdChoices(current: HoldAction, forward: Bool) -> [SettingChoice] {
        HoldAction.allCases.map { SettingChoice(id: $0.rawValue, title: $0.title(forward: forward), isSelected: $0 == current) }
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

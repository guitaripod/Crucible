import Foundation

/// The Up Next countdown a show keeps for itself on iPhone, iPad and Apple TV, over Settings' Up Next Countdown, keyed by
/// server and show like `ShowTrackMemory`. Linux keeps it in its title rules (`TitlePlaybackRules.upNextCountdown`).
package enum ShowUpNextCountdown {
    private static let storageKey = "showUpNextCountdown.v1"

    /// One choice of a show's countdown menu: nil seconds follows Settings.
    package struct Choice: Equatable, Sendable {
        package let seconds: Int?
        package let title: String
        package let isSelected: Bool
    }

    /// The show's own countdown, or nil while it follows Settings (or keeps one Settings no longer offers).
    package static func seconds(forShow showKey: String?, server: String?, defaults: UserDefaults = .standard) -> Int? {
        guard let key = key(showKey, server), let seconds = stored(defaults)[key] else { return nil }
        return Preferences.upNextCountdownChoices.contains(seconds) ? seconds : nil
    }

    /// How long the Up Next card counts down for the show: its own choice, or Settings'.
    package static func effective(forShow showKey: String?, server: String?, defaults: UserDefaults = .standard) -> Int {
        seconds(forShow: showKey, server: server, defaults: defaults) ?? UpNextOffer.countdownSeconds
    }

    /// Keeps `seconds` for the show; nil, or a length Settings does not offer, lets it follow Settings again.
    package static func set(_ seconds: Int?, forShow showKey: String?, server: String?, defaults: UserDefaults = .standard) {
        guard let key = key(showKey, server) else { return }
        var all = stored(defaults)
        all[key] = seconds.flatMap { Preferences.upNextCountdownChoices.contains($0) ? $0 : nil }
        defaults.set(all, forKey: storageKey)
    }

    /// Settings' own length first ("Default (10 Seconds)"), then Instant and each length.
    package static func choices(forShow showKey: String?, server: String?, defaults: UserDefaults = .standard) -> [Choice] {
        let current = seconds(forShow: showKey, server: server, defaults: defaults)
        let settings = PreferenceSetting.upNextCountdownTitle(UpNextOffer.countdownSeconds)
        let following = Choice(seconds: nil, title: String(localized: "Default (\(settings))", comment: "Choice that follows Settings, with what Settings say, e.g. Default (Show Button)"),
                               isSelected: current == nil)
        return [following] + Preferences.upNextCountdownChoices.map {
            Choice(seconds: $0, title: PreferenceSetting.upNextCountdownTitle($0), isSelected: current == $0)
        }
    }

    /// The menu's title with what the show does: "Up Next: Instant", or the setting's name while it follows Settings.
    package static func menuTitle(forShow showKey: String?, server: String?, defaults: UserDefaults = .standard) -> String {
        guard let seconds = seconds(forShow: showKey, server: server, defaults: defaults) else { return PreferenceSetting.upNextCountdown.title }
        return String(localized: "Up Next: \(PreferenceSetting.upNextCountdownTitle(seconds))", comment: "Show page menu: the show's own Up Next countdown, e.g. Up Next: Instant")
    }

    private static func key(_ showKey: String?, _ server: String?) -> String? {
        guard let showKey, !showKey.isEmpty else { return nil }
        return "\(server ?? "")|\(showKey)"
    }

    private static func stored(_ defaults: UserDefaults) -> [String: Int] {
        defaults.dictionary(forKey: storageKey) as? [String: Int] ?? [:]
    }
}

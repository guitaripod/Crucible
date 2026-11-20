import CrucibleCore
import Foundation

/// Settings › Playback › Skipping on Linux: what each kind of stretch does, kept per kind. A kind never set follows the
/// shared Skip Intro setting (Skip Credits for the credits), which decided every kind before they were separate.
@MainActor
enum SkipSettings {
    private static let key = "linux.skipModes"
    static let defaultMode = SkipMode.button

    static func mode(for kind: SkipKind, in defaults: UserDefaults = .standard) -> SkipMode {
        if let raw = (defaults.dictionary(forKey: key) as? [String: String])?[kind.rawValue], let mode = SkipMode(rawValue: raw), kind.modes.contains(mode) {
            return mode
        }
        return kind == .credits ? SkipMode(Preferences.skipOutroMode) : SkipMode(Preferences.skipIntroMode)
    }

    static func set(_ mode: SkipMode, for kind: SkipKind, in defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        all[kind.rawValue] = mode.rawValue
        defaults.set(all, forKey: key)
        TitleRulesStore.announce()
    }
}

/// The rules each show or movie keeps for itself (`TitlePlaybackRules`), keyed like `PlayerTweakStore.key(ratingKey:)` of
/// the show or movie, so a show's episodes share them. A title whose rules all went back to Settings is dropped. The
/// shows and movies Match Content was turned on for before it moved here are read in once.
@MainActor
enum TitleRulesStore {
    private static let key = "player.titleRules"
    private static let legacyMatchContentKey = "player.matchContentTitles"
    /// Posted after any title's rules or a Skipping setting changed, so an open player and Settings follow.
    static let didChange = Notification.Name("org.guitaripod.Crucible.titleRulesChanged")

    struct Entry {
        let key: String
        let rules: TitlePlaybackRules
        let changed: Date

        /// The server's rating key of the show or movie, the part of the key after the server.
        var ratingKey: String? { key.split(separator: "/").last.map(String.init) }
    }

    private struct Kept: Codable {
        var rules: TitlePlaybackRules
        var changed: Date
    }

    static func rules(for title: String, in defaults: UserDefaults = .standard) -> TitlePlaybackRules {
        kept(in: defaults)[title]?.rules ?? TitlePlaybackRules()
    }

    /// Changes `title`'s rules, taking its name and kind along when given so Settings can list it.
    static func update(_ title: String, name: String? = nil, isShow: Bool? = nil, in defaults: UserDefaults = .standard,
                       _ change: (inout TitlePlaybackRules) -> Void) {
        var all = kept(in: defaults)
        var rules = all[title]?.rules ?? TitlePlaybackRules()
        change(&rules)
        if let name, !name.isEmpty { rules.name = name }
        if let isShow { rules.isShow = isShow }
        all[title] = rules.hasRules ? Kept(rules: rules, changed: Date()) : nil
        save(all, in: defaults)
    }

    /// Fills in the name of a title kept without one (read in from before names were kept), without counting as a change.
    static func name(_ title: String, _ name: String, isShow: Bool, in defaults: UserDefaults = .standard) {
        var all = kept(in: defaults)
        guard var entry = all[title], entry.rules.name == nil else { return }
        entry.rules.name = name
        entry.rules.isShow = isShow
        all[title] = entry
        defaults.set(try? JSONEncoder().encode(all), forKey: key)
    }

    static func forget(_ title: String, in defaults: UserDefaults = .standard) {
        var all = kept(in: defaults)
        guard all.removeValue(forKey: title) != nil else { return }
        save(all, in: defaults)
    }

    /// Every title with rules of its own, the last changed first.
    static func all(in defaults: UserDefaults = .standard) -> [Entry] {
        kept(in: defaults).map { Entry(key: $0.key, rules: $0.value.rules, changed: $0.value.changed) }.sorted { $0.changed > $1.changed }
    }

    static func announce() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    private static func save(_ all: [String: Kept], in defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(all), forKey: key)
        announce()
    }

    private static func kept(in defaults: UserDefaults) -> [String: Kept] {
        var all = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Kept].self, from: $0) } ?? [:]
        guard let legacy = defaults.stringArray(forKey: legacyMatchContentKey) else { return all }
        for title in legacy {
            var rules = all[title]?.rules ?? TitlePlaybackRules()
            rules.matchContent = true
            all[title] = Kept(rules: rules, changed: all[title]?.changed ?? Date())
        }
        defaults.set(try? JSONEncoder().encode(all), forKey: key)
        defaults.removeObject(forKey: legacyMatchContentKey)
        return all
    }
}

/// What the mouse does over the playing picture in the Desktop layout, and how long the player's controls stay after the
/// pointer rests.
@MainActor
enum PlayerMouse {
    enum Click: String, CaseIterable {
        case playPause, showControls, nothing
    }

    enum DoubleClick: String, CaseIterable {
        case fullScreen, nothing
    }

    enum Wheel: String, CaseIterable {
        case seekFive, seekTen, volume, nothing

        /// How far one notch seeks, for the two that seek.
        var seconds: Double? {
            switch self {
            case .seekFive: 5
            case .seekTen: 10
            case .volume, .nothing: nil
            }
        }
    }

    enum MiddleClick: String, CaseIterable {
        case nothing, mute, playPause, fullScreen
    }

    private static let clickKey = "player.mouse.click"
    private static let doubleClickKey = "player.mouse.doubleClick"
    private static let wheelKey = "player.mouse.wheel"
    private static let middleKey = "player.mouse.middle"
    private static let restKey = "player.controlsRest"

    static var click: Click {
        get { UserDefaults.standard.string(forKey: clickKey).flatMap(Click.init) ?? .playPause }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: clickKey) }
    }

    static var doubleClick: DoubleClick {
        get { UserDefaults.standard.string(forKey: doubleClickKey).flatMap(DoubleClick.init) ?? .fullScreen }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: doubleClickKey) }
    }

    static var wheel: Wheel {
        get { UserDefaults.standard.string(forKey: wheelKey).flatMap(Wheel.init) ?? .seekFive }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: wheelKey) }
    }

    static var middleClick: MiddleClick {
        get { UserDefaults.standard.string(forKey: middleKey).flatMap(MiddleClick.init) ?? .nothing }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: middleKey) }
    }

    /// The rests the controls can be given, in seconds.
    static let rests: [Double] = [1.5, 2.5, 4, 6]

    /// How long the controls stay after the pointer rests over the picture: the viewer's choice, or the layout's own
    /// (quicker at a desk than across the room).
    static var rest: Double {
        get { (UserDefaults.standard.object(forKey: restKey) as? Double).flatMap { rests.contains($0) ? $0 : nil } ?? defaultRest }
        set { UserDefaults.standard.set(newValue, forKey: restKey) }
    }

    static var defaultRest: Double { LinuxDisplay.isCouch ? 2.5 : 1.5 }
}

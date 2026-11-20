import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// A setting only the Linux client has, shown among the shared catalogue's (`SettingsCatalog`): Skipping per kind of
/// stretch, the player's taste in subtitles and sound that its menus also change, what the mouse does over the picture
/// and how long the controls stay, and the window's appearance. Each reads and writes where the player keeps it, so a
/// change here and one in the player's menu are the same change.
@MainActor
enum LinuxSetting: String, CaseIterable {
    case skipIntros, skipRecaps, skipCredits, skipPreviews, skipCommercials
    case subtitleStyle, subtitlePosition, subtitlesWhenMuted
    case dialogue, volumeBoost, volumePerTitle
    case controlsRest
    case mouseClick, mouseDoubleClick, mouseWheel, mouseMiddle
    case appearance, layout, posterSize

    var skipKind: SkipKind? {
        switch self {
        case .skipIntros: .intro
        case .skipRecaps: .recap
        case .skipCredits: .credits
        case .skipPreviews: .preview
        case .skipCommercials: .commercial
        default: nil
        }
    }

    var title: String {
        if let skipKind { return skipKind.title }
        switch self {
        case .subtitleStyle: return String(localized: "Subtitle Style", comment: "Linux setting: how subtitles stand out from the picture")
        case .subtitlePosition: return String(localized: "Subtitle Position", comment: "Linux setting: how high subtitles sit")
        case .subtitlesWhenMuted: return String(localized: "Subtitles While Muted", comment: "Linux setting: show subtitles while the sound is muted")
        case .dialogue: return String(localized: "Dialogue")
        case .volumeBoost: return String(localized: "Volume Boost")
        case .volumePerTitle: return String(localized: "Remember Volume for Each Show", comment: "Linux setting: each show and movie keeps the volume it last played at")
        case .controlsRest: return String(localized: "Hide Controls After", comment: "Linux setting: how long the player's controls stay after the pointer rests")
        case .mouseClick: return String(localized: "Click", comment: "Linux setting: what a click on the playing picture does")
        case .mouseDoubleClick: return String(localized: "Double-Click", comment: "Linux setting: what a double click on the playing picture does")
        case .mouseWheel: return String(localized: "Scroll Wheel", comment: "Linux setting: what the scroll wheel does over the playing picture")
        case .mouseMiddle: return String(localized: "Middle Click", comment: "Linux setting: what a middle click on the playing picture does")
        case .appearance: return String(localized: "Appearance")
        case .layout: return LinuxDisplay.layoutTitle
        case .posterSize: return String(localized: "Poster Size")
        default: return ""
        }
    }

    var explanation: String? {
        if let skipKind { return skipKind.explanation }
        switch self {
        case .subtitleStyle:
            return String(localized: "How subtitles stand out from the picture.", comment: "Linux setting explanation: subtitle style")
        case .subtitlePosition:
            return String(localized: "How high subtitles sit; they still move up out of the way while the controls show.", comment: "Linux setting explanation: subtitle position")
        case .subtitlesWhenMuted:
            return String(localized: "Muting shows subtitles in your language, and turning the sound back on takes them away.", comment: "Linux setting explanation: subtitles while muted")
        case .dialogue:
            return String(localized: "Clear Speech lifts voices over music and effects. Night Mode brings loud passages down.", comment: "Linux setting explanation: dialogue")
        case .volumeBoost:
            return String(localized: "Lets the volume go past 100%, up to 200%, for quiet titles.", comment: "Linux setting explanation: volume boost")
        case .volumePerTitle:
            return String(localized: "Each show and movie starts at the volume it last played at. Off, everything starts where you last set it.", comment: "Linux setting explanation: remember volume")
        case .controlsRest:
            return String(localized: "How long the controls stay over the picture once the pointer stops moving.", comment: "Linux setting explanation: hide controls after")
        case .mouseClick:
            return String(localized: "A click where the hidden controls sit always brings them back.", comment: "Linux setting explanation: click on the picture")
        case .mouseDoubleClick, .mouseMiddle:
            return nil
        case .mouseWheel:
            return String(localized: "Over the volume slider the wheel always turns the volume.", comment: "Linux setting explanation: scroll wheel")
        case .layout: return LinuxDisplay.layoutExplanation
        case .posterSize:
            return String(localized: "Ctrl with plus, minus or the wheel changes it anywhere.", comment: "Linux setting explanation: poster size")
        default: return nil
        }
    }

    var symbol: String {
        if let skipKind { return skipKind.symbol }
        switch self {
        case .subtitleStyle: return "captions.bubble"
        case .subtitlePosition: return "arrow.up.arrow.down"
        case .subtitlesWhenMuted: return "speaker.slash"
        case .dialogue: return "waveform"
        case .volumeBoost: return "speaker.wave.3"
        case .volumePerTitle: return "speaker.wave.2"
        case .controlsRest: return "timer"
        case .mouseClick, .mouseDoubleClick, .mouseMiddle: return "cursorarrow.click"
        case .mouseWheel: return "computermouse"
        case .appearance: return "circle.lefthalf.filled"
        case .layout: return "textformat.size"
        case .posterSize: return "square.grid.2x2"
        default: return "gearshape"
        }
    }

    /// Words that find it besides its title and explanation.
    var keywords: String {
        switch self {
        case .skipIntros, .skipRecaps, .skipCredits, .skipPreviews, .skipCommercials:
            return String(localized: "intro, credits, outro, opening, automatic", comment: "Search keywords for the skip intro and credits settings, comma separated")
        case .subtitleStyle, .subtitlePosition, .subtitlesWhenMuted:
            return String(localized: "captions, CC, text, font, bigger, smaller", comment: "Search keywords for the subtitle size setting, comma separated")
        case .dialogue, .volumeBoost, .volumePerTitle:
            return String(localized: "sound, loud, quiet, voices, volume", comment: "Search keywords for the Linux sound settings, comma separated")
        case .controlsRest, .mouseClick, .mouseDoubleClick, .mouseWheel, .mouseMiddle:
            return String(localized: "mouse, click, wheel, scroll, controls, full screen, pause", comment: "Search keywords for the Linux mouse settings, comma separated")
        case .appearance, .layout, .posterSize:
            return String(localized: "dark mode, light mode, theme", comment: "Search keywords for the appearance setting, comma separated")
        }
    }

    /// Choices by index, or a switch.
    var control: PreferenceSetting.Control {
        if let skipKind {
            let current = SkipSettings.mode(for: skipKind)
            return .choice(skipKind.modes.enumerated().map { SettingChoice(id: $0.offset, title: $0.element.title, isSelected: $0.element == current, detail: $0.element.detail) })
        }
        let taste = PlayerTweakStore.taste()
        switch self {
        case .subtitleStyle:
            return Self.choices(PlayerTweaks.SubtitleStyle.allCases, current: taste.subtitleStyle, title: PlayerScreen.styleTitle)
        case .subtitlePosition:
            return Self.choices(Self.positions, current: taste.subtitlePosition, title: Self.positionTitle)
        case .subtitlesWhenMuted: return .toggle(isOn: taste.subtitlesWhenMuted)
        case .dialogue:
            return Self.choices(PlayerTweaks.Dialogue.allCases, current: taste.dialogue, title: PlayerScreen.dialogueTitle)
        case .volumeBoost: return .toggle(isOn: taste.volumeBoost)
        case .volumePerTitle: return .toggle(isOn: PlayerVolumeStore.isPerTitle())
        case .controlsRest: return Self.choices(PlayerMouse.rests, current: PlayerMouse.rest, title: Self.seconds)
        case .mouseClick: return Self.choices(PlayerMouse.Click.allCases, current: PlayerMouse.click, title: Self.title)
        case .mouseDoubleClick: return Self.choices(PlayerMouse.DoubleClick.allCases, current: PlayerMouse.doubleClick, title: Self.title)
        case .mouseWheel: return Self.choices(PlayerMouse.Wheel.allCases, current: PlayerMouse.wheel, title: Self.title)
        case .mouseMiddle: return Self.choices(PlayerMouse.MiddleClick.allCases, current: PlayerMouse.middleClick, title: Self.title)
        case .appearance: return Self.choices([false, true], current: LinuxDisplay.isLight, title: { $0 ? String(localized: "Light") : String(localized: "Dark") })
        case .layout: return Self.choices([false, true], current: LinuxDisplay.isCouch, title: Self.layoutTitle)
        case .posterSize: return Self.choices(CardZoom.sizes, current: (Theme.current.cardZoom * 10).rounded() / 10, title: { "\(Int(($0 * 100).rounded()))%" })
        default: return .toggle(isOn: false)
        }
    }

    var valueLabel: String {
        switch control {
        case .choice(let choices): choices.first(where: \.isSelected)?.title ?? ""
        case .toggle(let isOn): TitleRulesCopy.onOff(isOn)
        }
    }

    func select(_ choice: SettingChoice, in window: Window?) {
        let index = choice.id
        if let skipKind {
            guard skipKind.modes.indices.contains(index) else { return }
            SkipSettings.set(skipKind.modes[index], for: skipKind)
            return
        }
        switch self {
        case .subtitleStyle: Self.pick(PlayerTweaks.SubtitleStyle.allCases, index) { style in PlayerTweakStore.changeTaste { $0.subtitleStyle = style } }
        case .subtitlePosition: Self.pick(Self.positions, index) { position in PlayerTweakStore.changeTaste { $0.subtitlePosition = position } }
        case .dialogue: Self.pick(PlayerTweaks.Dialogue.allCases, index) { dialogue in PlayerTweakStore.changeTaste { $0.dialogue = dialogue } }
        case .controlsRest: Self.pick(PlayerMouse.rests, index) { PlayerMouse.rest = $0 }
        case .mouseClick: Self.pick(PlayerMouse.Click.allCases, index) { PlayerMouse.click = $0 }
        case .mouseDoubleClick: Self.pick(PlayerMouse.DoubleClick.allCases, index) { PlayerMouse.doubleClick = $0 }
        case .mouseWheel: Self.pick(PlayerMouse.Wheel.allCases, index) { PlayerMouse.wheel = $0 }
        case .mouseMiddle: Self.pick(PlayerMouse.MiddleClick.allCases, index) { PlayerMouse.middleClick = $0 }
        case .appearance: Self.pick([false, true], index) { light in if light != LinuxDisplay.isLight { LinuxDisplay.toggleAppearance(in: window) } }
        case .layout: Self.pick([false, true], index) { couch in if couch != LinuxDisplay.isCouch { LinuxDisplay.toggleDensity(in: window) } }
        case .posterSize:
            Self.pick(CardZoom.sizes, index) { size in
                CardZoom.set(size)
                for each in LinuxDisplay.windows() + [window].compactMap({ $0 }) { each.relayoutEverything() }
            }
        default: return
        }
    }

    func setOn(_ isOn: Bool) {
        switch self {
        case .subtitlesWhenMuted: PlayerTweakStore.changeTaste { $0.subtitlesWhenMuted = isOn }
        case .volumeBoost: PlayerTweakStore.changeTaste { $0.volumeBoost = isOn }
        case .volumePerTitle: PlayerVolumeStore.setPerTitle(isOn)
        default: return
        }
    }

    /// Whether it differs from how Crucible starts out, for Restore Defaults. The window's own appearance and layout are
    /// the desk's to choose and never count.
    var isChanged: Bool {
        if let skipKind { return SkipSettings.mode(for: skipKind) != SkipSettings.defaultMode }
        let taste = PlayerTweakStore.taste()
        let fresh = PlayerTweaks.Taste()
        switch self {
        case .subtitleStyle: return taste.subtitleStyle != fresh.subtitleStyle
        case .subtitlePosition: return taste.subtitlePosition != fresh.subtitlePosition
        case .subtitlesWhenMuted: return taste.subtitlesWhenMuted != fresh.subtitlesWhenMuted
        case .dialogue: return taste.dialogue != fresh.dialogue
        case .volumeBoost: return taste.volumeBoost != fresh.volumeBoost
        case .volumePerTitle: return !PlayerVolumeStore.isPerTitle()
        case .controlsRest: return PlayerMouse.rest != PlayerMouse.defaultRest
        case .mouseClick: return PlayerMouse.click != .playPause
        case .mouseDoubleClick: return PlayerMouse.doubleClick != .fullScreen
        case .mouseWheel: return PlayerMouse.wheel != .seekFive
        case .mouseMiddle: return PlayerMouse.middleClick != .nothing
        case .posterSize: return abs(Theme.current.cardZoom - 1) > 0.01
        default: return false
        }
    }

    func restoreDefault(in window: Window?) {
        guard isChanged else { return }
        if let skipKind {
            SkipSettings.set(SkipSettings.defaultMode, for: skipKind)
            return
        }
        let fresh = PlayerTweaks.Taste()
        switch self {
        case .subtitleStyle: PlayerTweakStore.changeTaste { $0.subtitleStyle = fresh.subtitleStyle }
        case .subtitlePosition: PlayerTweakStore.changeTaste { $0.subtitlePosition = fresh.subtitlePosition }
        case .subtitlesWhenMuted: PlayerTweakStore.changeTaste { $0.subtitlesWhenMuted = fresh.subtitlesWhenMuted }
        case .dialogue: PlayerTweakStore.changeTaste { $0.dialogue = fresh.dialogue }
        case .volumeBoost: PlayerTweakStore.changeTaste { $0.volumeBoost = fresh.volumeBoost }
        case .volumePerTitle: PlayerVolumeStore.setPerTitle(true)
        case .controlsRest: PlayerMouse.rest = PlayerMouse.defaultRest
        case .mouseClick: PlayerMouse.click = .playPause
        case .mouseDoubleClick: PlayerMouse.doubleClick = .fullScreen
        case .mouseWheel: PlayerMouse.wheel = .seekFive
        case .mouseMiddle: PlayerMouse.middleClick = .nothing
        case .posterSize:
            CardZoom.set(1)
            for each in LinuxDisplay.windows() + [window].compactMap({ $0 }) { each.relayoutEverything() }
        default: return
        }
    }

    // MARK: Choices

    /// How far up subtitles can sit, as `PlayerTweaks.Taste.subtitlePosition` keeps it (100 the bottom).
    private static let positions = Array(stride(from: 100, through: 50, by: -5))

    private static func positionTitle(_ position: Int) -> String {
        position >= 100 ? String(localized: "At the Bottom", comment: "Subtitle position option: where the file puts them")
            : String(localized: "\(100 - position)% Higher", comment: "Subtitle position option, how much higher than the bottom, e.g. 10% Higher")
    }

    private static func seconds(_ value: Double) -> String {
        let number = value.rounded() == value ? String(Int(value)) : value.formatted(.number.precision(.fractionLength(1)))
        return String(localized: "\(number) Seconds", comment: "A duration in seconds that may have a decimal, e.g. 1.5 Seconds")
    }

    private static func layoutTitle(_ couch: Bool) -> String {
        couch ? String(localized: "Steam Deck", comment: "Linux layout made for a gamepad, on a Steam Deck or a TV")
              : String(localized: "Desktop", comment: "Linux layout made for a mouse and keyboard on a monitor")
    }

    private static func title(_ click: PlayerMouse.Click) -> String {
        switch click {
        case .playPause: String(localized: "Play or Pause")
        case .showControls: String(localized: "Show or Hide Controls", comment: "Linux mouse setting: a click shows or hides the player's controls")
        case .nothing: nothingTitle
        }
    }

    private static func title(_ click: PlayerMouse.DoubleClick) -> String {
        switch click {
        case .fullScreen: String(localized: "Full Screen", comment: "Player menu")
        case .nothing: nothingTitle
        }
    }

    private static func title(_ wheel: PlayerMouse.Wheel) -> String {
        switch wheel {
        case .seekFive, .seekTen: String(localized: "Seeks \(Int(wheel.seconds ?? 0)) Seconds", comment: "Linux mouse setting: each notch of the wheel seeks this far, e.g. Seeks 5 Seconds")
        case .volume: String(localized: "Turns the Volume", comment: "Linux mouse setting: the wheel turns the volume")
        case .nothing: nothingTitle
        }
    }

    private static func title(_ click: PlayerMouse.MiddleClick) -> String {
        switch click {
        case .nothing: nothingTitle
        case .mute: String(localized: "Mute")
        case .playPause: String(localized: "Play or Pause")
        case .fullScreen: String(localized: "Full Screen", comment: "Player menu")
        }
    }

    private static var nothingTitle: String { String(localized: "Nothing", comment: "Linux mouse setting: the click or wheel does nothing") }

    private static func choices<Value: Equatable>(_ values: [Value], current: Value, title: (Value) -> String) -> PreferenceSetting.Control {
        .choice(values.enumerated().map { SettingChoice(id: $0.offset, title: title($0.element), isSelected: $0.element == current) })
    }

    private static func pick<Value>(_ values: [Value], _ index: Int, _ apply: (Value) -> Void) {
        guard values.indices.contains(index) else { return }
        apply(values[index])
    }
}

/// One row of Linux Settings: a setting of the shared catalogue, one of the Linux client's own, or the list of shows and
/// movies with settings of their own.
@MainActor
enum SettingsRow {
    case entry(SettingsEntry)
    case linux(LinuxSetting)
    case titleRules

    var id: String {
        switch self {
        case .entry(let entry): entry.id
        case .linux(let setting): "linux.\(setting.rawValue)"
        case .titleRules: "linux.titleRules"
        }
    }

    var title: String {
        switch self {
        case .entry(let entry): entry.title
        case .linux(let setting): setting.title
        case .titleRules: TitleRulesCopy.listTitle
        }
    }

    var explanation: String? {
        switch self {
        case .entry(let entry):
            guard case .preference(let setting) = entry.item else { return entry.explanation }
            switch setting {
            case .matchContent: return TitleRulesCopy.matchContentExplanation
            case .skipBack, .skipForward:
                return String(localized: "How far one skip goes: Left and Right, J and L, the media keys and the skip buttons on the player's controls.",
                              comment: "Linux setting explanation: skip distances")
            case .holdLeft, .holdRight:
                return String(localized: "What holding Left or Right does: rewind and fast forward, a jump, or Start Over and Next Episode.",
                              comment: "Linux setting explanation: hold left and right")
            default: return entry.explanation
            }
        case .linux(let setting): return setting.explanation
        case .titleRules: return TitleRulesCopy.listExplanation
        }
    }

    var keywords: String {
        switch self {
        case .entry(let entry): entry.keywords.joined(separator: " ")
        case .linux(let setting): setting.keywords
        case .titleRules: TitleRulesCopy.listKeywords
        }
    }
}

/// Linux Settings' rows: the shared catalogue's categories with the Linux client's own settings in their sections, and a
/// search over all of them.
@MainActor
enum LinuxSettingsCatalog {
    struct Section {
        let title: String?
        let rows: [SettingsRow]
    }

    /// The rows of `category` by section. Playback's Skipping is decided per kind of stretch here, with the shows and
    /// movies that decide for themselves; Subtitles and Audio gain the player's taste; Controls gains how long the controls
    /// stay and, in the Desktop layout, the mouse; Appearance is the window's own.
    static func sections(of category: SettingsCategory) -> [Section] {
        if category == .appearance {
            return [Section(title: nil, rows: [.linux(.appearance), .linux(.layout), .linux(.posterSize)])]
        }
        var sections: [Section] = SettingsCatalog.sections(of: category, on: .linux).map { group in
            var rows: [SettingsRow] = []
            for entry in group.entries {
                switch entry.item {
                case .preference(.skipIntro):
                    rows += [.linux(.skipIntros), .linux(.skipRecaps), .linux(.skipCredits), .linux(.skipPreviews), .linux(.skipCommercials), .titleRules]
                case .preference(.skipOutro):
                    continue
                case .preference(.subtitleSize):
                    rows += [.entry(entry), .linux(.subtitleStyle), .linux(.subtitlePosition), .linux(.subtitlesWhenMuted)]
                case .preference(.audioPassthrough):
                    rows += [.entry(entry), .linux(.dialogue), .linux(.volumeBoost), .linux(.volumePerTitle)]
                default:
                    rows.append(.entry(entry))
                }
            }
            return Section(title: group.title ?? (category == .controls && !LinuxDisplay.isCouch ? TitleRulesCopy.keyboardSection : nil), rows: rows)
        }
        if category == .controls {
            sections.append(Section(title: String(localized: "Player"), rows: [.linux(.controlsRest)]))
            if !LinuxDisplay.isCouch {
                sections.append(Section(title: TitleRulesCopy.mouseSection, rows: [.linux(.mouseClick), .linux(.mouseDoubleClick), .linux(.mouseWheel), .linux(.mouseMiddle)]))
            }
        }
        return sections
    }

    /// The categories Linux Settings lists, Appearance in its place among them.
    static var categories: [SettingsCategory] {
        let listed = Set(SettingsCatalog.categories(on: .linux)).union([.appearance])
        return SettingsCategory.allCases.filter(listed.contains)
    }

    /// The settings matching every word of `query`, by category in Settings' order, the best matches of each first.
    static func search(_ query: String) -> [Section] {
        let tokens = words(query)
        guard !tokens.isEmpty else { return [] }
        return categories.compactMap { category in
            let scored: [(row: SettingsRow, score: Int, order: Int)] = sections(of: category).flatMap { section in
                section.rows.map { (row: $0, section: section.title) }
            }.enumerated().compactMap { index, pair in
                let fields: [(words: [String], weight: Int)] = [
                    (words(pair.row.title), 8), (words(pair.row.keywords), 4), (words(pair.section ?? ""), 2),
                    (words(category.title(on: .linux)), 2), (words(pair.row.explanation ?? ""), 1),
                ]
                var score = 0
                for token in tokens {
                    guard let best = fields.filter({ $0.words.contains { $0.hasPrefix(token) } }).map(\.weight).max() else { return nil }
                    score += best
                }
                return (pair.row, score, index)
            }
            guard !scored.isEmpty else { return nil }
            let rows = scored.sorted { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }.map(\.row)
            return Section(title: category.title(on: .linux), rows: rows)
        }
    }

    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

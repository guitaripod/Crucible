import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// What the show or movie playing keeps for itself over Settings (`TitlePlaybackRules`): how each kind of stretch is
/// skipped, whether the next episode plays on its own, and Match Content. The right-click menu's This Show (or This Movie)
/// sets them, as does a right click on the skip button for the stretch it offers; Settings › Playback lists every title
/// that has some.
extension PlayerScreen {
    /// What this show or movie keeps for itself; a file or a web video has none.
    var titleRules: TitlePlaybackRules {
        guard case .plex = source else { return TitlePlaybackRules() }
        if let keptTitleRules { return keptTitleRules }
        let rules = TitleRulesStore.rules(for: showOrTitleKey)
        keptTitleRules = rules
        return rules
    }

    /// The show's or movie's name, as Settings lists it.
    private var rulesTitleName: String? {
        guard case .plex(_, let item, _) = source else { return nil }
        return item.grandparentTitle ?? item.title
    }

    /// Changes this show's or movie's rules and takes them up at once.
    func changeTitleRules(_ change: (inout TitlePlaybackRules) -> Void) {
        guard case .plex(_, let item, _) = source else { return }
        TitleRulesStore.update(showOrTitleKey, name: rulesTitleName, isShow: item.grandparentRatingKey != nil, change)
        keptTitleRules = TitleRulesStore.rules(for: showOrTitleKey)
        applyTitleRules()
        updateSkip()
    }

    /// Hands this title's credits and autoplay rules to Up Next, at the start and whenever they change.
    func applyTitleRules() {
        guard upNext != nil else { return }
        let rules = titleRules
        upNext?.creditsMode = rules.mode(for: .credits, settings: SkipSettings.mode(for: .credits)).creditsMode
        upNext?.autoplaysNext = rules.autoplays(settings: Preferences.autoplayNextEpisode)
    }

    /// Follows what Settings changes while this player is open: the title rules and Skipping (Up Next's rules, a skip
    /// button showing now, and Match Content when Settings turned it on or off for this title), and the taste and
    /// subtitle size. The player's own changes have already been taken up, so they match what is kept and change nothing.
    func followSettings() {
        let center = NotificationCenter.default
        settingsObservers.append(center.addObserver(forName: TitleRulesStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                let matchedBefore = self.keptTitleRules?.matchContent
                self.keptTitleRules = nil
                self.applyTitleRules()
                self.updateSkip()
                guard let matchedBefore, matchedBefore != self.titleRules.matchContent, self.window?.isFullscreen == true, !self.isMini,
                      let stream = self.stream else { return }
                self.engageMatchContent(stream)
            }
        })
        settingsObservers.append(center.addObserver(forName: PlayerTweakStore.tasteChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.closed, let player = self.player else { return }
                self.tweaks.taste = PlayerTweakStore.taste()
                player.maximumVolume = self.tweaks.taste.volumeBoost ? 200 : 100
                player.set("sub-scale", String(format: "%.2f", Double(Preferences.subtitleSize.rawValue) / 100))
                self.applySubtitleLook()
                self.applyAudioFilters()
            }
        })
    }

    // MARK: Menus

    /// This Show, This Movie or This Title in the right-click menu, for a title from the server.
    func titleRulesSubmenu() -> ContextMenuView.Entry? {
        guard case .plex(_, let item, _) = source else { return nil }
        let title: String
        switch item.mediaType {
        case "episode": title = TitleRulesCopy.thisShow
        case "movie": title = TitleRulesCopy.thisMovie
        default: title = TitleRulesCopy.thisTitle
        }
        return .submenu(title, detail: titleRules.hasRules ? TitleRulesCopy.ownRules : nil, symbol: "slider.horizontal.3") { [weak self] in
            self?.titleRulesEntries() ?? []
        }
    }

    /// The kinds of stretch worth a row for this title: a show's intros, recaps, credits and previews, a film's credits,
    /// and any other kind this title has or already has a rule for.
    private var ruledKinds: [SkipKind] {
        let present = Set(segments.map { SkipKind($0.kind) })
        let rules = titleRules
        let usual: Set<SkipKind> = isEpisode ? [.intro, .recap, .credits, .preview] : [.credits]
        return SkipKind.allCases.filter { usual.contains($0) || present.contains($0) || rules[$0] != nil }
    }

    private func titleRulesEntries() -> [ContextMenuView.Entry] {
        typealias Action = ContextMenuView.Action
        let rules = titleRules
        var entries: [ContextMenuView.Entry] = []
        if let name = rulesTitleName { entries.append(.section(name)) }
        for kind in ruledKinds {
            let settings = SkipSettings.mode(for: kind)
            entries.append(.submenu(kind.title, detail: rules[kind]?.title ?? TitleRulesCopy.followingSettings(settings.title), symbol: Symbol(kind.symbol)) {
                [weak self] in self?.skipModeEntries(kind, closesMenu: false) ?? []
            })
        }
        if isEpisode {
            let settings = Preferences.autoplayNextEpisode
            let detail = rules.autoplay.map(TitleRulesCopy.onOff) ?? TitleRulesCopy.followingSettings(TitleRulesCopy.onOff(settings))
            entries.append(.submenu(PreferenceSetting.autoplayNextEpisode.title, detail: detail, symbol: "play") { [weak self] in
                guard let self else { return [] }
                let current = self.titleRules.autoplay
                return [
                    .action(Action(TitleRulesCopy.followingSettings(TitleRulesCopy.onOff(settings)), isChecked: current == nil, keepsOpen: true) {
                        [weak self] in self?.changeTitleRules { $0.autoplay = nil }
                    }),
                    .action(Action(TitleRulesCopy.onOff(true), isChecked: current == true, keepsOpen: true) { [weak self] in self?.changeTitleRules { $0.autoplay = true } }),
                    .action(Action(TitleRulesCopy.onOff(false), isChecked: current == false, keepsOpen: true) { [weak self] in self?.changeTitleRules { $0.autoplay = false } }),
                ]
            })
        }
        if Preferences.matchesContent {
            entries.append(.action(Action(PreferenceSetting.matchContent.title, symbol: "tv", isChecked: rules.matchContent, keepsOpen: true) {
                [weak self] in self.map { $0.setMatchContent(!$0.matchesContent) }
            }))
        }
        if rules.hasRules {
            entries.append(.separator)
            entries.append(.action(Action(TitleRulesCopy.useSettingsForAll, symbol: "arrow.counterclockwise", keepsOpen: true) { [weak self] in
                guard let self else { return }
                let wasMatching = self.matchesContent
                self.changeTitleRules { $0 = TitlePlaybackRules() }
                if wasMatching, let stream = self.stream { self.engageMatchContent(stream) }
            }))
        }
        return entries
    }

    /// The choices for `kind` in this title: Settings' own (named), then each mode. From the skip button's menu a choice
    /// closes it and says what changed; from This Show the menu stays open.
    private func skipModeEntries(_ kind: SkipKind, closesMenu: Bool) -> [ContextMenuView.Entry] {
        let current = titleRules[kind]
        let settings = SkipSettings.mode(for: kind)
        let choose: @MainActor (SkipMode?) -> Void = { [weak self] mode in
            self?.changeTitleRules { $0[kind] = mode }
            if closesMenu { self?.say(TitleRulesCopy.labelled(kind.title, (mode ?? settings).title), symbol: "forward.end") }
        }
        var entries: [ContextMenuView.Entry] = [
            .action(ContextMenuView.Action(TitleRulesCopy.followingSettings(settings.title), isChecked: current == nil, keepsOpen: !closesMenu) { choose(nil) }),
        ]
        entries += kind.modes.map { mode in
            .action(ContextMenuView.Action(mode.title, detail: mode.detail, isChecked: current == mode, keepsOpen: !closesMenu) { choose(mode) })
        }
        return entries
    }

    /// A right click on the skip button: how this show or movie skips the stretch the button offers. False when the button
    /// offers nothing of a title from the server (Undo Skip, a web video), so the usual menu opens instead.
    func presentSkipMenu(at point: Point) -> Bool {
        guard undo == nil, case .plex = source, let window else { return false }
        let now = position
        guard let segment = segments.first(where: { now >= $0.startSecs && now < $0.endSecs }) else { return false }
        let kind = SkipKind(segment.kind)
        let heading = [rulesTitleName, kind.title].compactMap { $0 }.joined(separator: " · ")
        contextMenu?.dismiss()
        let menu = ContextMenuView(at: point, highlightingFirstRow: false) { [weak self] in
            [.section(heading)] + (self?.skipModeEntries(kind, closesMenu: true) ?? [])
        }
        menu.onDismiss = { [weak self] in
            self?.showChrome(autoHide: true)
            self?.contextMenu = nil
        }
        contextMenu = menu
        menu.present(in: window)
        showChrome(autoHide: false)
        holdChrome()
        return true
    }
}

/// The words of the per-title rules, shared by the player's menus and Settings.
enum TitleRulesCopy {
    static var thisShow: String { String(localized: "This Show", comment: "Player menu: the settings kept for the show playing") }
    static var thisMovie: String { String(localized: "This Movie", comment: "Player menu: the settings kept for the movie playing") }
    static var thisTitle: String { String(localized: "This Title", comment: "Player menu: the settings kept for the title playing, neither a show nor a movie") }
    static var ownRules: String { String(localized: "Own Settings", comment: "Detail of the player's This Show menu while the show has settings of its own") }
    static var useSettingsForAll: String {
        String(localized: "Use Settings for Everything", comment: "Menu action: a show or movie goes back to following Settings for every rule it had of its own")
    }

    /// "Default (Show Button)": the choice that follows Settings, naming what Settings say.
    static func followingSettings(_ value: String) -> String {
        String(localized: "Default (\(value))", comment: "Choice that follows Settings, with what Settings say, e.g. Default (Show Button)")
    }

    static func onOff(_ isOn: Bool) -> String { isOn ? String(localized: "On") : String(localized: "Off") }

    /// "Intros: Skip Automatically", with the language's own punctuation.
    static func labelled(_ label: String, _ value: String) -> String { String(localized: "\(label): \(value)") }

    /// Settings' row and screen for the shows and movies with settings of their own.
    static var listTitle: String { String(localized: "Shows & Movies", comment: "Linux Settings: the shows and movies with skip and Up Next settings of their own") }

    static var listExplanation: String {
        String(localized: "Shows and movies that skip, play on or match the screen their own way. Set them in the player's menu, on the title's page, or here.",
               comment: "Linux Settings: what the Shows & Movies row lists")
    }

    static var listKeywords: String {
        String(localized: "per show, per movie, override, exception, series", comment: "Search keywords for the shows and movies with settings of their own, comma separated")
    }

    static func listValue(_ count: Int) -> String {
        count == 0 ? String(localized: "None", comment: "Linux Settings: no show or movie has settings of its own")
            : String(localized: "\(count) Titles", comment: "Linux Settings: how many shows and movies have settings of their own, e.g. 3 Titles")
    }

    static var matchContentExplanation: String {
        String(localized: "While the player fills the screen, it switches to a refresh rate that suits the title and to HDR for an HDR title, for each show or movie you turn it on for in the player's This Show menu. On KDE Plasma.",
               comment: "Linux setting explanation: Match Content, turned on per show or movie")
    }

    static var keyboardSection: String { String(localized: "Keyboard", comment: "Linux Settings section: what the keys do while a video plays") }
    static var mouseSection: String { String(localized: "Mouse", comment: "Linux Settings section: what the mouse does over the playing picture") }

    /// The page for one show's or movie's settings, and the action that opens it.
    static var pageTitle: String { String(localized: "Playback Settings", comment: "Title page action and screen: how this show or movie skips, plays on and matches the screen") }

    static var rememberedSection: String { String(localized: "Remembered", comment: "Linux Settings section: what the player kept for this show on its own (volume, languages)") }

    static var forgetAll: String { String(localized: "Forget This Title's Settings", comment: "Linux Settings action: a show or movie goes back to Settings and forgets its volume and languages") }

    static var noneYet: String {
        String(localized: "No show or movie has settings of its own yet.", comment: "Linux Settings: the empty Shows & Movies list")
    }

    static var matchContentForTitle: String {
        String(localized: "While the player fills the screen, it switches to a refresh rate that suits this title, and to HDR when the title is HDR.",
               comment: "Linux: Match Content on one show's or movie's settings page")
    }

    static var matchContentOffInSettings: String {
        String(localized: "Match Content is off in Settings › Playback, so no title switches the screen.", comment: "Linux: a title's Match Content row while Match Content is off in Settings")
    }

    static var volumeExplanation: String {
        String(localized: "Where the volume was when it last played.", comment: "Linux: the volume a show or movie remembered")
    }

    static var languagesTitle: String { String(localized: "Audio & Subtitles", comment: "Linux: the audio and subtitle languages a show remembered") }

    static var languagesExplanation: String {
        String(localized: "The languages you last chose, which every episode starts in.", comment: "Linux: the languages a show remembered")
    }

    static var notKept: String { String(localized: "Not Kept", comment: "Linux: nothing remembered for this show or movie") }

    /// "Forget Volume?" and the like.
    static func forgetTitle(_ what: String) -> String {
        String(localized: "Forget \(what)?", comment: "Linux: confirmation title for forgetting what a show remembered, e.g. Forget Volume?")
    }

    static var forgetAllMessage: String {
        String(localized: "It follows Settings again, and starts at the volume and languages you last chose anywhere.", comment: "Linux: confirmation message for forgetting a title's settings")
    }

    /// "Japanese · English Subtitles", or the audio alone, or "Subtitles Off".
    static func languagesSummary(_ languages: TrackLanguages) -> String {
        var parts: [String] = []
        if let audio = languages.audio { parts.append(SubtitleLanguages.name(for: audio.language)) }
        if let subtitle = languages.subtitle {
            parts.append(String(localized: "\(SubtitleLanguages.name(for: subtitle.language)) Subtitles", comment: "Linux: the subtitle language a show remembered, e.g. English Subtitles"))
        } else if languages.subtitlesOff {
            parts.append(String(localized: "Subtitles Off", comment: "Linux: a show remembered subtitles turned off"))
        }
        return parts.joined(separator: " · ")
    }

    /// What a title does its own way, for its row: "Intros: Skip Automatically · Autoplay: Off · Match Content".
    static func summary(of rules: TitlePlaybackRules) -> String {
        var parts = SkipKind.allCases.compactMap { kind in rules[kind].map { labelled(kind.title, $0.title) } }
        if let autoplay = rules.autoplay { parts.append(labelled(PreferenceSetting.autoplayNextEpisode.title, onOff(autoplay))) }
        if rules.matchContent { parts.append(PreferenceSetting.matchContent.title) }
        return parts.joined(separator: " · ")
    }
}

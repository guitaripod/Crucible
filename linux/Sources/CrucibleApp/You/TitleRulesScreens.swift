import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// A page of settings sections for the per-title screens: a title, then each section's heading over its rows, as cards
/// down the leading side in the Desktop layout (with choices made in place) and as the Apple TV's centred list on a couch.
@MainActor
class GroupedSettingsPage: ScreenView {
    struct Section {
        let title: String?
        let rows: [RowItem]
    }

    let heading: ScreenTitleView
    private let page = PageView()
    private var headers: [ScreenTitleView] = []
    private var lists: [RowListView] = []
    private let state = StateView()

    init(title: String, detail: String?) {
        heading = ScreenTitleView(title: title, detail: detail)
        super.init()
        addSubview(page)
        addSubview(state)
        state.isHidden = true
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
    }

    override var preferredFocusView: View? { state.isHidden ? lists.first { !$0.items.isEmpty } : state }

    private var isDesk: Bool { Theme.current.density == .desk }

    /// Shows `sections` in place of what was there, keeping each list (and the focus in it) where its rows stay.
    func show(_ sections: [Section]) {
        state.isHidden = true
        page.isHidden = false
        let metrics = Theme.current.metrics
        heading.columnWidth = metrics.settingsColumn
        heading.isLeadingAligned = isDesk
        var views: [View] = [heading]
        for (index, section) in sections.enumerated() {
            if let title = section.title {
                let header = index < headers.count ? headers[index] : ScreenTitleView(title: "")
                if index >= headers.count { headers.append(header) }
                header.detail = title.uppercased()
                header.columnWidth = metrics.settingsColumn
                header.isLeadingAligned = isDesk
                views.append(header)
            }
            let list = index < lists.count ? lists[index] : makeList()
            if index >= lists.count { lists.append(list) }
            list.isGrouped = isDesk
            list.isLeadingAligned = isDesk
            list.columnWidth = metrics.settingsColumn
            list.setItems(section.rows)
            views.append(list)
        }
        for unused in lists.dropFirst(sections.count) { unused.setItems([]) }
        page.setSections(views)
        setNeedsLayout()
    }

    /// Shows an empty or failed state in the rows' place.
    func show(_ newState: StateView.State) {
        state.show(newState)
        state.isHidden = false
        page.isHidden = true
        setNeedsLayout()
    }

    private func makeList() -> RowListView {
        let list = RowListView()
        list.onSelect = { [weak self] item in self?.rowSelected(item.id, anchor: nil) }
        list.onChoose = { [weak self] item, index, anchor in
            if let index { self?.optionChosen(item.id, index: index) } else { self?.rowSelected(item.id, anchor: anchor) }
        }
        list.onContextMenu = { [weak self] item, anchor in self?.rowMenu(item.id, at: anchor) ?? false }
        return list
    }

    /// Enter or a click on row `id`, or a click on its pop-up button with where it sits.
    func rowSelected(_ id: String, anchor: Rect?) {}

    /// A click on option `index` of row `id`'s choices.
    func optionChosen(_ id: String, index: Int) {}

    /// A right click on row `id`; true when a menu opened.
    func rowMenu(_ id: String, at anchor: Rect) -> Bool { false }

    /// Where a row's options hang from: under its control on a desk, under its trailing part on a couch.
    func anchor(for id: String) -> Rect {
        let frame = lists.lazy.compactMap { $0.row(id: id) }.first?.frameInWindow ?? frameInWindow
        let metrics = Theme.current.metrics
        let width = metrics.tv(isDesk ? 420 : 500)
        return isDesk ? Rect(x: frame.maxX - width - metrics.rowInset, y: frame.minY, width: width, height: frame.height)
            : Rect(x: frame.maxX - width, y: frame.maxY, width: 1, height: 1)
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        page.topInset = metrics.tabBarClearance
        page.bottomInset = metrics.tv(60)
        page.frame = bounds
        state.frame = Rect(x: metrics.sideMargin, y: metrics.tabBarClearance + heading.sizeThatFits(bounds.size).height, width: bounds.width - metrics.sideMargin * 2,
                           height: metrics.tv(480))
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

/// One show's or movie's own playback settings (`TitlePlaybackRules`): how each kind of stretch is skipped, whether the
/// next episode plays on its own, Match Content, and what the player remembered for it on its own (the volume, a show's
/// audio and subtitle languages), each of which can be forgotten. Opened from Settings' Shows & Movies, from the title's
/// page, and nowhere else changes them but the player's This Show menu.
@MainActor
final class TitleRulesScreen: GroupedSettingsPage {
    private let key: String
    private let ratingKey: String
    private let isShow: Bool
    private var observer: NSObjectProtocol?
    private weak var openMenu: MenuView?

    private enum RowID {
        static let skipPrefix = "skip."
        static let autoplay = "autoplay"
        static let countdown = "countdown"
        static let matchContent = "matchContent"
        static let volume = "volume"
        static let languages = "languages"
        static let forget = "forget"
    }

    init(ratingKey: String, name: String, isShow: Bool) {
        self.ratingKey = ratingKey
        key = PlayerTweakStore.key(ratingKey: ratingKey)
        self.isShow = isShow
        super.init(title: name, detail: TitleRulesCopy.pageTitle)
        render()
    }

    override func screenDidAppear() {
        render()
        observer = NotificationCenter.default.addObserver(forName: TitleRulesStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
    }

    override func screenWillDisappear() {
        observer.map { NotificationCenter.default.removeObserver($0) }
        observer = nil
        openMenu?.dismiss()
    }

    private var rules: TitlePlaybackRules { TitleRulesStore.rules(for: key) }

    private var kinds: [SkipKind] { isShow ? SkipKind.allCases : [.intro, .credits, .commercial] }

    private var languages: TrackLanguages? {
        isShow ? ShowTrackMemory.languages(forShow: ratingKey, server: ServerBootstrap.savedMachineIdentifier ?? "unknown") : nil
    }

    /// A row's options: Settings' own first, naming it, then each mode or On and Off.
    private func options(for id: String) -> (titles: [String], selected: Int, pick: (Int) -> Void)? {
        let rules = rules
        if id.hasPrefix(RowID.skipPrefix), let kind = SkipKind(rawValue: String(id.dropFirst(RowID.skipPrefix.count))) {
            let titles = [TitleRulesCopy.followingSettings(SkipSettings.mode(for: kind).title)] + kind.modes.map(\.title)
            let selected = rules[kind].flatMap { kind.modes.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            return (titles, selected, { [weak self] index in self?.change { $0[kind] = index == 0 ? nil : kind.modes[index - 1] } })
        }
        if id == RowID.autoplay {
            let titles = [TitleRulesCopy.followingSettings(TitleRulesCopy.onOff(Preferences.autoplayNextEpisode)), TitleRulesCopy.onOff(true), TitleRulesCopy.onOff(false)]
            let selected = rules.autoplay.map { $0 ? 1 : 2 } ?? 0
            return (titles, selected, { [weak self] index in self?.change { $0.autoplay = index == 0 ? nil : index == 1 } })
        }
        if id == RowID.countdown {
            let choices = Preferences.upNextCountdownChoices
            let titles = [TitleRulesCopy.countdownDetail(nil)] + choices.map(PreferenceSetting.upNextCountdownTitle)
            let selected = rules.upNextCountdown.flatMap { choices.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            return (titles, selected, { [weak self] index in self?.change { $0.upNextCountdown = index == 0 ? nil : choices[index - 1] } })
        }
        return nil
    }

    private func change(_ edit: (inout TitlePlaybackRules) -> Void) {
        TitleRulesStore.update(key, name: heading.title, isShow: isShow, edit)
        render()
    }

    private func render() {
        let rules = rules
        var sections: [Section] = []
        let skipping = kinds.compactMap { kind -> RowItem? in
            guard let found = options(for: RowID.skipPrefix + kind.rawValue) else { return nil }
            return .choice(id: RowID.skipPrefix + kind.rawValue, title: kind.title, subtitle: kind.explanation, options: found.titles, selected: found.selected,
                           symbol: Symbol(kind.symbol))
        }
        sections.append(Section(title: String(localized: "Skipping", comment: "Settings section for skip intro and skip credits"), rows: skipping))
        if isShow, let autoplay = options(for: RowID.autoplay), let countdown = options(for: RowID.countdown) {
            sections.append(Section(title: String(localized: "Up Next"), rows: [
                .choice(id: RowID.autoplay, title: PreferenceSetting.autoplayNextEpisode.title, subtitle: PreferenceSetting.autoplayNextEpisode.explanation,
                        options: autoplay.titles, selected: autoplay.selected, symbol: "play"),
                .choice(id: RowID.countdown, title: PreferenceSetting.upNextCountdown.title, subtitle: PreferenceSetting.upNextCountdown.explanation,
                        options: countdown.titles, selected: countdown.selected, symbol: "timer"),
            ]))
        }
        sections.append(Section(title: String(localized: "Video", comment: "Stream Info label"), rows: [
            .onOff(id: RowID.matchContent, title: PreferenceSetting.matchContent.title,
                   subtitle: Preferences.matchesContent ? TitleRulesCopy.matchContentForTitle : TitleRulesCopy.matchContentOffInSettings,
                   isOn: rules.matchContent, symbol: "tv", isEnabled: Preferences.matchesContent),
        ]))
        var remembered: [RowItem] = []
        let volume = PlayerVolumeStore.titleVolume(for: key)
        remembered.append(RowItem(id: RowID.volume, title: String(localized: "Volume"), subtitle: TitleRulesCopy.volumeExplanation,
                                  value: volume.map { "\(Int($0.rounded()))%" } ?? TitleRulesCopy.notKept, symbol: "speaker.wave.2",
                                  isStatic: volume == nil))
        if isShow {
            let summary = languages.map(TitleRulesCopy.languagesSummary) ?? TitleRulesCopy.notKept
            remembered.append(RowItem(id: RowID.languages, title: TitleRulesCopy.languagesTitle, subtitle: TitleRulesCopy.languagesExplanation, value: summary,
                                      symbol: "captions.bubble", isStatic: languages == nil))
        }
        let anything = rules.hasRules || volume != nil || languages != nil
        remembered.append(RowItem(id: RowID.forget, title: TitleRulesCopy.forgetAll, symbol: "arrow.counterclockwise", isDestructive: true, isEnabled: anything))
        sections.append(Section(title: TitleRulesCopy.rememberedSection, rows: remembered))
        show(sections)
    }

    override func rowSelected(_ id: String, anchor: Rect?) {
        guard let window else { return }
        switch id {
        case RowID.matchContent:
            change { $0.matchContent.toggle() }
        case RowID.volume, RowID.languages:
            AlertView.confirm(title: TitleRulesCopy.forgetTitle(id == RowID.volume ? String(localized: "Volume") : TitleRulesCopy.languagesTitle),
                              message: nil, confirm: String(localized: "Forget"), in: window) { [weak self] in self?.forget(id) }
        case RowID.forget:
            AlertView.confirm(title: TitleRulesCopy.forgetAll + "?", message: TitleRulesCopy.forgetAllMessage, confirm: String(localized: "Forget"), in: window) {
                [weak self] in
                guard let self else { return }
                TitleRulesStore.forget(self.key)
                self.forget(RowID.volume)
                self.forget(RowID.languages)
            }
        default:
            guard let found = options(for: id) else { return }
            openMenu?.dismiss()
            let menu = MenuView(title: nil, items: found.titles.enumerated().map {
                MenuView.Item(id: String($0.offset), title: $0.element, isChecked: $0.offset == found.selected)
            }, anchor: anchor ?? self.anchor(for: id))
            menu.onSelect = { item in Int(item.id).map(found.pick) }
            openMenu = menu
            menu.present(in: window)
        }
    }

    override func optionChosen(_ id: String, index: Int) {
        guard let found = options(for: id), index != found.selected, found.titles.indices.contains(index) else { return }
        found.pick(index)
    }

    override func rowMenu(_ id: String, at anchor: Rect) -> Bool {
        guard let window else { return false }
        var entries: [ContextMenuView.Entry] = []
        if let found = options(for: id) {
            entries = found.titles.enumerated().map { option in
                .action(ContextMenuView.Action(option.element, isChecked: option.offset == found.selected) { found.pick(option.offset) })
            }
        } else if id == RowID.volume || id == RowID.languages {
            entries = [.action(ContextMenuView.Action(String(localized: "Forget"), symbol: "arrow.counterclockwise") { [weak self] in self?.forget(id) })]
        }
        guard !entries.isEmpty else { return false }
        ContextMenuView(at: anchor.origin, highlightingFirstRow: false) { entries }.present(in: window)
        return true
    }

    private func forget(_ id: String) {
        switch id {
        case RowID.volume: PlayerVolumeStore.forget(key)
        case RowID.languages: ShowTrackMemory.remember(TrackLanguages(audio: nil, subtitle: nil), forShow: ratingKey, server: ServerBootstrap.savedMachineIdentifier ?? "unknown")
        default: break
        }
        render()
    }
}

/// Settings › Playback › Shows & Movies: every show and movie with settings of its own, the last changed first, each
/// summing up what it does its own way. A click opens its page; a right click lets it follow Settings again. Titles kept
/// before names were (Match Content's from 0.19.0) get theirs from the server.
@MainActor
final class TitleRulesListScreen: GroupedSettingsPage {
    private let api: APIClient
    private var entries: [TitleRulesStore.Entry] = []
    private var naming: Task<Void, Never>?

    init(api: APIClient) {
        self.api = api
        super.init(title: TitleRulesCopy.listTitle, detail: TitleRulesCopy.listExplanation)
    }

    override func screenDidAppear() {
        render()
        nameUnnamed()
    }

    override func screenWillDisappear() {
        naming?.cancel()
    }

    private func render() {
        entries = TitleRulesStore.all()
        guard !entries.isEmpty else {
            show(.empty(title: TitleRulesCopy.listTitle, message: TitleRulesCopy.noneYet, symbol: "slider.horizontal.3", action: nil))
            return
        }
        let rows = entries.map { entry in
            RowItem(id: entry.key, title: entry.rules.name ?? "…", subtitle: TitleRulesCopy.summary(of: entry.rules),
                    symbol: entry.rules.isShow == false ? "film" : "tv", accessory: .chevron)
        }
        show([Section(title: nil, rows: rows)])
    }

    /// Asks the server for the names of titles kept without one, and keeps them.
    private func nameUnnamed() {
        let unnamed = entries.filter { $0.rules.name == nil }
        guard !unnamed.isEmpty else { return }
        naming?.cancel()
        let api = api
        naming = Task { [weak self] in
            for entry in unnamed {
                guard let ratingKey = entry.ratingKey,
                      let item = try? await api.requestContainer(.metadata(ratingKey: ratingKey)).Metadata?.first else { continue }
                guard !Task.isCancelled else { return }
                TitleRulesStore.name(entry.key, item.title, isShow: item.mediaType == "show")
            }
            self?.render()
        }
    }

    override func rowSelected(_ id: String, anchor: Rect?) {
        guard let entry = entries.first(where: { $0.key == id }), let ratingKey = entry.ratingKey else { return }
        navigation?.push(TitleRulesScreen(ratingKey: ratingKey, name: entry.rules.name ?? "…", isShow: entry.rules.isShow ?? true))
    }

    override func rowMenu(_ id: String, at anchor: Rect) -> Bool {
        guard let window else { return false }
        ContextMenuView(at: anchor.origin, highlightingFirstRow: false) {
            [.action(ContextMenuView.Action(TitleRulesCopy.useSettingsForAll, symbol: "arrow.counterclockwise") { [weak self] in
                TitleRulesStore.forget(id)
                self?.render()
            })]
        }.present(in: window)
        return true
    }
}

import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// Settings: the shared catalogue's categories for this platform, each with its value line, opening a screen of rows
/// where a choice opens a menu of its options and a switch flips in place. In the Desktop layout the categories stand in
/// a column down the left under a search field and the chosen one's page fills the rest, so moving between them never
/// leaves Settings; typing anywhere on Settings searches every setting, and the matches show in the page's place.
@MainActor
final class SettingsScreen: ScreenView {
    private let title = ScreenTitleView(title: String(localized: "Settings"))
    private let rows = RowListView()
    private let page = PageView()
    private let api: APIClient
    private let categoryList = SidebarView()
    private let search = TextFieldView(placeholder: String(localized: "Search Settings"))
    /// The category whose page showed before a search took its place, which clearing the search brings back.
    private var paneBeforeSearch: String?
    /// The chosen category's page beside the list, in the Desktop layout.
    private var pane: ScreenView?
    private var paneID: String?
    /// The category last open beside the list, which Settings opens on again.
    private static var lastPaneID: String?

    init(api: APIClient) {
        self.api = api
        super.init()
        title.columnWidth = Theme.current.metrics.wideColumn
        addSubview(page)
        page.setSections([title, rows])
        rows.onSelect = { [weak self] item in
            guard let self, let screen = self.screen(for: item.id) else { return }
            self.navigation?.push(screen)
        }
        categoryList.showsNavigation = false
        categoryList.onSelect = { [weak self] item, _ in
            self?.search.setText("", notify: false)
            self?.paneBeforeSearch = nil
            self?.showPane(item.id)
        }
        addSubview(categoryList)
        search.onChange = { [weak self] text in self?.searchChanged(text) }
        search.onSubmit = { [weak self] _ in self?.focusFirstResult() }
        addSubview(search)
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
    }

    override var preferredFocusView: View? { usesPanes ? categoryList : rows }

    /// Whether the categories stand beside the chosen one's page (the Desktop layout) or open one at a time.
    private var usesPanes: Bool { Theme.current.density == .desk }

    /// The page of the category or setting `id`.
    private func screen(for id: String) -> ScreenView? {
        if id == Self.ownModelID { return OwnModelSettingsScreen() }
        if id == Self.webVideoID { return WebSettingsScreen() }
        if id == Self.crucibleServerID { return CrucibleServerScreen() }
        guard let category = SettingsCategory(rawValue: id) else { return nil }
        return SettingsCategoryScreen(category: category, api: api)
    }

    /// Opens `id`'s page beside the list in place of the one there; its own deeper pages still push onto the stack.
    private func showPane(_ id: String) {
        guard id != paneID || pane == nil, let screen = screen(for: id) else { return }
        install(screen)
        paneID = id
        Self.lastPaneID = id
        categoryList.select(id)
        placePanes()
    }

    private func install(_ screen: ScreenView) {
        pane?.screenWillDisappear()
        pane?.removeFromSuperview()
        screen.navigation = navigation
        pane = screen
        addSubview(screen)
        placePanes()
        screen.screenDidAppear()
    }

    // MARK: Search

    /// Puts typing that reached Settings into its search field (the desk's type-anywhere); false on a couch.
    func beginSearch(with typed: String) -> Bool {
        guard usesPanes else { return false }
        window?.focus.focus(search, animated: false)
        search.insert(typed)
        return true
    }

    /// Moves the keyboard to the search field (Ctrl+F on Settings); false on a couch.
    func focusSearch() -> Bool {
        guard usesPanes else { return false }
        window?.focus.focus(search, animated: false)
        return true
    }

    /// Shows the settings matching `text` in the page's place, or the category that was there once it is empty again.
    private func searchChanged(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            let back = paneBeforeSearch ?? Self.lastPaneID ?? rows.items.first?.id
            paneBeforeSearch = nil
            paneID = nil
            if let back { showPane(back) }
            return
        }
        if paneBeforeSearch == nil { paneBeforeSearch = paneID }
        paneID = nil
        categoryList.select(nil)
        if let results = pane as? SettingsCategoryScreen, results.isSearch {
            results.search(query)
        } else {
            install(SettingsCategoryScreen(search: query, api: api))
        }
    }

    /// Return in the search field moves to the first match.
    private func focusFirstResult() {
        guard let results = pane as? SettingsCategoryScreen, results.isSearch, let first = results.preferredFocusView else { return }
        window?.focus.focus(first, animated: false)
    }

    private static let ownModelID = "linux.ownModel"
    private static let webVideoID = "linux.webVideo"
    private static let crucibleServerID = "linux.crucibleServer"

    override func screenDidAppear() {
        render()
        let previous = YouConnectionStatus.shared.onChange
        restoreConnectionHandler = { YouConnectionStatus.shared.onChange = previous }
        YouConnectionStatus.shared.onChange = { [weak self] state in
            previous?(state)
            self?.render()
        }
        YouConnectionStatus.shared.refresh(api: api)
    }

    override func screenWillDisappear() {
        restoreConnectionHandler?()
        restoreConnectionHandler = nil
        pane?.screenWillDisappear()
    }

    /// Puts You's own handler back on the connection status when Settings leaves, since the status keeps one.
    private var restoreConnectionHandler: (() -> Void)?

    private func render() {
        var items = Self.categories.map { category in
            RowItem(id: category.rawValue, title: category.title(on: .linux), subtitle: category.explanation(on: .linux), value: Self.value(of: category),
                    symbol: Symbol(category.symbol), accessory: .chevron)
        }
        let ownModel = RowItem(id: Self.ownModelID, title: OwnModelCopy.title, subtitle: WatchCopy.title,
                               value: OwnModel.model ?? OwnModelCopy.notSet, symbol: "sparkles", accessory: .chevron)
        let after = items.firstIndex { $0.id == SettingsCategory.integrations.rawValue }.map { $0 + 1 } ?? items.count
        items.insert(ownModel, at: after)
        let webVideo = RowItem(id: Self.webVideoID, title: WebSettingsCopy.title, subtitle: WebSettingsCopy.pitch, value: WebSettings.quality.title,
                               symbol: "play.rectangle", accessory: .chevron)
        items.insert(webVideo, at: min(after + 1, items.count))
        if !DemoMode.shared.isActive {
            let server = RowItem(id: Self.crucibleServerID, title: CompanionCopy.title, subtitle: CompanionCopy.pitch, value: CrucibleServerCopy.rowValue,
                                 symbol: Symbol(SettingsCatalog.symbol(.crucibleServer)), accessory: .chevron)
            let connection = items.firstIndex { $0.id == SettingsCategory.connection.rawValue }.map { $0 + 1 } ?? items.count
            items.insert(server, at: connection)
        }
        rows.setItems(items)
        categoryList.sections = [SidebarView.Section(title: String(localized: "Settings"), items: items.map {
            SidebarView.Item(id: $0.id, title: $0.title, symbol: $0.symbol ?? "gearshape")
        })]
        if usesPanes, search.text.trimmingCharacters(in: .whitespaces).isEmpty {
            let wanted = paneID ?? Self.lastPaneID ?? items.first?.id
            if let wanted, items.contains(where: { $0.id == wanted }) {
                if pane == nil || paneID != wanted { showPane(wanted) } else { pane?.screenDidAppear() }
            }
        } else if usesPanes {
            pane?.screenDidAppear()
        }
        setNeedsLayout()
    }

    /// A category's value line: the desk's appearance, the route to the server as You shows it, or the catalogue's summary.
    private static func value(of category: SettingsCategory) -> String? {
        switch category {
        case .appearance: LinuxDisplay.summary
        case .connection: YouConnectionStatus.shared.state.routeSummary ?? SettingsCatalog.summary(of: category, on: .linux)
        default: SettingsCatalog.summary(of: category, on: .linux)
        }
    }

    /// The catalogue's categories for Linux, with Appearance in its place: the desk's own appearance, density and poster
    /// size live there, outside the shared catalogue.
    private static var categories: [SettingsCategory] { LinuxSettingsCatalog.categories }

    override func layoutSubviews() {
        page.topInset = Theme.current.metrics.tabBarClearance
        page.bottomInset = Theme.current.metrics.tv(60)
        if usesPanes, pane == nil, let first = Self.lastPaneID ?? rows.items.first?.id { showPane(first) }
        placePanes()
    }

    /// The search field and the list under it, beside the page, in the Desktop layout, or the one page of categories.
    private func placePanes() {
        page.isHidden = usesPanes
        categoryList.isHidden = !usesPanes
        search.isHidden = !usesPanes
        pane?.isHidden = !usesPanes
        guard usesPanes else {
            page.frame = bounds
            return
        }
        let metrics = Theme.current.metrics
        categoryList.preferredWidth = metrics.tv(560)
        let listWidth = categoryList.width
        let inset = metrics.tv(28)
        let fieldHeight = metrics.primaryControlHeight * 0.8
        search.frame = Rect(x: inset, y: metrics.tv(36), width: listWidth - inset * 2, height: fieldHeight)
        let top = search.frame.maxY + metrics.tv(12)
        categoryList.frame = Rect(x: 0, y: top, width: listWidth, height: max(bounds.height - top, 0))
        pane?.frame = Rect(x: listWidth, y: 0, width: max(bounds.width - listWidth, 0), height: bounds.height)
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

/// One category of settings, or the settings a search found, their rows grouped by section and ending with Restore
/// Defaults when any of a category's settings changed. In the Desktop layout each section is a card down the page's
/// leading side, a choice is made in place (its options side by side, or a pop-up button for a longer list), and a right
/// click on a row offers its options and Restore Default; on a couch a choice opens a menu of its options.
@MainActor
final class SettingsCategoryScreen: ScreenView {
    private enum Content {
        case category(SettingsCategory)
        case search(String)
    }

    private var content: Content
    private let api: APIClient
    private let page = PageView()
    private let title: ScreenTitleView
    private static let restoreID = "settings.restoreDefaults"
    private var headers: [ScreenTitleView] = []
    private var lists: [RowListView] = []
    private let restore = RowListView()
    private var rowsByID: [String: SettingsRow] = [:]
    /// The choice menu open over this screen, closed when the screen leaves so it never lingers over the next one.
    private weak var openMenu: MenuView?
    private weak var openContextMenu: ContextMenuView?

    init(category: SettingsCategory, api: APIClient) {
        content = .category(category)
        self.api = api
        title = ScreenTitleView(title: category.title(on: .linux), detail: category.explanation(on: .linux))
        super.init()
        setUp()
    }

    /// The settings matching `query`, by category.
    init(search query: String, api: APIClient) {
        content = .search(query)
        self.api = api
        title = ScreenTitleView(title: String(localized: "Search Settings"))
        super.init()
        setUp()
    }

    private func setUp() {
        addSubview(page)
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        restore.onSelect = { [weak self] _ in self?.confirmRestoreDefaults() }
        reload()
    }

    var isSearch: Bool {
        if case .search = content { return true }
        return false
    }

    /// Shows the matches for another `query` in place.
    func search(_ query: String) {
        content = .search(query)
        reload()
    }

    override var preferredFocusView: View? { lists.first { !$0.items.isEmpty } }

    override func screenDidAppear() {
        reload()
    }

    override func screenWillDisappear() {
        openMenu?.dismiss()
        openContextMenu?.dismiss()
    }

    private var isDesk: Bool { Theme.current.density == .desk }

    private var sections: [LinuxSettingsCatalog.Section] {
        switch content {
        case .category(let category): LinuxSettingsCatalog.sections(of: category)
        case .search(let query): LinuxSettingsCatalog.search(query)
        }
    }

    private func reload() {
        let metrics = Theme.current.metrics
        title.columnWidth = metrics.settingsColumn
        title.isLeadingAligned = isDesk
        if case .search(let query) = content {
            title.detail = sections.isEmpty
                ? String(localized: "Nothing in Settings matches “\(query)”.", comment: "Linux Settings search with no results, with what was typed")
                : nil
        }
        var views: [View] = [title]
        var used = 0
        rowsByID = [:]
        for section in sections {
            if let heading = section.title {
                let header = used < headers.count ? headers[used] : ScreenTitleView(title: "")
                if used >= headers.count { headers.append(header) }
                header.detail = heading.uppercased()
                header.columnWidth = metrics.settingsColumn
                header.isLeadingAligned = isDesk
                views.append(header)
            }
            let list = used < lists.count ? lists[used] : makeList()
            if used >= lists.count { lists.append(list) }
            used += 1
            list.isGrouped = isDesk
            list.isLeadingAligned = isDesk
            list.columnWidth = metrics.settingsColumn
            list.setItems(section.rows.map(item))
            for row in section.rows { rowsByID[row.id] = row }
            views.append(list)
        }
        for unused in lists.dropFirst(used) { unused.setItems([]) }
        if case .category = content, changedSettings.count > 0 {
            restore.setItems([RowItem(id: Self.restoreID, title: String(localized: "Restore Defaults", comment: "Button at the end of a settings category that resets its settings"),
                                      symbol: "arrow.counterclockwise")])
            restore.isLeadingAligned = isDesk
            restore.isGrouped = isDesk
            restore.columnWidth = metrics.settingsColumn
            views.append(restore)
        } else if restore.containsFocus, let first = lists.first {
            window?.focus.focus(first, animated: false)
        }
        page.setSections(views)
        setNeedsLayout()
    }

    private func makeList() -> RowListView {
        let list = RowListView()
        list.onSelect = { [weak self] item in self?.select(item.id, anchor: nil) }
        list.onChoose = { [weak self] item, index, anchor in self?.choose(item.id, index: index, anchor: anchor) }
        list.onContextMenu = { [weak self] item, anchor in self?.rowMenu(item.id, at: anchor) ?? false }
        return list
    }

    // MARK: Rows

    private func item(_ row: SettingsRow) -> RowItem {
        switch row {
        case .entry(let entry):
            return item(entry, explanation: row.explanation)
        case .linux(let setting):
            return item(id: row.id, title: setting.title, explanation: setting.explanation, symbol: setting.symbol, control: setting.control)
        case .titleRules:
            return RowItem(id: row.id, title: row.title, subtitle: row.explanation, value: TitleRulesCopy.listValue(TitleRulesStore.all().count),
                           symbol: "slider.horizontal.3", accessory: .chevron)
        }
    }

    private func item(id: String, title: String, explanation: String?, symbol: String, control: PreferenceSetting.Control) -> RowItem {
        switch control {
        case .toggle(let isOn):
            return .onOff(id: id, title: title, subtitle: explanation, isOn: isOn, symbol: Symbol(symbol))
        case .choice(let choices):
            return .choice(id: id, title: title, subtitle: explanation, options: choices.map(\.title), selected: choices.firstIndex(where: \.isSelected),
                           symbol: Symbol(symbol))
        }
    }

    private func item(_ entry: SettingsEntry, explanation: String?) -> RowItem {
        switch entry.item {
        case .preference(let setting):
            return item(id: entry.id, title: entry.title, explanation: explanation, symbol: entry.symbol, control: setting.control)
        case .action(let action):
            return RowItem(id: entry.id, title: entry.title, subtitle: explanation, symbol: Symbol(entry.symbol), isDestructive: action.needsConfirmation)
        case .destination(let destination):
            let opens = Self.opens(destination)
            return RowItem(id: entry.id, title: entry.title, subtitle: explanation, value: Self.value(of: destination), symbol: Symbol(entry.symbol),
                           accessory: opens ? .chevron : .none, isStatic: !opens, brand: Self.brand(of: destination))
        case .privacyStatement:
            return RowItem(id: entry.id, title: entry.title, subtitle: explanation, symbol: Symbol(entry.symbol), isStatic: true)
        }
    }

    /// A choice's options and how to pick one, for any row that is a choice.
    private func choices(of id: String) -> (title: String, choices: [SettingChoice], pick: (SettingChoice) -> Void)? {
        switch rowsByID[id] {
        case .entry(let entry)?:
            guard case .preference(let setting) = entry.item, case .choice(let choices) = setting.control else { return nil }
            return (entry.title, choices, { setting.select($0) })
        case .linux(let setting)?:
            guard case .choice(let choices) = setting.control else { return nil }
            return (setting.title, choices, { [weak self] in setting.select($0, in: self?.window) })
        default:
            return nil
        }
    }

    // MARK: Choosing

    /// Enter or a click on a row: a switch flips, a choice opens its options under the row's control, a page opens.
    private func select(_ id: String, anchor: Rect?) {
        guard let window, let row = rowsByID[id] else { return }
        let anchor = anchor ?? controlAnchor(for: id)
        switch row {
        case .titleRules:
            navigation?.push(TitleRulesListScreen(api: api))
        case .linux(let setting):
            if case .toggle(let isOn) = setting.control {
                setting.setOn(!isOn)
                reload()
            } else {
                presentChoices(id, anchor: anchor)
            }
        case .entry(let entry):
            switch entry.item {
            case .preference(let setting):
                if case .toggle(let isOn) = setting.control {
                    setting.setOn(!isOn)
                    reload()
                } else {
                    presentChoices(id, anchor: anchor)
                }
            case .action(let action):
                perform(action, anchor: window.focusedView?.frameInWindow ?? frameInWindow)
            case .destination(let destination):
                if let screen = screen(for: destination) { navigation?.push(screen) }
            case .privacyStatement:
                break
            }
        }
    }

    /// A click on a choice row's control: an option picks it at once, the pop-up button opens the options under it.
    private func choose(_ id: String, index: Int?, anchor: Rect) {
        guard let index else {
            presentChoices(id, anchor: anchor)
            return
        }
        guard let found = choices(of: id), found.choices.indices.contains(index), !found.choices[index].isSelected else { return }
        found.pick(found.choices[index])
        reload()
    }

    /// Where a row's options hang from when the keyboard opens them: under its control on a desk, under its trailing part
    /// on a couch.
    private func controlAnchor(for id: String) -> Rect {
        let frame = lists.lazy.compactMap { $0.row(id: id) }.first?.frameInWindow ?? window?.focusedView?.frameInWindow ?? frameInWindow
        let width = Theme.current.metrics.tv(isDesk ? 420 : 500)
        return isDesk ? Rect(x: frame.maxX - width - Theme.current.metrics.rowInset, y: frame.minY, width: width, height: frame.height)
            : Rect(x: frame.maxX - width, y: frame.maxY, width: 1, height: 1)
    }

    private func presentChoices(_ id: String, anchor: Rect) {
        guard let window, let found = choices(of: id) else { return }
        openMenu?.dismiss()
        let menu = MenuView(title: found.title, items: found.choices.map {
            MenuView.Item(id: String($0.id), title: $0.title, detail: $0.detail, isChecked: $0.isSelected)
        }, anchor: anchor)
        menu.onSelect = { [weak self] item in
            guard let choice = found.choices.first(where: { String($0.id) == item.id }) else { return }
            found.pick(choice)
            self?.reload()
        }
        openMenu = menu
        menu.present(in: window)
    }

    /// A right click on a row: a choice's options, then Restore Default while the setting differs from it.
    private func rowMenu(_ id: String, at anchor: Rect) -> Bool {
        guard let window, let row = rowsByID[id] else { return false }
        typealias Action = ContextMenuView.Action
        var entries: [ContextMenuView.Entry] = []
        if let found = choices(of: id) {
            entries += found.choices.map { choice in
                .action(Action(choice.title, detail: choice.detail, isChecked: choice.isSelected) { [weak self] in
                    found.pick(choice)
                    self?.reload()
                })
            }
        }
        if let restoring = restoreAction(for: row) {
            if !entries.isEmpty { entries.append(.separator) }
            entries.append(.action(Action(String(localized: "Restore Default", comment: "Menu action that puts one setting back to how Crucible starts out"),
                                          symbol: "arrow.counterclockwise") { [weak self] in
                restoring()
                self?.reload()
            }))
        }
        guard !entries.isEmpty else { return false }
        openContextMenu?.dismiss()
        let menu = ContextMenuView(at: anchor.origin, highlightingFirstRow: false) { entries }
        openContextMenu = menu
        menu.present(in: window)
        return true
    }

    /// Puts `row` back to how Crucible starts out, when it differs.
    private func restoreAction(for row: SettingsRow) -> (() -> Void)? {
        switch row {
        case .entry(let entry):
            guard case .preference(let setting) = entry.item, setting.isChanged else { return nil }
            return { setting.restoreDefault() }
        case .linux(let setting):
            guard setting.isChanged else { return nil }
            return { [weak self] in setting.restoreDefault(in: self?.window) }
        case .titleRules:
            return nil
        }
    }

    /// The settings of this category that differ from how Crucible starts out (the shows' own rules are theirs to keep).
    private var changedSettings: [SettingsRow] {
        sections.flatMap(\.rows).filter { restoreAction(for: $0) != nil }
    }

    /// The screen a destination row opens, where the Linux client has one.
    private func screen(for destination: SettingsDestination) -> ScreenView? {
        switch destination {
        case .homeRows: HomeRowsScreen()
        case .libraries: LibrariesScreen(api: api)
        case .incompatibleTitles: IncompatibleTitlesScreen(api: api)
        case .trakt: TraktSettingsScreen()
        case .seerr: SeerrSettingsScreen(api: api)
        case .liveTV: LivePlaylistsScreen(title: LiveTVCopy.title, showsDestinationToggle: true)
        case .serverConnection: ServerConnectionScreen()
        case .about: AboutScreen()
        case .diagnostics: DiagnosticsScreen()
        case .exactSkips: CrucibleServerScreen()
        default: nil
        }
    }

    /// Whether the Linux client has a screen for `destination`; the others show as plain text.
    private static func opens(_ destination: SettingsDestination) -> Bool {
        switch destination {
        case .homeRows, .libraries, .incompatibleTitles, .trakt, .seerr, .liveTV, .serverConnection, .about, .diagnostics, .exactSkips: true
        default: false
        }
    }

    /// The service's mark for an integration's row.
    private static func brand(of destination: SettingsDestination) -> String? {
        switch destination {
        case .trakt: "trakt"
        case .seerr: "seerr"
        default: nil
        }
    }

    /// The value line beside a destination row, as the Apple TV shows it.
    private static func value(of destination: SettingsDestination) -> String? {
        switch destination {
        case .homeRows: String(localized: "\(HomeLayout.visibleRows().count) rows", comment: "How many Home rows are on, e.g. 5 rows")
        case .libraries: LibrariesSettings.summary
        case .incompatibleTitles: IncompatibleTitles.count == 0 ? nil : IncompatibleCopy.count(IncompatibleTitles.count)
        case .trakt: TraktAccount.shared.rowStatus
        case .seerr: SeerrAccount.shared.connection?.displayName ?? String(localized: "Off", comment: "Integrations summary when nothing is connected")
        case .liveTV: LiveTVPreferences.showsDestination ? nil : String(localized: "Off", comment: "Integrations summary when nothing is connected")
        case .about: AppInfo.versionSummary
        default: nil
        }
    }

    /// Runs an action, after a confirmation when it cannot be undone, and says when it is done.
    private func perform(_ action: SettingsAction, anchor: Rect) {
        let run = { [weak self] in
            switch action {
            case .clearImageCache:
                try? FileManager.default.removeItem(at: LinuxSession.imageCacheDirectory)
                self?.window?.purgeImageMemory()
            case .clearSearchHistory:
                SearchRecentsStore.preferences.update { $0.clear() }
            case .forgetFinishedTitles:
                FinishedTitlesLedger.shared.reset()
            case .shareLogs:
                return
            }
            self?.reload()
            if let window = self?.window { AlertView.notice(title: String(localized: "Done", comment: "Alert after a settings action finished"), in: window) }
        }
        guard action.needsConfirmation, let window else {
            run()
            return
        }
        AlertView.confirm(title: action.confirmationTitle, message: action.confirmationMessage, confirm: action.confirmTitle, in: window, action: run)
    }

    private func confirmRestoreDefaults() {
        guard let window, case .category(let category) = content else { return }
        AlertView.confirm(title: String(localized: "Restore Defaults?", comment: "Confirmation title for resetting a settings category"),
                          message: String(localized: "Every setting in \(category.title(on: .linux)) goes back to how Crucible starts out.",
                                          comment: "Confirmation message for resetting a settings category"),
                          confirm: String(localized: "Restore", comment: "Button that confirms resetting a settings category"), in: window) { [weak self] in
            guard let self else { return }
            for row in self.changedSettings { self.restoreAction(for: row)?() }
            self.reload()
        }
    }

    override func layoutSubviews() {
        page.topInset = Theme.current.metrics.tabBarClearance
        page.bottomInset = Theme.current.metrics.tv(60)
        page.frame = bounds
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

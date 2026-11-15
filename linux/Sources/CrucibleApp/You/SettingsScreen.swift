import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// Settings: the shared catalogue's categories for this platform, each with its value line, opening a screen of rows
/// where a choice opens a menu of its options and a switch flips in place.
@MainActor
final class SettingsScreen: ScreenView {
    private let title = ScreenTitleView(title: String(localized: "Settings"))
    private let rows = RowListView()
    private let page = PageView()
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
        super.init()
        title.columnWidth = Theme.current.metrics.wideColumn
        addSubview(page)
        page.setSections([title, rows])
        rows.onSelect = { [weak self] item in
            guard let self else { return }
            if item.id == Self.ownModelID {
                self.navigation?.push(OwnModelSettingsScreen())
                return
            }
            guard let category = SettingsCategory(rawValue: item.id) else { return }
            if category == .appearance {
                self.navigation?.push(AppearanceSettingsScreen())
            } else {
                self.navigation?.push(SettingsCategoryScreen(category: category, api: self.api))
            }
        }
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
    }

    override var preferredFocusView: View? { rows }

    private static let ownModelID = "linux.ownModel"

    override func screenDidAppear() {
        var items = Self.categories.map { category in
            RowItem(id: category.rawValue, title: category.title(on: .linux), subtitle: category.explanation(on: .linux),
                    value: category == .appearance ? LinuxDisplay.summary : SettingsCatalog.summary(of: category, on: .linux), symbol: Symbol(category.symbol),
                    accessory: .chevron)
        }
        let ownModel = RowItem(id: Self.ownModelID, title: OwnModelCopy.title, subtitle: WatchCopy.title,
                               value: OwnModel.model ?? OwnModelCopy.notSet, symbol: "sparkles", accessory: .chevron)
        let after = items.firstIndex { $0.id == SettingsCategory.integrations.rawValue }.map { $0 + 1 } ?? items.count
        items.insert(ownModel, at: after)
        rows.setItems(items)
        setNeedsLayout()
    }

    /// The catalogue's categories for Linux, with Appearance in its place: the desk's own appearance, density and poster
    /// size live there, outside the shared catalogue.
    private static var categories: [SettingsCategory] {
        let listed = Set(SettingsCatalog.categories(on: .linux)).union([.appearance])
        return SettingsCategory.allCases.filter(listed.contains)
    }

    override func layoutSubviews() {
        page.topInset = Theme.current.metrics.tabBarClearance
        page.frame = bounds
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

/// One category of settings, its rows grouped by section, ending with Restore Defaults when any of its settings changed.
@MainActor
final class SettingsCategoryScreen: ScreenView {
    private let category: SettingsCategory
    private let api: APIClient
    private let page = PageView()
    private let title: ScreenTitleView
    private static let restoreID = "settings.restoreDefaults"
    private var lists: [RowListView] = []
    private let restore = RowListView()
    private var entries: [String: SettingsEntry] = [:]

    init(category: SettingsCategory, api: APIClient) {
        self.category = category
        self.api = api
        title = ScreenTitleView(title: category.title(on: .linux), detail: category.explanation(on: .linux))
        super.init()
        title.columnWidth = Theme.current.metrics.wideColumn
        addSubview(page)
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        restore.onSelect = { [weak self] _ in self?.confirmRestoreDefaults() }
        reload()
    }

    override var preferredFocusView: View? { lists.first }

    override func screenDidAppear() {
        reload()
    }

    private func reload() {
        var sections: [View] = [title]
        var used = 0
        for group in SettingsCatalog.sections(of: category, on: .linux) {
            if let heading = group.title {
                let header = ScreenTitleView(title: "", detail: heading.uppercased())
                header.columnWidth = Theme.current.metrics.wideColumn
                sections.append(header)
            }
            let list = used < lists.count ? lists[used] : RowListView()
            if used >= lists.count {
                list.onSelect = { [weak self] item in self?.select(item.id) }
                lists.append(list)
            }
            used += 1
            list.setItems(group.entries.map(row))
            for entry in group.entries { entries[entry.id] = entry }
            sections.append(list)
        }
        if SettingsCatalog.preferences(in: category, on: .linux).contains(where: \.isChanged) {
            restore.setItems([RowItem(id: Self.restoreID, title: String(localized: "Restore Defaults", comment: "Button at the end of a settings category that resets its settings"),
                                      symbol: "arrow.counterclockwise")])
            sections.append(restore)
        } else if restore.containsFocus, let first = lists.first {
            window?.focus.focus(first, animated: false)
        }
        page.setSections(sections)
        setNeedsLayout()
    }

    private func row(_ entry: SettingsEntry) -> RowItem {
        switch entry.item {
        case .preference(let setting):
            switch setting.control {
            case .toggle(let isOn):
                return RowItem(id: entry.id, title: entry.title, subtitle: entry.explanation,
                               value: isOn ? String(localized: "On") : String(localized: "Off"), symbol: Symbol(entry.symbol))
            case .choice:
                return RowItem(id: entry.id, title: entry.title, subtitle: entry.explanation, value: setting.valueLabel, symbol: Symbol(entry.symbol),
                               accessory: .chevron)
            }
        case .action(let action):
            return RowItem(id: entry.id, title: entry.title, subtitle: entry.explanation, symbol: Symbol(entry.symbol),
                           isDestructive: action.needsConfirmation)
        case .destination(let destination):
            let opens = Self.opens(destination)
            return RowItem(id: entry.id, title: entry.title, subtitle: entry.explanation, value: Self.value(of: destination), symbol: Symbol(entry.symbol),
                           accessory: opens ? .chevron : .none, isStatic: !opens, brand: Self.brand(of: destination))
        case .privacyStatement:
            return RowItem(id: entry.id, title: entry.title, subtitle: entry.explanation, symbol: Symbol(entry.symbol), isStatic: true)
        }
    }

    private func select(_ id: String) {
        guard let entry = entries[id], let window else { return }
        switch entry.item {
        case .preference(let setting):
            switch setting.control {
            case .toggle(let isOn):
                setting.setOn(!isOn)
                reload()
            case .choice(let choices):
                let anchor = window.focusedView?.frameInWindow ?? frameInWindow
                let menu = MenuView(title: entry.title, items: choices.map {
                    MenuView.Item(id: String($0.id), title: $0.title, detail: $0.detail, isChecked: $0.isSelected)
                }, anchor: Rect(x: anchor.maxX - Theme.current.metrics.tv(500), y: anchor.maxY, width: 1, height: 1))
                menu.onSelect = { [weak self] item in
                    guard let choice = choices.first(where: { String($0.id) == item.id }) else { return }
                    setting.select(choice)
                    self?.reload()
                }
                menu.present(in: window)
            }
        case .action(let action):
            perform(action, anchor: window.focusedView?.frameInWindow ?? frameInWindow)
        case .destination(let destination):
            if let screen = screen(for: destination) { navigation?.push(screen) }
        default:
            break
        }
    }

    /// The screen a destination row opens, where the Linux client has one.
    private func screen(for destination: SettingsDestination) -> ScreenView? {
        switch destination {
        case .homeRows: HomeRowsScreen()
        case .libraries: LibrariesScreen(api: api)
        case .trakt: TraktSettingsScreen()
        case .seerr: SeerrSettingsScreen(api: api)
        case .serverConnection: ServerConnectionScreen()
        case .about: AboutScreen()
        case .diagnostics: DiagnosticsScreen()
        default: nil
        }
    }

    /// Whether the Linux client has a screen for `destination`; the others show as plain text.
    private static func opens(_ destination: SettingsDestination) -> Bool {
        switch destination {
        case .homeRows, .libraries, .trakt, .seerr, .serverConnection, .about, .diagnostics: true
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
        case .trakt: TraktAccount.shared.rowStatus
        case .seerr: SeerrAccount.shared.connection?.displayName ?? String(localized: "Off", comment: "Integrations summary when nothing is connected")
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
        guard let window else { return }
        AlertView.confirm(title: String(localized: "Restore Defaults?", comment: "Confirmation title for resetting a settings category"),
                          message: String(localized: "Every setting in \(category.title(on: .linux)) goes back to how Crucible starts out.",
                                          comment: "Confirmation message for resetting a settings category"),
                          confirm: String(localized: "Restore", comment: "Button that confirms resetting a settings category"), in: window) { [weak self] in
            guard let self else { return }
            for setting in SettingsCatalog.preferences(in: self.category, on: .linux) where setting.isChanged {
                setting.restoreDefault()
            }
            self.reload()
        }
    }

    override func layoutSubviews() {
        page.topInset = Theme.current.metrics.tabBarClearance
        page.frame = bounds
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

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
            guard let self, let category = SettingsCategory(rawValue: item.id) else { return }
            self.navigation?.push(SettingsCategoryScreen(category: category, api: self.api))
        }
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
    }

    override var preferredFocusView: View? { rows }

    override func screenDidAppear() {
        rows.setItems(SettingsCatalog.categories(on: .linux).map { category in
            RowItem(id: category.rawValue, title: category.title(on: .linux), subtitle: category.explanation(on: .linux),
                    value: SettingsCatalog.summary(of: category, on: .linux), symbol: Symbol(category.symbol), accessory: .chevron)
        })
        setNeedsLayout()
    }

    override func layoutSubviews() {
        page.topInset = Theme.current.metrics.tabBarClearance
        page.frame = bounds
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

/// One category of settings, its rows grouped by section.
@MainActor
final class SettingsCategoryScreen: ScreenView {
    private let category: SettingsCategory
    private let api: APIClient
    private let page = PageView()
    private let title: ScreenTitleView
    private var lists: [RowListView] = []
    private var entries: [String: SettingsEntry] = [:]

    init(category: SettingsCategory, api: APIClient) {
        self.category = category
        self.api = api
        title = ScreenTitleView(title: category.title(on: .linux), detail: category.explanation(on: .linux))
        super.init()
        title.columnWidth = Theme.current.metrics.wideColumn
        addSubview(page)
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        reload()
    }

    override var preferredFocusView: View? { lists.first }

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
            return RowItem(id: entry.id, title: entry.title, subtitle: entry.explanation, symbol: Symbol(entry.symbol),
                           accessory: Self.screen(for: destination) == nil ? .none : .chevron, isStatic: Self.screen(for: destination) == nil)
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
            if let screen = Self.screen(for: destination) { navigation?.push(screen) }
        default:
            break
        }
    }

    /// The screen a destination row opens, where the Linux client has one.
    private static func screen(for destination: SettingsDestination) -> ScreenView? {
        switch destination {
        case .serverConnection: ServerConnectionScreen()
        case .about: AboutScreen()
        case .diagnostics: DiagnosticsScreen()
        default: nil
        }
    }

    /// Runs an action, after a confirmation menu when it cannot be undone.
    private func perform(_ action: SettingsAction, anchor: Rect) {
        let run = { [weak self] in
            switch action {
            case .clearImageCache:
                try? FileManager.default.removeItem(at: LinuxSession.imageCacheDirectory)
            case .clearSearchHistory:
                SearchRecentsStore.preferences.update { $0.clear() }
            case .forgetFinishedTitles, .shareLogs:
                break
            }
            self?.reload()
        }
        guard action.needsConfirmation, let window else {
            run()
            return
        }
        let menu = MenuView(title: action.confirmationTitle + " " + action.confirmationMessage, items: [
            .init(id: "confirm", title: action.confirmTitle, isDestructive: true),
            .init(id: "cancel", title: String(localized: "Cancel")),
        ], anchor: Rect(x: anchor.minX, y: anchor.maxY, width: 1, height: 1))
        menu.onSelect = { item in if item.id == "confirm" { run() } }
        menu.present(in: window)
    }

    override func layoutSubviews() {
        page.topInset = Theme.current.metrics.tabBarClearance
        page.frame = bounds
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

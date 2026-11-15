import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// Home's rows in the order Home draws them (`TVHomeRowsViewController`): Select turns a row on or off, its menu
/// (right-click or the Menu key) or Alt+Up and Alt+Down move it, and Reset Order puts every row back on in the default order.
@MainActor
final class HomeRowsScreen: SettingsScaffold {
    private static let resetID = "homeRows.reset"
    private static let prefix = "homeRows."

    private static let moving = String(localized: "Right-click a row or press the Menu key to move it, or use Alt+Up and Alt+Down.",
                                       comment: "How to reorder Home rows with a mouse or keyboard on Linux")
    private static var intro: String { "\(SettingsCatalog.explanation(.homeRows) ?? "")\n\(moving)" }

    init() {
        super.init(title: SettingsCatalog.title(.homeRows), detail: Self.intro)
        rows.onContextMenu = { [weak self] item, anchor in self?.presentMoves(for: item.id, anchor: anchor) ?? false }
        refreshRows()
    }

    override func screenDidAppear() {
        refreshRows()
    }

    override func rowSelected(_ id: String) {
        if id == Self.resetID {
            HomeLayout.reset()
        } else if let row = Self.row(for: id) {
            HomeLayout.setOn(row, !HomeLayout.isOn(row))
        }
        refreshRows()
    }

    /// The heading explains the focused row, keeping the way to move it underneath; focus leaving for a menu changes nothing.
    override func descendantFocusDidChange(to view: View?) {
        guard let view, view.isDescendant(of: self) else { return }
        let focused = view.enclosing(RowView.self).flatMap { Self.row(for: $0.item.id) }
        heading.detail = focused.map { "\($0.explanation)\n\(Self.moving)" } ?? Self.intro
    }

    override func keyPressed(_ event: KeyEvent) -> Bool {
        guard event.modifiers == .alt, event.key == .up || event.key == .down,
              let id = window?.focusedView?.enclosing(RowView.self)?.item.id else { return super.keyPressed(event) }
        move(id, by: event.key == .up ? -1 : 1)
        return true
    }

    /// Move Up and Move Down for the row `id`, whichever apply; nothing for Reset Order.
    private func presentMoves(for id: String, anchor: Rect) -> Bool {
        guard let window, let row = Self.row(for: id), let index = HomeLayout.entries().firstIndex(where: { $0.row == row }) else { return false }
        var items: [MenuView.Item] = []
        if index > 0 {
            items.append(MenuView.Item(id: "up", title: String(localized: "Move Up", comment: "Menu item that moves a Home row up"),
                                       detail: String(localized: "Alt+Up", comment: "Keyboard shortcut for Move Up"), symbol: "arrow.up"))
        }
        if index < HomeLayout.entries().count - 1 {
            items.append(MenuView.Item(id: "down", title: String(localized: "Move Down", comment: "Menu item that moves a Home row down"),
                                       detail: String(localized: "Alt+Down", comment: "Keyboard shortcut for Move Down"), symbol: "arrow.down"))
        }
        let menu = MenuView(title: row.title, items: items, anchor: anchor)
        menu.onSelect = { [weak self] chosen in self?.move(id, by: chosen.id == "up" ? -1 : 1) }
        menu.present(in: window)
        return true
    }

    /// Moves the row `id` one place up (`-1`) or down (`1`), keeping focus on it.
    private func move(_ id: String, by offset: Int) {
        guard let row = Self.row(for: id), let index = HomeLayout.entries().firstIndex(where: { $0.row == row }) else { return }
        let target = index + offset
        guard HomeLayout.entries().indices.contains(target) else { return }
        HomeLayout.move(from: index, to: target)
        refreshRows()
    }

    private func refreshRows() {
        let items = HomeLayout.entries().map { entry in
            RowItem(id: Self.prefix + entry.row.rawValue, title: entry.row.title,
                    value: entry.isOn ? String(localized: "On") : String(localized: "Off"), symbol: Symbol(entry.row.symbol))
        }
        setRows(items + [RowItem(id: Self.resetID, title: String(localized: "Reset Order", comment: "Row that puts Home's rows back in their default order and turns them all on"),
                                 symbol: "arrow.counterclockwise")])
    }

    private static func row(for id: String) -> HomeRow? {
        id.hasPrefix(prefix) ? HomeRow(rawValue: String(id.dropFirst(prefix.count))) : nil
    }
}

/// Which libraries count toward Home, search, suggestions and Statistics (`TVLibrariesSettingsViewController`): Select
/// flips a library between On and Off, the last one on stays locked, and a reset row appears once anything differs from
/// what Plex says.
@MainActor
final class LibrariesScreen: SettingsScaffold {
    private static let resetID = "libraries.reset"
    private static let prefix = "library."

    private let api: APIClient
    private let state = StateView()
    private var observer: UUID?
    private var loadTask: Task<Void, Never>?

    init(api: APIClient) {
        self.api = api
        super.init(title: String(localized: "Libraries"),
                   detail: String(localized: "\(LibrariesSettings.footerText) Every library keeps its tab."))
        addSubview(state)
        state.isHidden = true
        render()
    }

    override var preferredFocusView: View? { state.isHidden ? rows : state }

    override func screenDidAppear() {
        if observer == nil { observer = LibraryVisibility.addObserver { [weak self] in self?.render() } }
        load()
    }

    override func screenWillDisappear() {
        loadTask?.cancel()
        loadTask = nil
        if let observer { LibraryVisibility.removeObserver(observer) }
        observer = nil
    }

    override func rowSelected(_ id: String) {
        if id == Self.resetID {
            LibraryVisibility.resetToPlexDefaults()
            return
        }
        guard id.hasPrefix(Self.prefix), let libraryID = Int(id.dropFirst(Self.prefix.count)),
              let row = LibrariesSettings.row(id: libraryID), !row.isLocked else { return }
        LibraryVisibility.setIncluded(libraryID, !row.isIncluded)
    }

    /// Fetches the server's libraries; the rows already known stay up meanwhile, and only an empty list waits on a spinner.
    private func load() {
        if LibrariesSettings.isLoading { show(.loading(title: LibrariesSettings.loadingTitle)) }
        loadTask?.cancel()
        let api = api
        loadTask = Task { [weak self] in
            await LibrariesSettings.refresh(api: api)
            guard !Task.isCancelled else { return }
            self?.render(afterLoad: true)
        }
    }

    private func render(afterLoad: Bool = false) {
        guard !LibrariesSettings.isLoading else {
            if afterLoad {
                show(.error(title: String(localized: "Couldn’t Load Libraries"),
                            message: String(localized: "Check the connection to your server and try again."),
                            retryTitle: String(localized: "Try Again"),
                            retry: { [weak self] in self?.load() }))
            }
            return
        }
        var items = LibrariesSettings.rows.map { row in
            RowItem(id: "\(Self.prefix)\(row.id)", title: row.title, subtitle: row.subtitle,
                    value: row.isIncluded ? String(localized: "On", comment: "Library is included in the tabs") : String(localized: "Off", comment: "Library is excluded from the tabs"),
                    symbol: Symbol(row.symbol), isEnabled: !row.isLocked)
        }
        if LibrariesSettings.canReset {
            items.append(RowItem(id: Self.resetID, title: LibrariesSettings.resetTitle, symbol: "arrow.counterclockwise"))
        }
        setRows(items)
        let hadStateFocus = state.containsFocus
        state.isHidden = true
        rows.isHidden = false
        if hadStateFocus { window?.focus.focus(rows, animated: false) }
    }

    private func show(_ newState: StateView.State) {
        let hadFocus = rows.containsFocus
        state.show(newState)
        state.isHidden = false
        rows.isHidden = true
        if hadFocus || window?.focusedView == nil { window?.focus.focus(state, animated: false) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        state.frame = bounds
    }
}

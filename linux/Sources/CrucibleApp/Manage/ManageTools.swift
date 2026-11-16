import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// The server owner's tools (`TVManageMenus`): a title's Manage menu (refresh, analyze, Fix Match, Unmatch, Show Settings,
/// Edit Details, the poster and background pickers, delete) and a library's (scan, refresh, analyze, empty the trash).
/// Nobody else sees them: the server would refuse them anyway.
@MainActor
enum ManageTools {
    /// Whether `item` has a Manage menu for the signed-in account.
    static func offers(_ item: PlexMetadata) -> Bool {
        ServerOwnership.isOwner() && ["movie", "show", "season", "episode"].contains(item.mediaType)
    }

    /// A title's tools as menu items and what choosing one does. `leavesScreenWhenDeleted` is for a title's own page, which
    /// has nothing left to show once the title is gone; a list just reloads.
    static func itemMenu(for item: PlexMetadata, api: APIClient, host: View, leavesScreenWhenDeleted: Bool = false,
                         reload: @escaping () -> Void) -> (items: [MenuView.Item], choose: (MenuView.Item) -> Void) {
        let key = item.id
        var items = [
            MenuView.Item(id: "refresh", title: ManageCopy.refreshMetadata, symbol: "arrow.clockwise"),
            MenuView.Item(id: "analyze", title: ManageCopy.analyze, symbol: "waveform.badge.magnifyingglass"),
        ]
        if item.mediaType == "movie" || item.mediaType == "show" {
            items.append(MenuView.Item(id: "fixMatch", title: ManageCopy.fixMatch, symbol: "link"))
            items.append(MenuView.Item(id: "unmatch", title: ManageCopy.unmatch, symbol: "minus.circle"))
        }
        if item.mediaType == "show" {
            items.append(MenuView.Item(id: "showSettings", title: ManageCopy.showSettings, symbol: "slider.horizontal.3"))
        }
        let section = item.librarySectionID.map(String.init)
        if section != nil {
            items.append(MenuView.Item(id: "edit", title: ManageCopy.editDetails, symbol: "pencil"))
        }
        items.append(MenuView.Item(id: "poster", title: CrucibleCore.ArtworkKind.poster.chooseTitle, symbol: "photo.on.rectangle"))
        items.append(MenuView.Item(id: "background", title: CrucibleCore.ArtworkKind.background.chooseTitle, symbol: "photo"))
        items.append(MenuView.Item(id: "delete", title: ManageCopy.delete, symbol: "trash", isDestructive: true))
        let choose: (MenuView.Item) -> Void = { [weak host] chosen in
            guard let host else { return }
            switch chosen.id {
            case "refresh":
                run(in: host, reloadAfter: .seconds(3), reload: reload) { try await LibraryManagement.refresh(ratingKey: key, api: api) }
            case "analyze":
                run(in: host, reloadAfter: .seconds(3), reload: reload) { try await LibraryManagement.analyze(ratingKey: key, api: api) }
            case "fixMatch":
                host.rootView?.push(FixMatchScreen(item: item, api: api, onMatched: reload))
            case "unmatch":
                run(in: host, reloadAfter: .seconds(2), reload: reload) { try await LibraryManagement.unmatch(ratingKey: key, api: api) }
            case "showSettings":
                host.rootView?.push(ShowSettingsScreen(ratingKey: key, api: api))
            case "edit":
                if let section { host.rootView?.push(EditDetailsScreen(edit: MetadataEdit(item: item, sectionId: section), api: api, onSaved: reload)) }
            case "poster":
                host.rootView?.push(artworkPicker(ratingKey: key, kind: .poster, api: api, onChosen: reload))
            case "background":
                host.rootView?.push(artworkPicker(ratingKey: key, kind: .background, api: api, onChosen: reload))
            case "delete":
                confirmDelete(item, api: api, host: host, leavesScreen: leavesScreenWhenDeleted, reload: reload)
            default:
                break
            }
        }
        return (items, choose)
    }

    /// Opens a title's Manage menu at `anchor`.
    static func presentItemMenu(for item: PlexMetadata, api: APIClient, host: View, anchor: Rect, leavesScreenWhenDeleted: Bool = false,
                                reload: @escaping () -> Void) {
        guard let window = host.window else { return }
        let tools = itemMenu(for: item, api: api, host: host, leavesScreenWhenDeleted: leavesScreenWhenDeleted, reload: reload)
        let menu = MenuView(title: ManageCopy.menuTitle, items: tools.items, anchor: anchor)
        menu.onSelect = tools.choose
        menu.present(in: window)
    }

    private static func confirmDelete(_ item: PlexMetadata, api: APIClient, host: View, leavesScreen: Bool, reload: @escaping () -> Void) {
        guard let window = host.window else { return }
        let key = item.id
        AlertView.confirm(title: ManageCopy.delete, message: ManageCopy.deleteMessage(item.title),
                          confirm: String(localized: "Delete", comment: "Button that confirms deleting a title from the server"), in: window) { [weak host] in
            guard let host else { return }
            guard leavesScreen else {
                run(in: host, reloadAfter: .zero, reload: reload) { try await LibraryManagement.delete(ratingKey: key, api: api) }
                return
            }
            Task { [weak host] in
                do {
                    try await LibraryManagement.delete(ratingKey: key, api: api)
                    _ = host?.enclosing(ScreenView.self)?.navigation?.pop()
                } catch {
                    if let window = host?.window { AlertView.notice(title: ManageCopy.failed, message: ConnectionError.message(for: error), in: window) }
                }
            }
        }
    }

    /// Scan, refresh (confirmed), analyze and empty the trash (confirmed) of a library.
    static func presentLibraryMenu(sectionId: String, api: APIClient, host: View, anchor: Rect) {
        guard ServerOwnership.isOwner(), let window = host.window else { return }
        let menu = MenuView(title: ManageCopy.menuTitle, items: [
            MenuView.Item(id: "scan", title: ManageCopy.scanLibrary, symbol: "arrow.triangle.2.circlepath"),
            MenuView.Item(id: "refresh", title: ManageCopy.refreshLibrary, symbol: "arrow.clockwise"),
            MenuView.Item(id: "analyze", title: ManageCopy.analyzeLibrary, symbol: "waveform.badge.magnifyingglass"),
            MenuView.Item(id: "trash", title: ManageCopy.emptyTrash, symbol: "trash", isDestructive: true),
        ], anchor: anchor)
        menu.onSelect = { [weak host] chosen in
            guard let host, let window = host.window else { return }
            switch chosen.id {
            case "scan":
                run(in: host) { try await LibraryManagement.scan(sectionId: sectionId, force: false, api: api) }
            case "refresh":
                AlertView.confirm(title: ManageCopy.refreshLibrary, message: ManageCopy.refreshLibraryMessage, confirm: ManageCopy.refreshLibrary,
                                  role: .normal, in: window) { [weak host] in
                    guard let host else { return }
                    run(in: host) { try await LibraryManagement.scan(sectionId: sectionId, force: true, api: api) }
                }
            case "analyze":
                run(in: host) { try await LibraryManagement.analyze(sectionId: sectionId, api: api) }
            case "trash":
                AlertView.confirm(title: ManageCopy.emptyTrash, message: ManageCopy.emptyTrashMessage, confirm: ManageCopy.emptyTrash, in: window) { [weak host] in
                    guard let host else { return }
                    run(in: host) { try await LibraryManagement.emptyTrash(sectionId: sectionId, api: api) }
                }
            default:
                break
            }
        }
        menu.present(in: window)
    }

    /// The poster or background picker: every picture the server's agents and the owner's uploads offer, the one in use
    /// captioned so. Picking another makes it the title's artwork and goes back.
    static func artworkPicker(ratingKey: String, kind: CrucibleCore.ArtworkKind, api: APIClient, onChosen: @escaping () -> Void) -> ArtworkPickerScreen {
        ArtworkPickerScreen(ratingKey: ratingKey, kind: kind, api: api, onChosen: onChosen)
    }

    /// Sends a tool to the server: an alert says it went or that the server refused it, and the screen reloads once the server
    /// has had a moment to do it.
    static func run(in host: View, reloadAfter delay: Duration? = nil, reload: (() -> Void)? = nil, _ work: @escaping () async throws -> Void) {
        Task { [weak host] in
            do {
                try await work()
                if let window = host?.window { AlertView.notice(title: ManageCopy.done, in: window) }
                if let delay, let reload {
                    try? await Task.sleep(for: delay)
                    reload()
                }
            } catch {
                if let window = host?.window { AlertView.notice(title: ManageCopy.failed, message: ConnectionError.message(for: error), in: window) }
            }
        }
    }
}

/// Choose Poster and Choose Background: a grid of every picture on offer, the one in use captioned In Use.
@MainActor
final class ArtworkPickerScreen: ScreenView {
    private let ratingKey: String
    private let kind: CrucibleCore.ArtworkKind
    private let api: APIClient
    private let onChosen: () -> Void
    private let page = PageView()
    private let heading: ScreenTitleView
    private let grid = CardGridView()
    private let state = StateView()
    private var choices: [String: PlexArtworkChoice] = [:]
    private var loadTask: Task<Void, Never>?

    init(ratingKey: String, kind: CrucibleCore.ArtworkKind, api: APIClient, onChosen: @escaping () -> Void) {
        self.ratingKey = ratingKey
        self.kind = kind
        self.api = api
        self.onChosen = onChosen
        heading = ScreenTitleView(title: kind == .poster ? String(localized: "Choose Poster", comment: "Title of the poster picker")
                                                       : String(localized: "Choose Background", comment: "Title of the background picker"))
        super.init()
        [page, state].forEach(addSubview)
        page.setSections([heading, grid])
        grid.aspect = kind == .poster ? 1.5 : 9 / 16
        grid.onActivate = { [weak self] card in self?.choose(card.id) }
        state.show(.loading(title: nil))
    }

    override var preferredFocusView: View? { state.isHidden ? grid : state }

    override func screenDidAppear() {
        guard choices.isEmpty else { return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await LibraryManagement.artwork(ratingKey: self.ratingKey, kind: self.kind, api: self.api)
                guard !Task.isCancelled else { return }
                self.show(loaded)
            } catch {
                guard !Task.isCancelled else { return }
                self.state.show(.error(title: ManageCopy.failed, message: ConnectionError.message(for: error), retryTitle: String(localized: "Try Again"),
                                       retry: { [weak self] in
                                           self?.choices = [:]
                                           self?.state.show(.loading(title: nil))
                                           self?.screenDidAppear()
                                       }))
            }
        }
    }

    override func screenWillDisappear() {
        loadTask?.cancel()
    }

    private func show(_ loaded: [PlexArtworkChoice]) {
        choices = Dictionary(loaded.map { ($0.ratingKey, $0) }, uniquingKeysWith: { first, _ in first })
        guard !loaded.isEmpty else {
            state.show(.empty(title: String(localized: "Nothing to Choose From", comment: "Artwork picker empty state"), message: nil, symbol: "photo", action: nil))
            return
        }
        let inUse = String(localized: "In Use", comment: "Caption of the artwork a title uses now")
        grid.setItems(loaded.map { choice in
            CardItem(id: choice.ratingKey, artwork: choice.imagePath.map { .path($0, kind == .poster ? .poster : .backdrop) },
                     title: choice.selected == true ? inUse : (choice.provider ?? ""), placeholderSymbol: "photo")
        })
        let hadFocus = state.containsFocus
        state.isHidden = true
        if hadFocus { window?.focus.focus(grid, animated: false) }
        page.setNeedsLayout()
    }

    private func choose(_ id: String) {
        guard let choice = choices[id], choice.selected != true else { return }
        let api = api
        let key = ratingKey
        let kind = kind
        let onChosen = onChosen
        Task { [weak self] in
            do {
                try await LibraryManagement.select(choice, kind: kind, ratingKey: key, api: api)
                _ = self?.navigation?.pop()
                onChosen()
            } catch {
                if let window = self?.window { AlertView.notice(title: ManageCopy.failed, message: ConnectionError.message(for: error), in: window) }
            }
        }
    }

    override func layoutSubviews() {
        page.topInset = Theme.current.metrics.tabBarClearance
        page.frame = bounds
        state.frame = bounds
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

/// Fix Match (`TVFixMatchViewController`): the server's agents searched for the right movie or show, starting from the title
/// as it is; the one picked is matched. The first row edits the search, and a year typed after the name narrows it.
@MainActor
final class FixMatchScreen: SettingsScaffold {
    private static let searchID = "fixMatch.search"
    private static let retryID = "fixMatch.retry"
    private static let resultPrefix = "fixMatch.result."

    private let item: PlexMetadata
    private let api: APIClient
    private let onMatched: () -> Void
    private var query: String
    private var results: [PlexMatchResult] = []
    private var failure: String?
    private var isSearching = true
    private var searchTask: Task<Void, Never>?

    init(item: PlexMetadata, api: APIClient, onMatched: @escaping () -> Void) {
        self.item = item
        self.api = api
        self.onMatched = onMatched
        query = MatchQuery.text(for: item)
        super.init(title: String(localized: "Fix Match", comment: "Title of the Fix Match screen"),
                   detail: String(localized: "Pick the right movie or show for \(item.title).", comment: "Fix Match explanation, e.g. Pick the right movie or show for Dune."))
        render()
        search()
    }

    override func screenWillDisappear() {
        searchTask?.cancel()
    }

    override func rowSelected(_ id: String) {
        switch id {
        case Self.searchID:
            guard let window else { return }
            weak var alert: AlertView?
            let shown = AlertView(title: String(localized: "Title and year", comment: "Placeholder of the Fix Match search field"), actions: [
                AlertView.Action(String(localized: "Search", comment: "Button that runs a search")) { [weak self] in
                    self?.query = alert?.text ?? ""
                    self?.search()
                },
                AlertView.Action(String(localized: "Cancel"), role: .cancel),
            ], fieldPlaceholder: String(localized: "Title and year", comment: "Placeholder of the Fix Match search field"), fieldText: query)
            alert = shown
            shown.present(in: window)
        case Self.retryID:
            search()
        default:
            guard let result = results.first(where: { Self.resultPrefix + $0.guid == id }) else { return }
            confirm(result)
        }
    }

    private func search() {
        let parsed = MatchQuery(parsing: query)
        isSearching = true
        failure = nil
        render()
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await LibraryManagement.matches(ratingKey: self.item.id, title: parsed.name, year: parsed.year, api: self.api)
                guard !Task.isCancelled else { return }
                self.results = found
            } catch {
                guard !Task.isCancelled else { return }
                MidgarLog.error("Fix Match search failed for \(self.item.id): \(error)", category: .networking)
                self.results = []
                self.failure = ConnectionError.message(for: error)
            }
            self.isSearching = false
            self.render()
        }
    }

    private func confirm(_ result: PlexMatchResult) {
        guard let window else { return }
        let name = Self.name(result)
        let api = api
        let key = item.id
        let onMatched = onMatched
        AlertView.confirm(title: String(localized: "Match to \(name)?", comment: "Fix Match confirmation title, e.g. Match to Dune (2021)?"),
                          message: String(localized: "The title takes this one's details, artwork and ratings.", comment: "Fix Match confirmation message"),
                          confirm: String(localized: "Match", comment: "Button that confirms a Fix Match choice"), role: .normal, in: window) { [weak self] in
            Task { [weak self] in
                do {
                    try await LibraryManagement.match(ratingKey: key, to: result, api: api)
                    _ = self?.navigation?.pop()
                    try? await Task.sleep(for: .seconds(2))
                    onMatched()
                } catch {
                    if let window = self?.window { AlertView.notice(title: ManageCopy.failed, message: ConnectionError.message(for: error), in: window) }
                }
            }
        }
    }

    private func render() {
        var items = [RowItem(id: Self.searchID, title: String(localized: "Search", comment: "Button that runs a search"), value: query, symbol: "magnifyingglass")]
        if isSearching {
            items.append(RowItem(id: "fixMatch.searching", title: String(localized: "Searching…", comment: "Fix Match status while the server's agents are searched"),
                                 symbol: "hourglass", isStatic: true))
        } else if let failure {
            items.append(RowItem(id: "fixMatch.failed", title: ManageCopy.failed, subtitle: failure, symbol: "exclamationmark.triangle", isStatic: true))
            items.append(RowItem(id: Self.retryID, title: String(localized: "Try Again"), symbol: "arrow.clockwise"))
        } else if results.isEmpty {
            items.append(RowItem(id: "fixMatch.none", title: String(localized: "No Matches", comment: "Fix Match empty state title"),
                                 subtitle: String(localized: "Try the original title, or add the year.", comment: "Fix Match empty state message"),
                                 symbol: "film", isStatic: true))
        } else {
            items += results.map { result in
                RowItem(id: Self.resultPrefix + result.guid, title: Self.name(result),
                        value: result.score.map { String(localized: "\($0)% match", comment: "How sure the server's agent is of a Fix Match result, e.g. 92% match") },
                        symbol: "film", accessory: result.matched == true ? .checkmark : .none)
            }
        }
        setRows(items)
    }

    private static func name(_ result: PlexMatchResult) -> String {
        [result.name, result.year.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    }
}

/// Edit Details (`TVEditDetailsViewController`): a title's name, sort name, original name, year (for a movie) and summary,
/// each typed in a field. Save sends only what changed and locks it, so the server's next refresh keeps the owner's words.
@MainActor
final class EditDetailsScreen: SettingsScaffold {
    private enum Field: String, CaseIterable {
        case title, sortTitle, originalTitle, year, summary

        var label: String {
            switch self {
            case .title: String(localized: "Title", comment: "Edit Details field")
            case .sortTitle: String(localized: "Sort Title", comment: "Edit Details field: the name the title is sorted by")
            case .originalTitle: String(localized: "Original Title", comment: "Edit Details field")
            case .year: String(localized: "Year", comment: "Edit Details field")
            case .summary: String(localized: "Summary", comment: "Edit Details field")
            }
        }

        var symbol: Symbol {
            switch self {
            case .title: "textformat"
            case .sortTitle: "arrow.up.arrow.down"
            case .originalTitle: "globe"
            case .year: "calendar"
            case .summary: "text.alignleft"
            }
        }
    }

    private static let saveID = "editDetails.save"
    private var edit: MetadataEdit
    private let api: APIClient
    private let onSaved: () -> Void

    init(edit: MetadataEdit, api: APIClient, onSaved: @escaping () -> Void) {
        self.edit = edit
        self.api = api
        self.onSaved = onSaved
        super.init(title: String(localized: "Edit Details", comment: "Title of the Edit Details screen"),
                   detail: String(localized: "Saved fields are locked, so the server keeps them when it refreshes the title.", comment: "Note under the Edit Details form"))
        render()
    }

    override func rowSelected(_ id: String) {
        if id == Self.saveID {
            save()
            return
        }
        guard let field = Field(rawValue: String(id.dropFirst("editDetails.".count))), let window else { return }
        weak var alert: AlertView?
        let shown = AlertView(title: field.label, actions: [
            AlertView.Action(String(localized: "Done", comment: "Button that accepts the typed text")) { [weak self] in
                self?.set(alert?.text ?? "", for: field)
                self?.render()
            },
            AlertView.Action(String(localized: "Cancel"), role: .cancel),
        ], fieldPlaceholder: field.label, fieldText: value(of: field))
        alert = shown
        shown.present(in: window)
    }

    private var fields: [Field] { Field.allCases.filter { $0 != .year || edit.editsYear } }

    private func value(of field: Field) -> String {
        switch field {
        case .title: edit.title
        case .sortTitle: edit.sortTitle
        case .originalTitle: edit.originalTitle
        case .year: edit.year
        case .summary: edit.summary
        }
    }

    private func set(_ text: String, for field: Field) {
        switch field {
        case .title: edit.title = text
        case .sortTitle: edit.sortTitle = text
        case .originalTitle: edit.originalTitle = text
        case .year: edit.year = text.filter(\.isNumber)
        case .summary: edit.summary = text
        }
    }

    private func render() {
        var items = fields.map { field in
            RowItem(id: "editDetails.\(field.rawValue)", title: field.label, value: Self.shortened(value(of: field)), symbol: field.symbol)
        }
        items.append(RowItem(id: Self.saveID, title: String(localized: "Save", comment: "Button that saves the Edit Details form"), symbol: "checkmark.circle",
                             isEnabled: !edit.changedValues.isEmpty))
        setRows(items)
    }

    private static func shortened(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        return line.count > 48 ? String(line.prefix(47)) + "…" : line
    }

    private func save() {
        guard !edit.changedValues.isEmpty else { return }
        let edit = edit
        let api = api
        let onSaved = onSaved
        Task { [weak self] in
            do {
                try await LibraryManagement.edit(edit, api: api)
                _ = self?.navigation?.pop()
                onSaved()
            } catch {
                if let window = self?.window { AlertView.notice(title: ManageCopy.failed, message: ConnectionError.message(for: error), in: window) }
            }
        }
    }
}

/// The server's settings for one show (`TVShowSettingsViewController`): Select flips an on/off setting or opens the server's
/// choices for the rest, a menu with the value in use checked. A change is sent at once and applies to everyone.
@MainActor
final class ShowSettingsScreen: SettingsScaffold {
    private static let prefix = "showSettings."

    private let ratingKey: String
    private let api: APIClient
    private let state = StateView()
    private var settings: [ItemSetting] = []
    private var loadTask: Task<Void, Never>?

    init(ratingKey: String, api: APIClient) {
        self.ratingKey = ratingKey
        self.api = api
        super.init(title: ManageCopy.showSettingsTitle, detail: ManageCopy.showSettingsNote)
        addSubview(state)
        state.show(.loading(title: nil))
        rows.isHidden = true
    }

    override var preferredFocusView: View? { state.isHidden ? rows : state }

    override func screenDidAppear() {
        if settings.isEmpty { load() }
    }

    override func screenWillDisappear() {
        loadTask?.cancel()
    }

    override func descendantFocusDidChange(to view: View?) {
        guard let row = view?.enclosing(RowView.self) else { return }
        heading.detail = settings.first { Self.prefix + $0.id == row.item.id }?.summary ?? ManageCopy.showSettingsNote
    }

    override func rowSelected(_ id: String) {
        guard let setting = settings.first(where: { Self.prefix + $0.id == id }) else { return }
        if setting.isToggle {
            change(setting, to: setting.toggleValue(!setting.isOn))
            return
        }
        guard let window else { return }
        let anchor = window.focusedView?.frameInWindow ?? frameInWindow
        let menu = MenuView(title: setting.label, items: setting.choices.map {
            MenuView.Item(id: $0.value, title: $0.title, isChecked: $0.value == setting.value)
        }, anchor: Rect(x: anchor.maxX - Theme.current.metrics.tv(500), y: anchor.maxY, width: 1, height: 1))
        menu.onSelect = { [weak self] item in self?.change(setting, to: item.id) }
        menu.present(in: window)
    }

    private func load() {
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                self.settings = try await ItemSettings.load(ratingKey: self.ratingKey, api: self.api)
                guard !Task.isCancelled else { return }
                if self.settings.isEmpty {
                    self.state.show(.empty(title: ManageCopy.showSettingsTitle, message: ManageCopy.noShowSettings, symbol: "slider.horizontal.3", action: nil))
                } else {
                    self.render()
                    let hadFocus = self.state.containsFocus
                    self.state.isHidden = true
                    self.rows.isHidden = false
                    if hadFocus { self.window?.focus.focus(self.rows, animated: false) }
                }
            } catch {
                guard !Task.isCancelled else { return }
                MidgarLog.error("Show settings failed to load for \(self.ratingKey): \(error)", category: .networking)
                self.state.show(.error(title: ManageCopy.failed, message: ConnectionError.message(for: error), retryTitle: String(localized: "Try Again"),
                                       retry: { [weak self] in
                                           self?.state.show(.loading(title: nil))
                                           self?.load()
                                       }))
            }
        }
    }

    private func render() {
        setRows(settings.map { setting in
            RowItem(id: Self.prefix + setting.id, title: setting.label, value: setting.valueTitle, symbol: setting.isToggle ? "switch.2" : "list.bullet",
                    accessory: setting.isToggle ? .none : .chevron)
        })
    }

    private func change(_ setting: ItemSetting, to value: String) {
        guard value != setting.value else { return }
        let api = api
        let key = ratingKey
        Task { [weak self] in
            do {
                try await ItemSettings.set(setting, to: value, ratingKey: key, api: api)
                if let reloaded = try? await ItemSettings.load(ratingKey: key, api: api) { self?.settings = reloaded }
                self?.render()
            } catch {
                if let window = self?.window { AlertView.notice(title: ManageCopy.failed, message: ConnectionError.message(for: error), in: window) }
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        state.frame = bounds
    }
}

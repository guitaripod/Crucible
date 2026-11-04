import CrucibleCore
import CrucibleDesign
import UIKit

/// One category of Settings on Apple TV, from the shared catalog: a choice opens a single-select list, a switch flips in
/// place, a row that leads somewhere opens it, and the context column explains whichever row has focus. Restore Defaults
/// shows once anything in the category was changed.
final class TVSettingsCategoryViewController: TVSettingsScaffold {
    private static let restoreID = "settings.restoreDefaults"

    private let env: TVAppEnvironment
    private let category: SettingsCategory
    private let heading: TVSettingsHeading

    init(env: TVAppEnvironment, category: SettingsCategory) {
        self.env = env
        self.category = category
        heading = TVSettingsHeading(title: category.title(on: .tv), body: category.explanation(on: .tv))
        super.init()
        title = category.title(on: .tv)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var entries: [SettingsEntry] {
        SettingsCatalog.sections(of: category, on: .tv).flatMap(\.entries)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installHeading(heading)
        refreshRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshRows()
    }

    override func rowDidSelect(_ id: String) {
        if id == Self.restoreID {
            confirmRestoreDefaults()
            return
        }
        guard let entry = entries.first(where: { rowID($0) == id }) else { return }
        switch entry.item {
        case .preference(let setting):
            switch setting.control {
            case .choice:
                TVNavigation.push(TVSettingsChoiceViewController(setting: setting), from: self)
            case .toggle(let isOn):
                setting.setOn(!isOn)
                refreshRows()
            }
        case .destination(let destination):
            open(destination)
        case .action(let action):
            perform(action)
        case .privacyStatement:
            break
        }
    }

    override func rowDidFocus(_ id: String?) {
        let entry = entries.first { rowID($0) == id }
        heading.setBody(entry?.explanation ?? category.explanation(on: .tv))
    }

    private func refreshRows() {
        var rows = entries.map { entry in
            TVRowItem(
                id: rowID(entry),
                title: entry.title,
                value: value(of: entry),
                symbol: entry.symbol,
                accessory: accessory(of: entry),
                isStatic: entry.item == .privacyStatement
            )
        }
        if SettingsCatalog.preferences(in: category, on: .tv).contains(where: \.isChanged) {
            rows.append(TVRowItem(id: Self.restoreID, title: String(localized: "Restore Defaults", comment: "Button at the end of a settings category that resets its settings"), symbol: "arrow.counterclockwise"))
        }
        setRows(rows)
    }

    /// Rows keep the identifiers the Playback screen always had (`playback.streamingQuality`), so focus memory and tests
    /// carry over; other categories follow the same pattern.
    private func rowID(_ entry: SettingsEntry) -> String {
        switch entry.item {
        case .preference(let setting): return "\(category.rawValue).\(setting)"
        default: return "\(category.rawValue).\(entry.id)"
        }
    }

    private func value(of entry: SettingsEntry) -> String? {
        switch entry.item {
        case .preference(let setting): return setting.valueLabel
        case .destination(.libraries): return LibrariesSettings.summary
        case .destination(.homeRows): return String(localized: "\(HomeLayout.visibleRows().count) rows", comment: "How many Home rows are on, e.g. 5 rows")
        case .destination(.about): return AppInfo.versionSummary
        default: return nil
        }
    }

    private func accessory(of entry: SettingsEntry) -> TVRowItem.Accessory {
        switch entry.item {
        case .preference(let setting): return setting.choices.isEmpty ? .none : .chevron
        case .destination: return .chevron
        case .action, .privacyStatement: return .none
        }
    }

    private func open(_ destination: SettingsDestination) {
        let screen: UIViewController
        switch destination {
        case .homeRows: screen = TVHomeRowsViewController()
        case .libraries: screen = TVScreens.settings(env, page: .libraries)
        case .serverConnection: screen = TVScreens.settings(env, page: .server)
        case .diagnostics: screen = TVScreens.settings(env, page: .diagnostics)
        case .about: screen = TVScreens.settings(env, page: .about)
        case .manageStorage, .notificationPermission, .sourceCode: return
        }
        TVNavigation.push(screen, from: self)
    }

    private func perform(_ action: SettingsAction) {
        guard action.needsConfirmation else {
            run(action)
            return
        }
        presentConfirmation(title: action.confirmationTitle, message: action.confirmationMessage, confirmTitle: action.confirmTitle) { [weak self] in
            self?.run(action)
        }
    }

    private func run(_ action: SettingsAction) {
        switch action {
        case .clearImageCache:
            Task { await ImageLoader.shared.clearCache() }
        case .clearSearchHistory:
            Preferences.recentSearches = []
        case .forgetFinishedTitles:
            FinishedTitlesLedger.shared.reset()
        case .shareLogs:
            return
        }
        presentAlert(title: String(localized: "Done", comment: "Alert after a settings action finished"))
    }

    private func confirmRestoreDefaults() {
        presentConfirmation(
            title: String(localized: "Restore Defaults?", comment: "Confirmation title for resetting a settings category"),
            message: String(localized: "Every setting in \(category.title(on: .tv)) goes back to how Crucible starts out.", comment: "Confirmation message for resetting a settings category"),
            confirmTitle: String(localized: "Restore", comment: "Button that confirms resetting a settings category")
        ) { [weak self] in
            guard let self else { return }
            for setting in SettingsCatalog.preferences(in: category, on: .tv) where setting.isChanged {
                setting.restoreDefault()
            }
            refreshRows()
        }
    }
}

/// The single-select list a choice setting opens: one row per choice with a checkmark on the
/// current one. Selecting applies it immediately; Back returns.
final class TVSettingsChoiceViewController: TVSettingsScaffold {
    private let setting: PreferenceSetting

    init(setting: PreferenceSetting) {
        self.setting = setting
        super.init()
        title = setting.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var preferredFocusRowID: String? {
        setting.choices.first(where: \.isSelected).map(Self.rowID)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let heading = TVSettingsHeading(title: setting.title, body: setting.explanation)
        installHeading(heading)
        refreshRows()
    }

    override func rowDidSelect(_ id: String) {
        guard let choice = setting.choices.first(where: { Self.rowID($0) == id }) else { return }
        setting.select(choice)
        refreshRows()
    }

    private func refreshRows() {
        setRows(setting.choices.map { choice in
            TVRowItem(id: Self.rowID(choice), title: choice.title, subtitle: choice.detail, accessory: choice.isSelected ? .checkmark : .none)
        })
    }

    private static func rowID(_ choice: SettingChoice) -> String {
        "choice.\(choice.id)"
    }
}

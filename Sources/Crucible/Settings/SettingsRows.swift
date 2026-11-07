import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit
import UserNotifications

/// How every settings row looks and what it does, shared by the category screens and the search results: a choice opens
/// a menu right on the row, a switch flips in place, and a row that leads somewhere or does something goes through
/// `SettingsNavigator`.
@MainActor
enum SettingsRows {
    static func configure(
        _ cell: UICollectionViewListCell,
        entry: SettingsEntry,
        subtitle: String?,
        status: String?,
        changed: @escaping @MainActor () -> Void
    ) {
        cell.accessories = []
        cell.applyThemedBackground()
        cell.accessibilityIdentifier = "settings.\(entry.id)"
        switch entry.item {
        case .preference(let setting):
            switch setting.control {
            case .toggle(let isOn):
                var content = IconRowContentConfiguration(symbol: setting.symbol, title: setting.title, subtitle: subtitle)
                content.toggle = .init(isOn: isOn) { isOn in
                    Haptics.selection()
                    setting.setOn(isOn)
                    changed()
                }
                cell.contentConfiguration = content
            case .choice:
                cell.contentConfiguration = IconRowContentConfiguration(
                    symbol: setting.symbol,
                    title: setting.title,
                    subtitle: subtitle,
                    value: setting.valueLabel,
                    menu: menu(for: setting, changed: changed)
                )
            }
        case .destination:
            cell.contentConfiguration = IconRowContentConfiguration(symbol: entry.symbol, title: entry.title, subtitle: subtitle, value: status)
            cell.accessories = [.disclosureIndicator()]
        case .action:
            cell.contentConfiguration = IconRowContentConfiguration(symbol: entry.symbol, title: entry.title, subtitle: subtitle, value: status)
        case .privacyStatement:
            cell.contentConfiguration = IconRowContentConfiguration(symbol: entry.symbol, title: entry.title, subtitle: entry.explanation)
        }
    }

    static func isSelectable(_ entry: SettingsEntry) -> Bool {
        switch entry.item {
        case .destination, .action: return true
        case .preference, .privacyStatement: return false
        }
    }

    static func menu(for setting: PreferenceSetting, changed: @escaping @MainActor () -> Void) -> UIMenu {
        let actions = setting.choices.map { choice in
            let action = UIAction(title: choice.title, state: choice.isSelected ? .on : .off) { _ in
                Haptics.selection()
                setting.select(choice)
                changed()
            }
            action.subtitle = choice.detail
            return action
        }
        return UIMenu(title: setting.title, children: actions)
    }

    /// Where a search result lives, for the line under its title.
    static func breadcrumb(for entry: SettingsEntry) -> String {
        [entry.category.title(on: .phone), entry.section].compactMap { $0 }.joined(separator: " › ")
    }
}

/// Opens the screen a settings row leads to and runs the things a row does.
@MainActor
final class SettingsNavigator {
    private let api: APIClient
    private weak var host: UIViewController?
    var onChange: (@MainActor () -> Void)?

    init(api: APIClient, host: UIViewController) {
        self.api = api
        self.host = host
    }

    func open(_ destination: SettingsDestination, source: UIView?) {
        guard let host else { return }
        switch destination {
        case .homeRows:
            host.navigationController?.pushViewController(HomeRowsViewController(), animated: true)
        case .libraries:
            host.navigationController?.pushViewController(LibrariesViewController(api: api), animated: true)
        case .serverConnection:
            host.navigationController?.pushViewController(ServerDetailViewController(api: api), animated: true)
        case .crucibleServer:
            host.navigationController?.pushViewController(CompanionViewController(), animated: true)
        case .manageStorage:
            (host.tabBarController as? TabBarController)?.select(.downloads)
        case .notificationPermission:
            Task { @MainActor [weak self] in
                let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                if status == .notDetermined {
                    await NotificationCoordinator.shared.requestPermissionIfNeeded()
                    self?.onChange?()
                } else if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    await UIApplication.shared.open(url)
                }
            }
        case .about:
            host.navigationController?.pushViewController(AboutViewController(), animated: true)
        case .sourceCode:
            if let url = AppInfo.sourceURL { UIApplication.shared.open(url) }
        case .diagnostics:
            perform(.shareLogs, source: source)
        }
    }

    func perform(_ action: SettingsAction, source: UIView?) {
        guard let host else { return }
        guard action.needsConfirmation else {
            run(action, source: source)
            return
        }
        let alert = UIAlertController(title: action.confirmationTitle, message: action.confirmationMessage, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: action.confirmTitle, style: .destructive) { [weak self] _ in self?.run(action, source: source) })
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        host.present(alert, animated: true)
    }

    private func run(_ action: SettingsAction, source: UIView?) {
        switch action {
        case .shareLogs:
            shareLogs(from: source)
        case .clearImageCache:
            Task { @MainActor [weak self] in
                await ImageLoader.shared.clearCache()
                Haptics.success()
                self?.onChange?()
            }
        case .clearSearchHistory:
            Preferences.recentSearches = []
            Haptics.success()
            onChange?()
        case .forgetFinishedTitles:
            FinishedTitlesLedger.shared.reset()
            Haptics.success()
            onChange?()
        }
    }

    private func shareLogs(from source: UIView?) {
        Task { @MainActor [weak self] in
            let device = UIDevice.current
            let url = await DiagnosticsReport.export(deviceDescription: DiagnosticsReport.deviceDescription(
                systemName: device.systemName, systemVersion: device.systemVersion, model: device.model
            ))
            guard let host = self?.host else { return }
            guard let url else {
                let alert = UIAlertController(title: String(localized: "No Logs Yet"), message: String(localized: "There are no diagnostic logs to share."), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
                host.present(alert, animated: true)
                return
            }
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activity.completionWithItemsHandler = { _, _, _, _ in
                try? FileManager.default.removeItem(at: url)
            }
            activity.popoverPresentationController?.sourceView = source ?? host.view
            activity.popoverPresentationController?.sourceRect = source?.bounds ?? .zero
            host.present(activity, animated: true)
        }
    }

    /// The value a destination or action row shows: whether iOS lets Crucible notify, how much is downloaded or cached.
    static func status(of item: SettingsItem) async -> String? {
        switch item {
        case .destination(.notificationPermission):
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .ephemeral: return String(localized: "On", comment: "Notification permission status")
            case .provisional: return String(localized: "Quietly", comment: "Notification permission status: delivered quietly")
            case .denied: return String(localized: "Off in iOS Settings", comment: "Notification permission status when iOS denies notifications")
            default: return String(localized: "Not Asked Yet", comment: "Notification permission status before the system prompt")
            }
        case .destination(.manageStorage):
            let used = await DownloadManager.shared.totalBytesOnDisk()
            return used > 0 ? Formatters.fileSize(used) : String(localized: "None")
        case .destination(.libraries):
            return LibrariesSettings.summary
        case .destination(.crucibleServer):
            return CompanionStore.current()?.name ?? CompanionCopy.notSetUp
        case .action(.clearImageCache):
            return ImageCacheMeter.formatted(await ImageCacheMeter.totalBytes())
        case .destination(.sourceCode):
            return "GitHub"
        default:
            return nil
        }
    }
}

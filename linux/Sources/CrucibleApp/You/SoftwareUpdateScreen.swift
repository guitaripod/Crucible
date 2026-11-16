import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// Software Update, from About Crucible: this copy's version and how it was installed beside what can be done about the
/// newest release. A tarball install updates and restarts in place; a package or a checkout copies its command; a binary
/// with no installer opens the release page.
@MainActor
final class SoftwareUpdateScreen: SettingsScaffold {
    private enum RowID {
        static let action = "update.action"
        static let notes = "update.notes"
        static let check = "update.check"
        static let automatic = "update.automatic"
    }

    private let update = SoftwareUpdate.shared
    private let panel: ContextPanel
    private var observer: UUID?
    private var copiedUntil: Date?
    private var showedAction = false

    init() {
        panel = ContextPanel(content: .init(symbol: "arrow.down.circle", title: "Crucible"))
        super.init(title: String(localized: "Software Update"))
        installContext(panel)
        observer = update.observe { [weak self] in self?.refresh() }
        refresh()
    }

    deinit {
        let observer = observer
        Task { @MainActor in observer.map(SoftwareUpdate.shared.stopObserving) }
    }

    override func screenDidAppear() {
        if update.checksReleases, update.phase == .idle, update.lastChecked.map({ Date().timeIntervalSince($0) > 60 * 60 }) ?? true {
            update.check()
        }
    }

    private func refresh() {
        panel.content = .init(symbol: "arrow.down.circle", title: "Crucible \(update.current)", subtitle: installSentence, status: panelStatus.text,
                              statusColor: panelStatus.color, body: panelBody)
        let items = rowItems
        setRows(items)
        let showsAction = items.first?.id == RowID.action
        if showsAction, !showedAction { focusActionIfRowsHaveFocus() }
        showedAction = showsAction
    }

    /// The action row arrived above the row that has the focus (a check found a release): the focus moves to it, so Enter
    /// does what the screen now offers instead of checking again.
    private func focusActionIfRowsHaveFocus() {
        guard let window, let focused = window.focusedView, focused.isDescendant(of: rows), let action = rows.row(id: RowID.action) else { return }
        layoutIfNeeded()
        window.focus.focus(action, animated: true)
    }

    /// How this copy was installed, which says what updates it.
    private var installSentence: String {
        switch update.install {
        case .tarball: return String(localized: "Installed from a release tarball, so it updates itself.")
        case .packaged:
            return String(localized: "Installed by pacman as \(update.ownerPackage ?? "crucible"), which updates it.")
        case .source(let checkout): return String(localized: "Built from the checkout at \(Self.displayPath(checkout)), which updates it.")
        case .developer: return String(localized: "Running out of a build directory, so there is nothing to update.")
        case .standalone: return String(localized: "A binary no installer stamped, so updates come from the release page.")
        }
    }

    private var panelStatus: (text: String?, color: Color?) {
        let palette = Theme.current.palette
        switch update.phase {
        case .checking: return (String(localized: "Checking…"), nil)
        case .downloading: return (String(localized: "Downloading…"), nil)
        case .installing: return (String(localized: "Installing…"), nil)
        case .installed(let version): return (String(localized: "Crucible \(version.description) is installed. Restart to use it."), palette.accent)
        case .failed(let message): return (message, palette.destructive)
        case .idle:
            guard update.checksReleases else { return (nil, nil) }
            if update.hasUpdate, let version = update.newest?.version {
                return (String(localized: "Crucible \(version.description) is available"), palette.accent)
            }
            return update.lastChecked == nil ? (nil, nil) : (String(localized: "Up to date"), nil)
        }
    }

    /// The release's notes while it is newer, else when the last check ran.
    private var panelBody: String? {
        if update.hasUpdate, let notes = update.newest?.notes, !notes.isEmpty { return notes }
        guard update.checksReleases, let checked = update.lastChecked else { return nil }
        return String(localized: "Last checked \(checked.formatted(date: .abbreviated, time: .shortened))")
    }

    private var rowItems: [RowItem] {
        var items: [RowItem] = []
        switch update.offer {
        case .install(let release):
            if case .installed = update.phase {
                items.append(RowItem(id: RowID.action, title: String(localized: "Restart Crucible"), symbol: "arrow.clockwise", accessory: .chevron))
            } else {
                let busy = update.phase == .downloading || update.phase == .installing
                items.append(RowItem(id: RowID.action, title: String(localized: "Update Now"), value: Self.sizeText(release), symbol: "arrow.down.circle",
                                     accessory: .chevron, isEnabled: !busy))
            }
        case .command(let command, _):
            let copied = copiedUntil.map { $0 > Date() } ?? false
            items.append(RowItem(id: RowID.action, title: String(localized: "Copy Command"), subtitle: command,
                                 value: copied ? String(localized: "Copied") : nil, symbol: "doc.on.doc"))
        case .download:
            items.append(RowItem(id: RowID.action, title: String(localized: "Open the Release Page"), symbol: "arrow.up.right.square", accessory: .chevron))
        case .upToDate, .developerBuild:
            break
        }
        if update.hasUpdate, update.newest != nil {
            items.append(RowItem(id: RowID.notes, title: String(localized: "Release Notes"), symbol: "doc.text", accessory: .chevron))
        }
        if update.checksReleases {
            items.append(RowItem(id: RowID.check, title: String(localized: "Check for Updates"), symbol: "arrow.triangle.2.circlepath",
                                 isEnabled: update.phase != .checking && update.phase != .downloading && update.phase != .installing))
            items.append(RowItem(id: RowID.automatic, title: String(localized: "Check Automatically"),
                                 value: update.checksAutomatically ? String(localized: "On") : String(localized: "Off"), symbol: "clock"))
        }
        return items
    }

    override func rowSelected(_ id: String) {
        switch id {
        case RowID.action: act()
        case RowID.notes: update.newest.map { Browser.open($0.page) }
        case RowID.check: update.check()
        case RowID.automatic: update.checksAutomatically.toggle()
        default: break
        }
    }

    private func act() {
        switch update.offer {
        case .install:
            if case .installed = update.phase {
                update.restart()
            } else {
                update.installUpdate()
            }
        case .command(let command, _):
            window?.copy(command)
            copiedUntil = Date().addingTimeInterval(2.5)
            refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
        case .download(let release):
            Browser.open(release.page)
        case .upToDate, .developerBuild:
            break
        }
    }

    private static func sizeText(_ release: LinuxRelease) -> String {
        guard let size = release.tarballSize else { return release.version.description }
        return "\(release.version) · " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

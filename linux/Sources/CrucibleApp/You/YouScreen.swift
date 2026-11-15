import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// You (`TVYouViewController`): the account with its server's live status on the left; Watch History, the server's
/// activity, the settings pages, the desk's interface size and appearance, About and Sign Out on the right. It refreshes
/// on every appearance, with the slower remote content at most once a minute.
@MainActor
final class YouScreen: SettingsScaffold {
    var onSignOut: (() -> Void)?

    private enum RowID {
        static let switchProfile = "you.switchProfile"
        static let history = "you.history"
        static let playlists = "you.playlists"
        static let activity = "you.activity"
        static let dashboard = "you.dashboard"
        static let playback = "you.playback"
        static let remote = "you.remote"
        static let homeRows = "you.homeRows"
        static let libraries = "you.libraries"
        static let server = "you.server"
        static let privacy = "you.privacy"
        static let diagnostics = "you.diagnostics"
        static let about = "you.about"
        static let density = "you.density"
        static let appearance = "you.appearance"
        static let signOut = "you.signOut"
    }

    private let payload: LaunchPayload
    private let panel = ContextPanel(content: .init(symbol: "person.crop.circle", title: ""))
    private var accountName = PlexAccountName.stored
    private var historySubtitle: String?
    private var remoteThrottle = ReloadThrottle(interval: 60)
    private var remoteTask: Task<Void, Never>?

    init(payload: LaunchPayload) {
        self.payload = payload
        super.init(title: String(localized: "You"))
        installContext(panel)
        YouConnectionStatus.shared.onChange = { [weak self] _ in self?.refreshProfile() }
        refreshProfile()
    }

    override func screenDidAppear() {
        accountName = PlexAccountName.stored
        refreshProfile()
        YouConnectionStatus.shared.refresh(api: payload.api)
        guard !remoteThrottle.isFresh() else { return }
        remoteTask = Task { [weak self] in await self?.loadRemoteContent() }
    }

    private func loadRemoteContent() async {
        let api = payload.api
        async let headline = YouHistoryHeadline.latest(api: api)
        async let profiles: Void = refreshHomeProfiles()
        let (newHeadline, _) = await (headline, profiles)
        guard !Task.isCancelled else { return }
        historySubtitle = newHeadline
        remoteThrottle.markLoaded()
        refreshRows()
    }

    /// Asks plex.tv how many profiles the account's Home has, which decides whether Switch Profile shows.
    private func refreshHomeProfiles() async {
        guard let token = ServerBootstrap.accountToken else { return }
        _ = try? await HomeProfiles.load(accountToken: token)
    }

    private func refreshProfile() {
        let profile = YouProfile.make(accountName: accountName, state: YouConnectionStatus.shared.state)
        let palette = Theme.current.palette
        let tone: Color
        switch profile.tone {
        case .ok: tone = palette.statusOK
        case .failure: tone = palette.destructive
        case .neutral: tone = palette.labelTertiary
        }
        panel.content = .init(symbol: "person.crop.circle", monogram: Self.initials(of: profile.name), title: profile.name, status: profile.statusText,
                              statusColor: tone)
        refreshRows()
    }

    /// The first letters of the first two words of `name`.
    private static func initials(of name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }

    private func refreshRows() {
        let theme = Theme.current
        let state = YouConnectionStatus.shared.state
        var items = [
            RowItem(id: RowID.history, title: String(localized: "Watch History"), subtitle: historySubtitle, symbol: "clock", accessory: .chevron),
            RowItem(id: RowID.playlists, title: String(localized: "Playlists"), symbol: "list.bullet.rectangle", accessory: .chevron),
            RowItem(id: RowID.activity, title: ServerActivity.title, symbol: "dot.radiowaves.left.and.right", accessory: .chevron),
            RowItem(id: RowID.playback, title: SettingsCategory.playback.title(on: .linux), value: SettingsCatalog.summary(of: .playback, on: .linux),
                    symbol: Symbol(SettingsCategory.playback.symbol), accessory: .chevron),
            RowItem(id: RowID.remote, title: SettingsCategory.controls.title(on: .linux), symbol: Symbol(SettingsCategory.controls.symbol), accessory: .chevron),
            RowItem(id: RowID.homeRows, title: SettingsCatalog.title(.homeRows),
                    value: String(localized: "\(HomeLayout.visibleRows().count) rows", comment: "How many Home rows are on, e.g. 5 rows"),
                    symbol: Symbol(SettingsCatalog.symbol(.homeRows)), accessory: .chevron),
            RowItem(id: RowID.libraries, title: String(localized: "Libraries"), value: LibrariesSettings.summary, symbol: "rectangle.stack", accessory: .chevron),
            RowItem(id: RowID.server, title: String(localized: "Server & Connection"), value: state.routeSummary, symbol: "server.rack", accessory: .chevron),
            RowItem(id: RowID.privacy, title: SettingsCategory.privacy.title(on: .linux), value: SettingsCatalog.summary(of: .privacy, on: .linux),
                    symbol: Symbol(SettingsCategory.privacy.symbol), accessory: .chevron),
            RowItem(id: RowID.density, title: String(localized: "Interface Size"),
                    subtitle: String(localized: "Desk draws the Apple TV design for a monitor; Couch draws it as on a TV across the room."),
                    value: theme.density == .desk ? String(localized: "Desk") : String(localized: "Couch"), symbol: "textformat.size"),
            RowItem(id: RowID.appearance, title: String(localized: "Appearance"),
                    value: theme.palette.appearance == .dark ? String(localized: "Dark") : String(localized: "Light"), symbol: "circle.lefthalf.filled"),
            RowItem(id: RowID.diagnostics, title: String(localized: "Diagnostics"), symbol: "doc.text.magnifyingglass", accessory: .chevron),
            RowItem(id: RowID.about, title: String(localized: "About Crucible"), value: AppInfo.versionSummary, symbol: "info.circle", accessory: .chevron),
            RowItem(id: RowID.signOut, title: String(localized: "Sign Out"), symbol: "rectangle.portrait.and.arrow.right", isDestructive: true),
        ]
        if HomeProfiles.knownCount > 1 {
            items.insert(RowItem(id: RowID.switchProfile, title: HomeProfiles.title, value: PlexAccountName.stored, symbol: "person.2", accessory: .chevron),
                         at: 0)
        }
        if ServerOwnership.isOwner(), let activity = items.firstIndex(where: { $0.id == RowID.activity }) {
            items.insert(RowItem(id: RowID.dashboard, title: ServerDashboardCopy.title, symbol: "gauge.with.dots.needle.33percent", accessory: .chevron),
                         at: activity + 1)
        }
        setRows(items)
    }

    override func rowSelected(_ id: String) {
        let theme = Theme.current
        let api = payload.api
        switch id {
        case RowID.switchProfile:
            navigation?.push(ProfilesScreen(machineIdentifier: payload.connection.machineIdentifier) { [weak self] in self?.rootView?.onReconnect?() })
        case RowID.history: navigation?.push(HistoryScreen(api: api))
        case RowID.playlists: navigation?.push(PlaylistScreens.playlists(api: api))
        case RowID.activity: navigation?.push(OwnerScreens.activity(api: api))
        case RowID.dashboard: navigation?.push(ServerDashboardScreen(api: api))
        case RowID.playback: navigation?.push(SettingsCategoryScreen(category: .playback, api: api))
        case RowID.remote: navigation?.push(SettingsCategoryScreen(category: .controls, api: api))
        case RowID.homeRows: navigation?.push(HomeRowsScreen())
        case RowID.libraries: navigation?.push(LibrariesScreen(api: api))
        case RowID.server: navigation?.push(ServerConnectionScreen())
        case RowID.privacy: navigation?.push(SettingsCategoryScreen(category: .privacy, api: api))
        case RowID.diagnostics: navigation?.push(DiagnosticsScreen())
        case RowID.about: navigation?.push(AboutScreen())
        case RowID.density:
            theme.density = theme.density == .desk ? .couch : .desk
            window?.relayoutEverything()
        case RowID.appearance:
            theme.palette = theme.palette.appearance == .dark ? .light : .dark
            window?.background = theme.palette.canvas
            window?.relayoutEverything()
        case RowID.signOut:
            guard let window else { return }
            AlertView.confirm(title: String(localized: "Sign Out"), message: String(localized: "Are you sure you want to sign out?"),
                              confirm: String(localized: "Sign Out"), in: window) { [weak self] in self?.onSignOut?() }
        default:
            break
        }
        refreshRows()
    }
}

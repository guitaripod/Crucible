import CrucibleCore
import CrucibleStats
import CrucibleUI
import Foundation
import Kiln

/// You (`TVYouViewController`): the account with its server's live status and this year's Year in Review card on the left;
/// Watch History, Statistics, Playlists, the server's activity, the settings pages, the desk's interface size and
/// appearance, About and Sign Out on the right. It refreshes on every appearance, with the slower remote content at most
/// once a minute.
@MainActor
final class YouScreen: SettingsScaffold {
    var onSignOut: (() -> Void)?
    var onLeaveDemo: (() -> Void)?

    private enum RowID {
        static let switchProfile = "you.switchProfile"
        static let history = "you.history"
        static let statistics = "you.statistics"
        static let playlists = "you.playlists"
        static let watchlist = "you.watchlist"
        static let activity = "you.activity"
        static let dashboard = "you.dashboard"
        static let playback = "you.playback"
        static let remote = "you.remote"
        static let homeRows = "you.homeRows"
        static let libraries = "you.libraries"
        static let server = "you.server"
        static let crucibleServer = "you.crucibleServer"
        static let trakt = "you.trakt"
        static let seerr = "you.seerr"
        static let requests = "you.requests"
        static let privacy = "you.privacy"
        static let diagnostics = "you.diagnostics"
        static let about = "you.about"
        static let density = "you.density"
        static let appearance = "you.appearance"
        static let signOut = "you.signOut"
        static let demo = "you.demo"
        static let leaveDemo = "you.leaveDemo"
        static let settings = "you.settings"
        /// The rows that are Settings' own pages, which the Desktop layout leaves to the sidebar's Settings.
        static let settingsPages: Set<String> = [playback, remote, homeRows, libraries, server, crucibleServer, trakt, seerr, privacy, diagnostics,
                                                 about, density, appearance]
    }

    private let payload: LaunchPayload
    private let panel = ContextPanel(content: .init(symbol: "person.crop.circle", title: ""))
    private let yearCard = YearInReviewCardView()
    private var accountName = PlexAccountName.stored
    private var historySubtitle: String?
    private var remoteThrottle = ReloadThrottle(interval: 60)
    private var remoteTask: Task<Void, Never>?
    private var libraryObserver: UUID?
    private var releasesObserver: UUID?
    private var tourObserver: UUID?
    private var traktObserver: UUID?
    private var seerrObserver: UUID?
    private var updateObserver: UUID?

    init(payload: LaunchPayload) {
        self.payload = payload
        super.init(title: String(localized: "You"))
        installContext(ContextColumn(panel: panel, card: yearCard))
        yearCard.isHidden = true
        yearCard.onSelect = { [weak self] in self?.openStatistics() }
        YouConnectionStatus.shared.onChange = { [weak self] _ in self?.refreshProfile() }
        observeRowSources()
        refreshProfile()
    }

    deinit {
        let (library, releases, tour, trakt, seerr, update) = (libraryObserver, releasesObserver, tourObserver, traktObserver, seerrObserver, updateObserver)
        Task { @MainActor in
            library.map(LibraryVisibility.removeObserver)
            releases.map(WatchlistReleases.shared.removeObserver)
            tour.map(DemoTour.shared.stopObserving)
            trakt.map(TraktAccount.shared.stopObserving)
            seerr.map(SeerrAccount.shared.stopObserving)
            update.map(SoftwareUpdate.shared.stopObserving)
        }
    }

    /// Redraws the rows whenever what they say changes while You is open (`TVYouViewController`): the libraries shown, the
    /// watchlist's releases, the demo tour, and Trakt or Seerr connecting or leaving.
    private func observeRowSources() {
        libraryObserver = LibraryVisibility.addObserver { [weak self] in self?.refreshRows() }
        releasesObserver = WatchlistReleases.shared.addObserver { [weak self] in self?.refreshRows() }
        tourObserver = DemoTour.shared.observe { [weak self] in self?.refreshRows() }
        traktObserver = TraktAccount.shared.observe { [weak self] in self?.refreshRows() }
        seerrObserver = SeerrAccount.shared.observe { [weak self] in self?.refreshRows() }
        updateObserver = SoftwareUpdate.shared.observe { [weak self] in self?.refreshRows() }
    }

    /// How many shows on the watchlist have something new out, when any do.
    private var watchlistNews: String? {
        let count = WatchlistReleases.shared.releases().count
        return count > 0 ? WatchlistReleaseCopy.newCount(count) : nil
    }

    // MARK: Two panes

    /// The page beside the list in the Desktop layout, and which row it belongs to.
    private var pane: ScreenView?
    private var paneID: String?
    /// The page last open beside the list, which You opens on again.
    private static var lastPaneID = RowID.history
    /// The rows whose pages open beside the list rather than over it.
    private static let paneRows: Set<String> = [RowID.history, RowID.statistics, RowID.playlists, RowID.watchlist, RowID.requests, RowID.activity,
                                                RowID.dashboard]

    /// Whether You keeps its list down the left with the chosen page beside it (the Desktop layout).
    private var usesPanes: Bool { Theme.current.density == .desk }

    private func paneScreen(for id: String) -> ScreenView? {
        let api = payload.api
        switch id {
        case RowID.history: return HistoryScreen(api: api)
        case RowID.statistics: return StatisticsScreen(api: api)
        case RowID.playlists: return PlaylistScreens.playlists(api: api)
        case RowID.watchlist: return WatchlistScreens.watchlist(api: api)
        case RowID.requests: return SeerrRequestsScreen(api: api)
        case RowID.activity: return OwnerScreens.activity(api: api)
        case RowID.dashboard: return ServerDashboardScreen(api: api)
        default: return nil
        }
    }

    /// Opens `id`'s page beside the list in place of the one there; what it opens itself still goes on the stack.
    private func showPane(_ id: String) {
        guard id != paneID || pane == nil, let screen = paneScreen(for: id) else { return }
        pane?.screenWillDisappear()
        pane?.removeFromSuperview()
        screen.navigation = navigation
        pane = screen
        paneID = id
        Self.lastPaneID = id
        rows.selectedID = id
        addSubview(screen)
        placePanes()
        screen.screenDidAppear()
    }

    private func closePane() {
        pane?.screenWillDisappear()
        pane?.removeFromSuperview()
        pane = nil
        paneID = nil
        rows.selectedID = nil
    }

    override func layoutSubviews() {
        if usesPanes, pane == nil, !rows.items.isEmpty {
            showPane(rows.items.contains { $0.id == Self.lastPaneID } ? Self.lastPaneID : RowID.history)
        }
        if !usesPanes, pane != nil { closePane() }
        placePanes()
    }

    /// The list in a column at the leading edge and the page in the rest, or the list alone on a couch.
    private func placePanes() {
        let column = Theme.current.metrics.tv(980)
        leadingColumnWidth = usesPanes ? column : nil
        super.layoutSubviews()
        guard let pane else { return }
        pane.frame = Rect(x: column, y: 0, width: max(bounds.width - column, 0), height: bounds.height)
    }

    override func screenWillDisappear() {
        pane?.screenWillDisappear()
    }

    override func screenDidAppear() {
        pane?.screenDidAppear()
        accountName = PlexAccountName.stored
        refreshProfile()
        YouConnectionStatus.shared.refresh(api: payload.api)
        guard !remoteThrottle.isFresh() else { return }
        remoteTask = Task { [weak self] in await self?.loadRemoteContent() }
    }

    private func loadRemoteContent() async {
        let api = payload.api
        async let headline = YouHistoryHeadline.latest(api: api)
        async let summary = YearInReviewSummary.load()
        async let profiles: Void = refreshHomeProfiles()
        let (newHeadline, newSummary, _) = await (headline, summary, profiles)
        guard !Task.isCancelled else { return }
        historySubtitle = newHeadline
        applyYear(newSummary)
        remoteThrottle.markLoaded()
        refreshRows()
    }

    private func applyYear(_ summary: YearInReviewSummary?) {
        if let summary {
            yearCard.configure(caption: summary.caption, primary: summary.primary, unit: summary.unit, detail: summary.detail, strip: summary.strip)
        }
        yearCard.isHidden = summary == nil
        yearCard.superview?.setNeedsLayout()
        setNeedsLayout()
    }

    private func openStatistics() {
        navigation?.push(StatisticsScreen(api: payload.api))
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
            RowItem(id: RowID.statistics, title: String(localized: "Statistics"), symbol: "chart.bar", accessory: .chevron),
            RowItem(id: RowID.playlists, title: String(localized: "Playlists"), symbol: "list.bullet.rectangle", accessory: .chevron),
            RowItem(id: RowID.watchlist, title: WatchlistService.title, value: watchlistNews, symbol: "bookmark", accessory: .chevron),
            RowItem(id: RowID.activity, title: ServerActivity.title, symbol: "dot.radiowaves.left.and.right", accessory: .chevron),
            RowItem(id: RowID.playback, title: SettingsCategory.playback.title(on: .linux), value: SettingsCatalog.summary(of: .playback, on: .linux),
                    symbol: Symbol(SettingsCategory.playback.symbol), accessory: .chevron),
            RowItem(id: RowID.remote, title: SettingsCategory.controls.title(on: .linux), symbol: Symbol(SettingsCategory.controls.symbol), accessory: .chevron),
            RowItem(id: RowID.homeRows, title: SettingsCatalog.title(.homeRows),
                    value: String(localized: "\(HomeLayout.visibleRows().count) rows", comment: "How many Home rows are on, e.g. 5 rows"),
                    symbol: Symbol(SettingsCatalog.symbol(.homeRows)), accessory: .chevron),
            RowItem(id: RowID.libraries, title: String(localized: "Libraries"), value: LibrariesSettings.summary, symbol: "rectangle.stack", accessory: .chevron),
            RowItem(id: RowID.server, title: String(localized: "Server & Connection"), value: state.routeSummary, symbol: "server.rack", accessory: .chevron),
            RowItem(id: RowID.crucibleServer, title: CompanionCopy.title, value: CrucibleServerCopy.rowValue, symbol: Symbol(SettingsCatalog.symbol(.crucibleServer)), accessory: .chevron),
            RowItem(id: RowID.trakt, title: TraktCopy.name, subtitle: TraktCopy.tagline, value: TraktAccount.shared.rowStatus, symbol: Symbol(SettingsCatalog.symbol(.trakt)),
                    accessory: .chevron, brand: "trakt"),
            RowItem(id: RowID.seerr, title: SeerrCopy.name, subtitle: SeerrCopy.tagline,
                    value: SeerrAccount.shared.connection?.displayName ?? String(localized: "Off", comment: "Integrations summary when nothing is connected"),
                    symbol: Symbol(SettingsCatalog.symbol(.seerr)), accessory: .chevron, brand: "seerr"),
            RowItem(id: RowID.privacy, title: SettingsCategory.privacy.title(on: .linux), value: SettingsCatalog.summary(of: .privacy, on: .linux),
                    symbol: Symbol(SettingsCategory.privacy.symbol), accessory: .chevron),
            RowItem(id: RowID.density, title: LinuxDisplay.layoutTitle, subtitle: LinuxDisplay.layoutExplanation, value: LinuxDisplay.densityLabel,
                    symbol: "textformat.size"),
            RowItem(id: RowID.appearance, title: String(localized: "Appearance"),
                    value: LinuxDisplay.appearanceLabel, symbol: "circle.lefthalf.filled"),
            RowItem(id: RowID.diagnostics, title: String(localized: "Diagnostics"), symbol: "doc.text.magnifyingglass", accessory: .chevron),
            RowItem(id: RowID.about, title: String(localized: "About Crucible"),
                    value: SoftwareUpdate.shared.hasUpdate ? String(localized: "Update Available") : AppInfo.versionSummary, symbol: "info.circle",
                    accessory: .chevron),
            RowItem(id: RowID.signOut, title: String(localized: "Sign Out"), symbol: "rectangle.portrait.and.arrow.right", isDestructive: true),
        ]
        if HomeProfiles.knownCount > 1 {
            items.insert(RowItem(id: RowID.switchProfile, title: HomeProfiles.title, value: PlexAccountName.stored, symbol: "person.2", accessory: .chevron),
                         at: 0)
        }
        if SeerrAccount.shared.isConnected, let watchlist = items.firstIndex(where: { $0.id == RowID.watchlist }) {
            items.insert(RowItem(id: RowID.requests, title: SeerrCopy.requests, symbol: "tray.full", accessory: .chevron), at: watchlist + 1)
        }
        if ServerOwnership.isOwner(), let activity = items.firstIndex(where: { $0.id == RowID.activity }) {
            items.insert(RowItem(id: RowID.dashboard, title: ServerDashboardCopy.title, symbol: "gauge.with.dots.needle.33percent", accessory: .chevron),
                         at: activity + 1)
        }
        if Theme.current.density == .desk {
            items.removeAll { RowID.settingsPages.contains($0.id) }
            let settings = RowItem(id: RowID.settings, title: String(localized: "Settings"), value: SoftwareUpdate.shared.hasUpdate ? String(localized: "Update Available") : nil,
                                   symbol: "gearshape", accessory: .chevron)
            items.insert(settings, at: items.firstIndex { $0.id == RowID.signOut } ?? items.count)
        }
        if DemoMode.shared.isActive { adaptForDemo(&items) }
        setRows(items)
    }

    /// While the demo runs: the quiet way into the tour at the top, no server to manage, and Sign Out becomes Leave the
    /// Demo, since there is no account to sign out of.
    private func adaptForDemo(_ items: inout [RowItem]) {
        items.removeAll { $0.id == RowID.server || $0.id == RowID.crucibleServer }
        if let signOut = items.firstIndex(where: { $0.id == RowID.signOut }) {
            items[signOut] = RowItem(id: RowID.leaveDemo, title: String(localized: "Leave the Demo"), symbol: "rectangle.portrait.and.arrow.right",
                                     isDestructive: true)
        }
        items.insert(RowItem(id: RowID.demo, title: DemoCopy.bannerTitle, subtitle: LinuxDemoState.progressText(), symbol: "testtube.2", accessory: .chevron),
                     at: 0)
    }

    override func rowSelected(_ id: String) {
        let api = payload.api
        if usesPanes, Self.paneRows.contains(id) {
            showPane(id)
            return
        }
        switch id {
        case RowID.switchProfile:
            navigation?.push(ProfilesScreen(machineIdentifier: payload.connection.machineIdentifier) { [weak self] in self?.rootView?.onReconnect?() })
        case RowID.history: navigation?.push(HistoryScreen(api: api))
        case RowID.settings: rootView?.openSettings()
        case RowID.statistics: openStatistics()
        case RowID.playlists: navigation?.push(PlaylistScreens.playlists(api: api))
        case RowID.watchlist: navigation?.push(WatchlistScreens.watchlist(api: api))
        case RowID.activity: navigation?.push(OwnerScreens.activity(api: api))
        case RowID.dashboard: navigation?.push(ServerDashboardScreen(api: api))
        case RowID.playback: navigation?.push(SettingsCategoryScreen(category: .playback, api: api))
        case RowID.remote: navigation?.push(SettingsCategoryScreen(category: .controls, api: api))
        case RowID.homeRows: navigation?.push(HomeRowsScreen())
        case RowID.libraries: navigation?.push(LibrariesScreen(api: api))
        case RowID.server: navigation?.push(ServerConnectionScreen())
        case RowID.crucibleServer: navigation?.push(CrucibleServerScreen())
        case RowID.trakt: navigation?.push(TraktSettingsScreen())
        case RowID.seerr: navigation?.push(SeerrSettingsScreen(api: api))
        case RowID.requests: navigation?.push(SeerrRequestsScreen(api: api))
        case RowID.privacy: navigation?.push(SettingsCategoryScreen(category: .privacy, api: api))
        case RowID.diagnostics: navigation?.push(DiagnosticsScreen())
        case RowID.about: navigation?.push(AboutScreen())
        case RowID.density: LinuxDisplay.toggleDensity(in: window)
        case RowID.appearance: LinuxDisplay.toggleAppearance(in: window)
        case RowID.demo: navigation?.push(DemoTourScreen(payload: payload))
        case RowID.leaveDemo:
            guard let window else { return }
            DemoLeave.confirm(connecting: false, in: window) { [weak self] in self?.onLeaveDemo?() }
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

/// You's left column: the profile panel with the Year in Review card under it while there is a year to show.
@MainActor
private final class ContextColumn: View {
    private let panel: View
    private let card: View

    init(panel: View, card: View) {
        self.panel = panel
        self.card = card
        super.init()
        [panel, card].forEach(addSubview)
    }

    private var spacing: Float { Theme.current.metrics.tv(40) }

    override func sizeThatFits(_ size: Size) -> Size {
        var height = panel.sizeThatFits(size).height
        if !card.isHidden { height += spacing + card.sizeThatFits(size).height }
        return Size(width: size.width, height: height)
    }

    override func layoutSubviews() {
        let panelHeight = panel.sizeThatFits(Size(width: frame.width, height: 0)).height
        panel.frame = Rect(x: 0, y: 0, width: frame.width, height: panelHeight)
        let cardHeight = card.sizeThatFits(Size(width: frame.width, height: 0)).height
        card.frame = Rect(x: 0, y: panelHeight + spacing, width: frame.width, height: cardHeight)
    }
}

import CrucibleCore
import CrucibleDesign
import CrucibleStats
import UIKit

/// The You tab: the account and the Year in Review card on the left, the list of places on the
/// right (history, statistics, settings sub-screens, sign out).
final class TVYouViewController: TVSettingsScaffold {
    private enum RowID {
        static let demo = "you.demo"
        static let freePreview = "you.demoFreePreview"
        static let switchProfile = "you.switchProfile"
        static let playlists = "you.playlists"
        static let watchlist = "you.watchlist"
        static let activity = "you.activity"
        static let dashboard = "you.dashboard"
        static let history = "you.history"
        static let statistics = "you.statistics"
        static let pro = "you.pro"
        static let playback = "you.playback"
        static let remote = "you.remote"
        static let homeRows = "you.homeRows"
        static let privacy = "you.privacy"
        static let libraries = "you.libraries"
        static let server = "you.server"
        static let crucibleServer = "you.crucibleServer"
        static let trakt = "you.trakt"
        static let seerr = "you.seerr"
        static let requests = "you.requests"
        static let diagnostics = "you.diagnostics"
        static let about = "you.about"
        static let signOut = "you.signOut"
        static let leaveDemo = "you.leaveDemo"
    }

    private let env: TVAppEnvironment
    private let profilePanel = TVProfilePanelView()
    private let yearCard = TVYearCardView()
    private let yearGuide = UIFocusGuide()
    private var accountName = PlexAccountName.fallbackName
    private var historySubtitle: String?
    private lazy var remoteContentSlot = makeTaskSlot()
    private var remoteContentThrottle = ReloadThrottle(interval: 60)
    private var libraryObserver: UUID?
    private var proObserver: UUID?
    private var tourObserver: UUID?

    init(env: TVAppEnvironment) {
        self.env = env
        super.init()
        title = String(localized: "You")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let libraryObserver {
            Task { @MainActor in LibraryVisibility.removeObserver(libraryObserver) }
        }
        if let proObserver {
            Task { @MainActor in ProAccess.shared.stopObserving(proObserver) }
        }
        if let tourObserver {
            Task { @MainActor in DemoTour.shared.stopObserving(tourObserver) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildContextColumn()
        YouConnectionStatus.shared.onChange = { [weak self] _ in self?.refreshProfile() }
        libraryObserver = LibraryVisibility.addObserver { [weak self] in self?.refreshRows() }
        proObserver = ProAccess.shared.observe { [weak self] _ in self?.refreshRows() }
        tourObserver = DemoTour.shared.observe { [weak self] in self?.refreshRows() }
        refreshProfile()
        refreshRows()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        accountName = PlexAccountName.stored
        refreshProfile()
        refreshRows()
        YouConnectionStatus.shared.refresh(api: env.api)
        guard !remoteContentThrottle.isFresh() else { return }
        remoteContentSlot.run { [weak self] in
            await self?.loadRemoteContent()
        }
    }

    override func rowDidSelect(_ id: String) {
        switch id {
        case RowID.demo: push(TVScreens.demoTour(env))
        case RowID.freePreview: DemoMode.shared.setPreviewsFreeVersion(!DemoMode.shared.previewsFreeVersion)
        case RowID.switchProfile: push(TVScreens.profiles(env))
        case RowID.playlists: push(TVScreens.playlists(env))
        case RowID.watchlist: push(TVScreens.watchlist(env))
        case RowID.activity: push(TVScreens.serverActivity(env))
        case RowID.dashboard: push(TVScreens.serverDashboard(env))
        case RowID.history: push(TVScreens.history(env))
        case RowID.statistics: push(TVScreens.statistics(env))
        case RowID.pro: openPro()
        case RowID.playback: push(TVScreens.settings(env, page: .playback))
        case RowID.remote: push(TVScreens.settings(env, page: .remote))
        case RowID.homeRows: push(TVScreens.settings(env, page: .homeRows))
        case RowID.privacy: push(TVScreens.settings(env, page: .privacy))
        case RowID.libraries: push(TVScreens.settings(env, page: .libraries))
        case RowID.server: push(TVScreens.settings(env, page: .server))
        case RowID.crucibleServer: push(TVCompanionViewController())
        case RowID.trakt: push(TVTraktSettingsViewController())
        case RowID.seerr: push(TVSeerrSettingsViewController(env: env))
        case RowID.requests: push(TVSeerrRequestsViewController(env: env))
        case RowID.diagnostics: push(TVScreens.settings(env, page: .diagnostics))
        case RowID.about: push(TVScreens.settings(env, page: .about))
        case RowID.signOut: confirmSignOut()
        case RowID.leaveDemo: confirmLeaveDemo()
        default: break
        }
    }

    /// A Pro user sees their plan; everyone else meets the paywall, and so does the demo, which unlocks every feature but must still
    /// show what Pro costs: `requestUnlock` would answer at once there, so the paywall is presented directly.
    private func openPro() {
        guard ProAccess.shared.isPro else {
            presentPaywall()
            return
        }
        push(TVScreens.settings(env, page: .pro))
    }

    private func presentPaywall() {
        guard !ProAccess.shared.hasFullAccess else {
            TVPaywallViewController.present(PaywallRequest(), from: self) { _ in }
            return
        }
        ProAccess.shared.requestUnlock(nil)
    }

    private func push(_ screen: UIViewController) {
        TVNavigation.push(screen, from: self)
    }

    private func buildContextColumn() {
        yearCard.isHidden = true
        yearCard.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            push(TVScreens.statistics(env))
        }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [profilePanel, yearCard])
        stack.axis = .vertical
        stack.spacing = Theme.Space.l
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        contextColumn.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contextColumn.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contextColumn.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contextColumn.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contextColumn.bottomAnchor),
        ])

        view.addLayoutGuide(yearGuide)
        NSLayoutConstraint.activate([
            yearGuide.leadingAnchor.constraint(equalTo: contextColumn.leadingAnchor),
            yearGuide.trailingAnchor.constraint(equalTo: contextColumn.trailingAnchor),
            yearGuide.topAnchor.constraint(equalTo: contextColumn.topAnchor),
            yearGuide.bottomAnchor.constraint(equalTo: yearCard.topAnchor),
        ])
        yearGuide.preferredFocusEnvironments = [yearCard]
        yearGuide.isEnabled = false
    }

    private func loadRemoteContent() async {
        let api = env.api
        async let headline = YouHistoryHeadline.latest(api: api)
        async let summary = YearInReviewSummary.load()
        async let profiles: Void = refreshHomeProfiles()
        let (newHeadline, newSummary, _) = await (headline, summary, profiles)
        guard !Task.isCancelled else { return }
        historySubtitle = newHeadline
        refreshRows()
        applyYear(newSummary)
        remoteContentThrottle.markLoaded()
    }

    /// Asks plex.tv how many profiles the account's Home has, which decides whether Switch Profile shows.
    private func refreshHomeProfiles() async {
        guard let token = ServerBootstrap.accountToken else { return }
        _ = try? await HomeProfiles.load(accountToken: token)
    }

    private func applyYear(_ summary: YearInReviewSummary?) {
        if let summary { yearCard.configure(summary) }
        yearCard.isHidden = summary == nil
        yearGuide.isEnabled = summary != nil
    }

    private func refreshProfile() {
        profilePanel.configure(YouProfile.make(accountName: accountName, state: YouConnectionStatus.shared.state))
        refreshRows()
    }

    private func refreshRows() {
        let state = YouConnectionStatus.shared.state
        let inDemo = DemoMode.shared.isActive
        var rows = [
            TVRowItem(id: RowID.history, title: String(localized: "Watch History"), subtitle: historySubtitle, symbol: "clock", accessory: .chevron),
            TVRowItem(id: RowID.statistics, title: String(localized: "Statistics"), symbol: "chart.bar", accessory: .chevron),
            TVRowItem(id: RowID.playlists, title: String(localized: "Playlists"), symbol: "list.bullet.rectangle", accessory: .chevron),
            TVRowItem(id: RowID.watchlist, title: WatchlistService.title, symbol: "bookmark", accessory: .chevron),
            TVRowItem(id: RowID.activity, title: ServerActivity.title, symbol: "dot.radiowaves.left.and.right", accessory: .chevron),
            TVRowItem(id: RowID.playback, title: SettingsCategory.playback.title(on: .tv), value: SettingsCatalog.summary(of: .playback, on: .tv), symbol: SettingsCategory.playback.symbol, accessory: .chevron),
            TVRowItem(id: RowID.remote, title: SettingsCategory.controls.title(on: .tv), symbol: "appletvremote.gen4", accessory: .chevron),
            TVRowItem(id: RowID.homeRows, title: SettingsCatalog.title(.homeRows), value: String(localized: "\(HomeLayout.visibleRows().count) rows", comment: "How many Home rows are on, e.g. 5 rows"), symbol: SettingsCatalog.symbol(.homeRows), accessory: .chevron),
            TVRowItem(id: RowID.libraries, title: String(localized: "Libraries"), value: LibrariesSettings.summary, symbol: "rectangle.stack", accessory: .chevron),
            TVRowItem(id: RowID.server, title: String(localized: "Server & Connection"), value: state.routeSummary, symbol: "server.rack", accessory: .chevron),
            TVRowItem(id: RowID.crucibleServer, title: CompanionCopy.title, value: CompanionStore.current()?.name ?? CompanionCopy.notSetUp, symbol: SettingsCatalog.symbol(.crucibleServer), accessory: .chevron),
            TVRowItem(id: RowID.trakt, title: TraktCopy.name, subtitle: TraktCopy.tagline, value: TraktAccount.shared.summary, symbol: SettingsCatalog.symbol(.trakt), accessory: .chevron),
            TVRowItem(id: RowID.seerr, title: SeerrCopy.name, subtitle: SeerrCopy.tagline, value: SeerrAccount.shared.connection?.displayName ?? String(localized: "Off", comment: "Integrations summary when nothing is connected"), symbol: SettingsCatalog.symbol(.seerr), accessory: .chevron),
            TVRowItem(id: RowID.privacy, title: SettingsCategory.privacy.title(on: .tv), value: SettingsCatalog.summary(of: .privacy, on: .tv), symbol: SettingsCategory.privacy.symbol, accessory: .chevron),
            TVRowItem(id: RowID.diagnostics, title: String(localized: "Diagnostics"), symbol: "doc.text.magnifyingglass", accessory: .chevron),
            TVRowItem(id: RowID.about, title: String(localized: "About Crucible"), value: AppInfo.versionSummary, symbol: "info.circle", accessory: .chevron),
            signOutRow(inDemo: inDemo),
        ]
        if ProAccess.shared.isStoreBacked {
            rows.insert(proRow(), at: 2)
        }
        if HomeProfiles.knownCount > 1 {
            rows.insert(TVRowItem(id: RowID.switchProfile, title: HomeProfiles.title, value: PlexAccountName.stored, symbol: "person.2", accessory: .chevron), at: 0)
        }
        if SeerrAccount.shared.isConnected, let watchlist = rows.firstIndex(where: { $0.id == RowID.watchlist }) {
            rows.insert(TVRowItem(id: RowID.requests, title: SeerrCopy.requests, symbol: "tray.full", accessory: .chevron), at: watchlist + 1)
        }
        if ServerOwnership.isOwner(), let activity = rows.firstIndex(where: { $0.id == RowID.activity }) {
            rows.insert(TVRowItem(id: RowID.dashboard, title: ServerDashboardCopy.title, symbol: "gauge.with.dots.needle.33percent", accessory: .chevron), at: activity + 1)
        }
        if inDemo {
            rows.removeAll { $0.id == RowID.server || $0.id == RowID.crucibleServer }
            if ProAccess.shared.isStoreBacked, !ProAccess.shared.isPro { rows.insert(freePreviewRow(), at: 0) }
            rows.insert(demoRow(), at: 0)
        }
        setRows(rows)
    }

    /// The quiet way into the tour, at the top of the list for as long as the demo runs.
    private func demoRow() -> TVRowItem {
        TVRowItem(
            id: RowID.demo,
            title: DemoCopy.bannerTitle,
            subtitle: TVDemoState.progressText(),
            symbol: "testtube.2",
            accessory: .chevron
        )
    }

    /// Sign Out becomes Leave the Demo while the demo runs: there is no account to sign out of.
    private func freePreviewRow() -> TVRowItem {
        TVRowItem(
            id: RowID.freePreview,
            title: DemoCopy.freePreviewTitle,
            subtitle: DemoCopy.freePreviewDetail,
            value: DemoMode.shared.previewsFreeVersion ? String(localized: "On") : String(localized: "Off"),
            symbol: "lock"
        )
    }

    private func signOutRow(inDemo: Bool) -> TVRowItem {
        guard inDemo else {
            return TVRowItem(id: RowID.signOut, title: String(localized: "Sign Out"), symbol: "rectangle.portrait.and.arrow.right", isDestructive: true)
        }
        return TVRowItem(id: RowID.leaveDemo, title: String(localized: "Leave the Demo"), symbol: "rectangle.portrait.and.arrow.right", isDestructive: true)
    }

    private func proRow() -> TVRowItem {
        TVRowItem(
            id: RowID.pro,
            title: String(localized: "Crucible Pro"),
            subtitle: ProTVPresentation.rowSubtitle(for: ProAccess.shared.status, proWeekEndsAt: ProAccess.shared.proWeekEndsAt),
            symbol: "sparkles",
            accessory: .chevron
        )
    }

    private func confirmLeaveDemo() {
        presentLeaveDemoConfirmation(connecting: false) { [session = env.session] in
            session.leaveDemo()
        }
    }

    private func confirmSignOut() {
        presentConfirmation(title: String(localized: "Sign Out"), message: String(localized: "Are you sure you want to sign out?"), confirmTitle: String(localized: "Sign Out")) { [session = env.session] in
            session.signOut()
        }
    }
}

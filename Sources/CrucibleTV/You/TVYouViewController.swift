import CrucibleCore
import CrucibleDesign
import CrucibleStats
import UIKit

/// The You tab: the account and the Year in Review card on the left, the list of places on the
/// right (history, statistics, settings sub-screens, sign out).
final class TVYouViewController: TVSettingsScaffold {
    private enum RowID {
        static let history = "you.history"
        static let statistics = "you.statistics"
        static let playback = "you.playback"
        static let libraries = "you.libraries"
        static let server = "you.server"
        static let diagnostics = "you.diagnostics"
        static let about = "you.about"
        static let signOut = "you.signOut"
    }

    private let env: TVAppEnvironment
    private let profilePanel = TVProfilePanelView()
    private let yearCard = TVYearCardView()
    private let yearGuide = UIFocusGuide()
    private var accountName = PlexAccountName.fallbackName
    private var historySubtitle: String?
    private var loadTask: Task<Void, Never>?
    private var remoteContentThrottle = ReloadThrottle(interval: 60)
    private var libraryObserver: UUID?

    init(env: TVAppEnvironment) {
        self.env = env
        super.init(nibName: nil, bundle: nil)
        title = "You"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        loadTask?.cancel()
        if let libraryObserver {
            Task { @MainActor in LibraryVisibility.removeObserver(libraryObserver) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildContextColumn()
        YouConnectionStatus.shared.onChange = { [weak self] _ in self?.refreshProfile() }
        libraryObserver = LibraryVisibility.addObserver { [weak self] in self?.refreshRows() }
        refreshProfile()
        refreshRows()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        accountName = PlexAccountName.stored
        refreshProfile()
        refreshRows()
        YouConnectionStatus.shared.refresh(api: env.api)
        loadTask?.cancel()
        guard !remoteContentThrottle.isFresh() else { return }
        loadTask = Task { [weak self] in
            await self?.loadRemoteContent()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
    }

    override func rowDidSelect(_ id: String) {
        switch id {
        case RowID.history: push(TVScreens.history(env))
        case RowID.statistics: push(TVScreens.statistics(env))
        case RowID.playback: push(TVScreens.settings(env, page: .playback))
        case RowID.libraries: push(TVScreens.settings(env, page: .libraries))
        case RowID.server: push(TVScreens.settings(env, page: .server))
        case RowID.diagnostics: push(TVScreens.settings(env, page: .diagnostics))
        case RowID.about: push(TVScreens.settings(env, page: .about))
        case RowID.signOut: confirmSignOut()
        default: break
        }
    }

    private func push(_ screen: UIViewController) {
        navigationController?.pushViewController(screen, animated: true)
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
        let (newHeadline, newSummary) = await (headline, summary)
        guard !Task.isCancelled else { return }
        historySubtitle = newHeadline
        refreshRows()
        applyYear(newSummary)
        remoteContentThrottle.markLoaded()
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
        setRows([
            TVRowItem(id: RowID.history, title: "Watch History", subtitle: historySubtitle, symbol: "clock", accessory: .chevron),
            TVRowItem(id: RowID.statistics, title: "Statistics", symbol: "chart.bar", accessory: .chevron),
            TVRowItem(id: RowID.playback, title: "Playback", symbol: "play.rectangle", accessory: .chevron),
            TVRowItem(id: RowID.libraries, title: "Libraries", value: LibrariesSettings.summary, symbol: "rectangle.stack", accessory: .chevron),
            TVRowItem(id: RowID.server, title: "Server & Connection", value: state.routeSummary, symbol: "server.rack", accessory: .chevron),
            TVRowItem(id: RowID.diagnostics, title: "Diagnostics", symbol: "doc.text.magnifyingglass", accessory: .chevron),
            TVRowItem(id: RowID.about, title: "About Crucible", value: AppInfo.versionSummary, symbol: "info.circle", accessory: .chevron),
            TVRowItem(id: RowID.signOut, title: "Sign Out", symbol: "rectangle.portrait.and.arrow.right", isDestructive: true),
        ])
    }

    private func confirmSignOut() {
        let alert = UIAlertController(title: "Sign Out", message: "Are you sure you want to sign out?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Sign Out", style: .destructive) { [session = env.session] _ in
            session.signOut()
        })
        present(alert, animated: true)
    }
}

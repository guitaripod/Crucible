import CrucibleCore
import CrucibleDesign
import UIKit

final class YouViewController: UICollectionViewController {
    enum Section: Int, Hashable {
        case demo, profile, year, activity, app, about
    }

    enum Item: Hashable {
        case demo, freePreview, profile, switchProfile, year, playlists, watchlist, activity, dashboard, history, statistics, settings, server, about
    }

    private let api: APIClient
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var refreshTask: Task<Void, Never>?
    private var accountName = PlexAccountName.fallbackName
    private var historySubtitle: String?
    private var yearSummary: YouYearSummary?
    private var demoObservation: DemoObservation?

    init(api: APIClient) {
        self.api = api
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        refreshTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "You", comment: "Navigation title of the You tab")
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        view.backgroundColor = Theme.Color.canvas
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.allowsKeyboardFocus()
        collectionView.showsVerticalScrollIndicator = false

        collectionView.collectionViewLayout = makeLayout()
        configureDataSource()
        applySnapshot()

        YouConnectionStatus.shared.onChange = { [weak self] _ in
            self?.reconfigureAll()
        }
        demoObservation = DemoObservation { [weak self] in
            self?.applySnapshot()
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        accountName = PlexAccountName.stored
        applySnapshot()
        YouConnectionStatus.shared.refresh(api: api)
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.loadRemoteContent()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTask?.cancel()
    }

    private func loadRemoteContent() async {
        async let history = YouHistoryHeadline.latest(api: api)
        async let year = YouYearSummary.load()
        async let profiles: Void = refreshHomeProfiles()
        let (newHistory, newYear, _) = await (history, year, profiles)
        guard !Task.isCancelled else { return }
        historySubtitle = newHistory
        yearSummary = newYear
        applySnapshot()
    }

    /// Asks plex.tv how many profiles the account's Home has, which decides whether Switch Profile shows.
    private func refreshHomeProfiles() async {
        guard let token = ServerBootstrap.accountToken else { return }
        _ = try? await HomeProfiles.load(accountToken: token)
    }

    private var offersProfiles: Bool { HomeProfiles.knownCount > 1 }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            let section = self?.dataSource?.sectionIdentifier(for: index)
            if section == .year {
                return Self.yearSection(environment)
            }
            let list = NSCollectionLayoutSection.list(using: .wellRows(), layoutEnvironment: environment)
            var insets = list.contentInsets
            insets.top = section == .demo || (section == .profile && self?.isInDemo == false) ? 14 : 16
            insets.bottom = 0
            list.contentInsets = insets
            Theme.centerReadable(list, environment)
            return list
        }
    }

    /// The year card lines up with the rows under it: 16 points on a phone, the list's own margins and readable width on a large screen.
    private static func yearSection(_ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(176))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 0, trailing: 16)
        if Theme.Room(environment) != .compact {
            let rows = NSCollectionLayoutSection.list(using: .wellRows(), layoutEnvironment: environment).contentInsets
            section.contentInsets.leading = rows.leading
            section.contentInsets.trailing = rows.trailing
            Theme.centerReadable(section, environment)
        }
        return section
    }

    private func configureDataSource() {
        let rowRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            switch item {
            case .demo:
                cell.contentConfiguration = IconRowContentConfiguration(
                    symbol: "list.bullet.clipboard", title: DemoCopy.bannerTitle, value: demoProgress
                )
                cell.accessories = [.disclosureIndicator()]
                cell.accessibilityIdentifier = "you.demo"
            case .freePreview:
                cell.contentConfiguration = IconRowContentConfiguration(
                    symbol: "lock",
                    title: DemoCopy.freePreviewTitle,
                    subtitle: DemoCopy.freePreviewDetail,
                    toggle: .init(isOn: DemoMode.shared.previewsFreeVersion) { DemoMode.shared.setPreviewsFreeVersion($0) }
                )
                cell.accessories = []
                cell.accessibilityIdentifier = "you.demoFreePreview"
            case .profile:
                cell.contentConfiguration = profileConfiguration()
                cell.accessories = isInDemo ? [] : [.disclosureIndicator()]
            case .switchProfile:
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "person.2", title: HomeProfiles.title, value: PlexAccountName.stored)
                cell.accessories = [.disclosureIndicator()]
                cell.accessibilityIdentifier = "you.switchProfile"
            case .playlists:
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "list.bullet.rectangle", title: String(localized: "Playlists"))
                cell.accessories = [.disclosureIndicator()]
                cell.accessibilityIdentifier = "you.playlists"
            case .watchlist:
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "bookmark", title: WatchlistService.title)
                cell.accessories = [.disclosureIndicator()]
                cell.accessibilityIdentifier = "you.watchlist"
            case .activity:
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "dot.radiowaves.left.and.right", title: ServerActivity.title)
                cell.accessories = [.disclosureIndicator()]
                cell.accessibilityIdentifier = "you.activity"
            case .dashboard:
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "gauge.with.dots.needle.33percent", title: ServerDashboardCopy.title)
                cell.accessories = [.disclosureIndicator()]
                cell.accessibilityIdentifier = "you.dashboard"
            case .history:
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "clock", title: String(localized: "Watch History"), subtitle: historySubtitle)
                cell.accessories = [.disclosureIndicator()]
                cell.accessibilityIdentifier = "you.history"
            case .statistics:
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "chart.bar", title: String(localized: "Statistics"))
                cell.accessories = [.disclosureIndicator()]
                cell.accessibilityIdentifier = "you.statistics"
            case .settings:
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "gearshape", title: String(localized: "Settings"))
                cell.accessories = [.disclosureIndicator()]
                cell.accessibilityIdentifier = "you.settings"
            case .server:
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "server.rack", title: String(localized: "Server & Connection"), value: YouConnectionStatus.shared.state.routeSummary)
                cell.accessories = [.disclosureIndicator()]
            case .about:
                cell.contentConfiguration = IconRowContentConfiguration(
                    symbol: "info.circle",
                    title: String(localized: "About Crucible"),
                    value: AppInfo.versionSummary
                )
                cell.accessories = [.disclosureIndicator()]
            case .year:
                break
            }
            cell.applyThemedBackground()
        }

        let yearRegistration = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            guard let summary = self?.yearSummary else { return }
            cell.contentConfiguration = YouYearCardContentConfiguration(summary: summary)
            cell.backgroundConfiguration = .clear()
            cell.configurationUpdateHandler = { cell, state in
                cell.contentView.alpha = state.isHighlighted ? 0.85 : 1
            }
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .year:
                return collectionView.dequeueConfiguredReusableCell(using: yearRegistration, for: indexPath, item: item)
            default:
                return collectionView.dequeueConfiguredReusableCell(using: rowRegistration, for: indexPath, item: item)
            }
        }
    }

    private var isInDemo: Bool { DemoMode.shared.isActive }

    /// The free version can be previewed with a store behind the app, by a viewer who has not bought Pro, which nothing locks.
    private var offersFreePreview: Bool { ProAccess.shared.isStoreBacked && !ProAccess.shared.isPro }

    private var demoProgress: String {
        DemoPhoneTourPlan.progress(steps: DemoTour.shared.steps, completed: DemoTour.shared.completed)
    }

    private func profileConfiguration() -> YouProfileContentConfiguration {
        let profile = YouProfile.make(accountName: accountName, state: YouConnectionStatus.shared.state)
        return YouProfileContentConfiguration(name: profile.name, statusText: profile.statusText, statusColor: profile.tone.color)
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if isInDemo {
            snapshot.appendSections([.demo])
            snapshot.appendItems(offersFreePreview ? [.demo, .freePreview] : [.demo], toSection: .demo)
        }
        snapshot.appendSections([.profile])
        snapshot.appendItems(offersProfiles ? [.profile, .switchProfile] : [.profile], toSection: .profile)
        if yearSummary != nil {
            snapshot.appendSections([.year])
            snapshot.appendItems([.year], toSection: .year)
        }
        snapshot.appendSections([.activity, .app, .about])
        snapshot.appendItems([.history, .statistics, .playlists, .watchlist, .activity] + (ServerOwnership.isOwner() ? [.dashboard] : []), toSection: .activity)
        snapshot.appendItems(isInDemo ? [.settings] : [.settings, .server], toSection: .app)
        snapshot.appendItems([.about], toSection: .about)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func reconfigureAll() {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        let destination: UIViewController
        switch item {
        case .demo: destination = DemoTourViewController()
        case .freePreview:
            DemoMode.shared.setPreviewsFreeVersion(!DemoMode.shared.previewsFreeVersion)
            return
        case .switchProfile:
            let profiles = ProfilesViewController(machineIdentifier: ServerBootstrap.savedMachineIdentifier ?? "")
            profiles.onSwitched = { [weak profiles] in
                (profiles?.view.window?.windowScene?.delegate as? SceneDelegate)?.reconfigureRoot()
            }
            destination = profiles
        case .profile where isInDemo: return
        case .profile, .server: destination = ServerDetailViewController(api: api)
        case .year, .statistics: destination = StatisticsViewController(api: api)
        case .playlists: destination = PlaylistScreens.playlists(api: api)
        case .watchlist: destination = WatchlistScreen.watchlist(api: api)
        case .activity: destination = ActivityScreen.serverActivity(api: api)
        case .dashboard: destination = ServerDashboardViewController(api: api)
        case .history: destination = ActivityHistoryViewController(api: api)
        case .settings: destination = SettingsViewController(api: api)
        case .about: destination = AboutViewController()
        }
        navigationController?.pushViewController(destination, animated: true)
    }
}

import CrucibleCore
import CrucibleDesign
import UIKit

final class YouViewController: UICollectionViewController {
    enum Section: Int, Hashable {
        case profile, year, activity, app, about
    }

    enum Item: Hashable {
        case profile, year, history, statistics, settings, server, about
    }

    private let api: APIClient
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var refreshTask: Task<Void, Never>?
    private var accountName = PlexAccountName.fallbackName
    private var historySubtitle: String?
    private var yearSummary: YouYearSummary?

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
        title = "You"
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        view.backgroundColor = Theme.Color.canvas
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.showsVerticalScrollIndicator = false

        collectionView.collectionViewLayout = makeLayout()
        configureDataSource()
        applySnapshot()

        YouConnectionStatus.shared.onChange = { [weak self] _ in
            self?.reconfigureAll()
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
        let (newHistory, newYear) = await (history, year)
        guard !Task.isCancelled else { return }
        historySubtitle = newHistory
        yearSummary = newYear
        applySnapshot()
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            let section = self?.dataSource?.sectionIdentifier(for: index)
            if section == .year {
                return Self.yearSection()
            }
            let list = NSCollectionLayoutSection.list(using: .wellRows(), layoutEnvironment: environment)
            var insets = list.contentInsets
            insets.top = section == .profile ? 14 : 16
            insets.bottom = 0
            list.contentInsets = insets
            return list
        }
    }

    private static func yearSection() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(176))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 0, trailing: 16)
        return section
    }

    private func configureDataSource() {
        let rowRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            switch item {
            case .profile:
                cell.contentConfiguration = profileConfiguration()
                cell.accessories = [.disclosureIndicator()]
            case .history:
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "clock", title: "Watch History", subtitle: historySubtitle)
                cell.accessories = [.disclosureIndicator()]
            case .statistics:
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "chart.bar", title: "Statistics")
                cell.accessories = [.disclosureIndicator()]
            case .settings:
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "gearshape", title: "Settings")
                cell.accessories = [.disclosureIndicator()]
            case .server:
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "server.rack", title: "Server & Connection", value: YouConnectionStatus.shared.state.routeSummary)
                cell.accessories = [.disclosureIndicator()]
            case .about:
                cell.contentConfiguration = IconRowContentConfiguration(
                    symbol: "info.circle",
                    title: "About Crucible",
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

    private func profileConfiguration() -> YouProfileContentConfiguration {
        let profile = YouProfile.make(accountName: accountName, state: YouConnectionStatus.shared.state)
        return YouProfileContentConfiguration(name: profile.name, statusText: profile.statusText, statusColor: profile.tone.color)
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.profile])
        snapshot.appendItems([.profile], toSection: .profile)
        if yearSummary != nil {
            snapshot.appendSections([.year])
            snapshot.appendItems([.year], toSection: .year)
        }
        snapshot.appendSections([.activity, .app, .about])
        snapshot.appendItems([.history, .statistics], toSection: .activity)
        snapshot.appendItems([.settings, .server], toSection: .app)
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
        case .profile, .server: destination = ServerDetailViewController(api: api)
        case .year, .statistics: destination = StatisticsViewController(api: api)
        case .history: destination = ActivityHistoryViewController(api: api)
        case .settings: destination = SettingsViewController(api: api)
        case .about: destination = AboutViewController()
        }
        navigationController?.pushViewController(destination, animated: true)
    }
}

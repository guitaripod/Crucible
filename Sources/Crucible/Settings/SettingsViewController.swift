@preconcurrency import UIKit

final class SettingsViewController: UICollectionViewController {
    enum Section: Int, CaseIterable {
        case server, libraries, activity, account, about
    }

    enum Item: Hashable {
        case serverName(String)
        case serverURI(String)
        case library(String, String)
        case activityHistory
        case signOut
        case appVersion(String)
    }

    private let api: APIClient
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var loadTask: Task<Void, Never>?

    init(api: APIClient) {
        self.api = api
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        navigationController?.navigationBar.prefersLargeTitles = true

        var listConfig = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        listConfig.headerMode = .supplementary
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout.list(using: listConfig)

        configureDataSource()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        loadData()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
    }

    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            switch item {
            case .serverName(let name):
                var config = UIListContentConfiguration.valueCell()
                config.text = "Server"
                config.secondaryText = name
                cell.contentConfiguration = config
                cell.accessories = []

            case .serverURI(let uri):
                var config = UIListContentConfiguration.valueCell()
                config.text = "Address"
                config.secondaryText = uri
                config.secondaryTextProperties.font = .systemFont(ofSize: 14)
                config.secondaryTextProperties.color = .tertiaryLabel
                cell.contentConfiguration = config
                cell.accessories = []

            case .library(let name, let count):
                var config = UIListContentConfiguration.valueCell()
                config.text = name
                config.secondaryText = count
                cell.contentConfiguration = config
                cell.accessories = []

            case .activityHistory:
                var config = UIListContentConfiguration.cell()
                config.text = "Activity History"
                config.image = UIImage(systemName: "clock")
                cell.contentConfiguration = config
                cell.accessories = [.disclosureIndicator()]

            case .signOut:
                var config = UIListContentConfiguration.cell()
                config.text = "Sign Out"
                config.textProperties.color = .systemRed
                config.image = UIImage(systemName: "rectangle.portrait.and.arrow.right")
                config.imageProperties.tintColor = .systemRed
                cell.contentConfiguration = config
                cell.accessories = []

            case .appVersion(let version):
                var config = UIListContentConfiguration.valueCell()
                config.text = "App Version"
                config.secondaryText = version
                cell.contentConfiguration = config
                cell.accessories = []
            }
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, item in
            cv.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: item)
        }

        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { cell, _, indexPath in
            guard let section = Section(rawValue: indexPath.section) else { return }
            var config = UIListContentConfiguration.groupedHeader()
            switch section {
            case .server: config.text = "Server"
            case .libraries: config.text = "Libraries"
            case .activity: config.text = "Activity"
            case .account: config.text = "Account"
            case .about: config.text = "About"
            }
            cell.contentConfiguration = config
        }
        dataSource.supplementaryViewProvider = { cv, kind, indexPath in
            cv.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    private func loadData() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }

            let connection = ServerBootstrap.connection()
            let serverName = connection?.serverName ?? "Unknown"
            let serverURI = connection?.serverURI.absoluteString ?? "Unknown"

            var libraryItems = [Item]()
            do {
                let container = try await api.requestContainer(.sections)
                guard !Task.isCancelled else { return }
                for dir in container.Directory ?? [] {
                    let sectionContainer = try await api.requestContainer(
                        .sectionItems(sectionId: dir.key, start: 0, size: 0)
                    )
                    let count = sectionContainer.totalSize ?? 0
                    libraryItems.append(.library(dir.title, "\(count) items"))
                }
            } catch {
                guard !Task.isCancelled else { return }
            }

            var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()

            snapshot.appendSections([.server])
            snapshot.appendItems([.serverName(serverName), .serverURI(serverURI)], toSection: .server)

            if !libraryItems.isEmpty {
                snapshot.appendSections([.libraries])
                snapshot.appendItems(libraryItems, toSection: .libraries)
            }

            snapshot.appendSections([.activity])
            snapshot.appendItems([.activityHistory], toSection: .activity)

            snapshot.appendSections([.account])
            snapshot.appendItems([.signOut], toSection: .account)

            snapshot.appendSections([.about])
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            snapshot.appendItems([.appVersion(appVersion)], toSection: .about)

            await dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .activityHistory:
            let vc = ActivityHistoryViewController(api: api)
            navigationController?.pushViewController(vc, animated: true)

        case .signOut:
            let alert = UIAlertController(title: "Sign Out", message: "Are you sure you want to sign out?", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Sign Out", style: .destructive) { [weak self] _ in
                guard let self else { return }
                ServerBootstrap.clear()
                if let scene = view.window?.windowScene?.delegate as? SceneDelegate {
                    scene.reconfigureRoot()
                }
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            present(alert, animated: true)

        default:
            break
        }
    }
}

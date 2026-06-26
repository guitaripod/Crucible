@preconcurrency import UIKit

final class SettingsViewController: UICollectionViewController {
    enum Section: Int, CaseIterable {
        case server, libraries, playback, activity, storage, account, about
    }

    enum Item: Hashable {
        case serverName(String)
        case serverURI(String)
        case library(key: String, type: String, name: String, count: String)
        case quality(String)
        case activityHistory
        case clearCache
        case signOut
        case sourceCode
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
                config.image = UIImage(systemName: "server.rack")
                config.imageProperties.tintColor = .systemOrange
                cell.contentConfiguration = config
                cell.accessories = []

            case .serverURI(let uri):
                var config = UIListContentConfiguration.valueCell()
                config.text = "Address"
                config.secondaryText = uri
                config.secondaryTextProperties.font = .systemFont(ofSize: 13)
                config.secondaryTextProperties.color = .tertiaryLabel
                config.image = UIImage(systemName: "network")
                config.imageProperties.tintColor = .tertiaryLabel
                cell.contentConfiguration = config
                cell.accessories = []

            case .library(_, _, let name, let count):
                var config = UIListContentConfiguration.valueCell()
                config.text = name
                config.secondaryText = count
                config.image = UIImage(systemName: "rectangle.stack.fill")
                config.imageProperties.tintColor = .systemOrange
                cell.contentConfiguration = config
                cell.accessories = [.disclosureIndicator()]

            case .quality(let current):
                var config = UIListContentConfiguration.valueCell()
                config.text = "Streaming Quality"
                config.secondaryText = current
                config.image = UIImage(systemName: "dial.high.fill")
                config.imageProperties.tintColor = .systemOrange
                cell.contentConfiguration = config
                cell.accessories = [.disclosureIndicator()]

            case .clearCache:
                var config = UIListContentConfiguration.cell()
                config.text = "Clear Image Cache"
                config.image = UIImage(systemName: "trash")
                config.imageProperties.tintColor = .systemOrange
                cell.contentConfiguration = config
                cell.accessories = []

            case .sourceCode:
                var config = UIListContentConfiguration.valueCell()
                config.text = "Source Code"
                config.secondaryText = "GitHub"
                config.image = UIImage(systemName: "chevron.left.forwardslash.chevron.right")
                config.imageProperties.tintColor = .systemOrange
                cell.contentConfiguration = config
                cell.accessories = [.disclosureIndicator()]

            case .activityHistory:
                var config = UIListContentConfiguration.cell()
                config.text = "Activity History"
                config.image = UIImage(systemName: "clock.fill")
                config.imageProperties.tintColor = .systemOrange
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
                config.text = "Version"
                config.secondaryText = version
                config.image = UIImage(systemName: "info.circle.fill")
                config.imageProperties.tintColor = .tertiaryLabel
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
            case .playback: config.text = "Playback"
            case .activity: config.text = "Activity"
            case .storage: config.text = "Storage"
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
                    guard let key = dir.key else { continue }
                    let sectionContainer = try await api.requestContainer(
                        .sectionItems(sectionId: key, start: 0, size: 0)
                    )
                    let count = sectionContainer.totalSize ?? 0
                    libraryItems.append(.library(key: key, type: dir.type ?? "movie", name: dir.title ?? "Library", count: "\(count) items"))
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

            snapshot.appendSections([.playback])
            snapshot.appendItems([.quality(Preferences.streamingQuality.title)], toSection: .playback)

            snapshot.appendSections([.activity])
            snapshot.appendItems([.activityHistory], toSection: .activity)

            snapshot.appendSections([.storage])
            snapshot.appendItems([.clearCache], toSection: .storage)

            snapshot.appendSections([.account])
            snapshot.appendItems([.signOut], toSection: .account)

            snapshot.appendSections([.about])
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            snapshot.appendItems([.sourceCode, .appVersion(appVersion)], toSection: .about)

            await dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .library(let key, let type, let name, _):
            let vc: UIViewController = type == "show"
                ? ShowGridViewController(api: api, sectionId: key)
                : MovieGridViewController(api: api, sectionId: key)
            vc.title = name
            navigationController?.pushViewController(vc, animated: true)

        case .quality:
            let sheet = UIAlertController(title: "Streaming Quality", message: "Original direct-plays when the device supports the file; lower settings transcode to save bandwidth.", preferredStyle: .actionSheet)
            for quality in Preferences.Quality.allCases {
                let isCurrent = quality == Preferences.streamingQuality
                sheet.addAction(UIAlertAction(title: isCurrent ? "\(quality.title)  ✓" : quality.title, style: .default) { [weak self] _ in
                    Preferences.streamingQuality = quality
                    self?.loadData()
                })
            }
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            if let popover = sheet.popoverPresentationController, let cell = collectionView.cellForItem(at: indexPath) {
                popover.sourceView = cell
                popover.sourceRect = cell.bounds
            }
            present(sheet, animated: true)

        case .clearCache:
            Task { await ImageLoader.shared.clearCache() }
            let alert = UIAlertController(title: "Image Cache Cleared", message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)

        case .sourceCode:
            if let url = URL(string: "https://github.com/guitaripod/Crucible") {
                UIApplication.shared.open(url)
            }

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

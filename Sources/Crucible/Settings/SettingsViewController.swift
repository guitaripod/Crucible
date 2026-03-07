@preconcurrency import UIKit

final class SettingsViewController: UICollectionViewController {
    enum Section: Int, CaseIterable {
        case server, library, activity, about
    }

    enum Item: Hashable {
        case serverURL(String)
        case serverVersion(String)
        case stat(String, String)
        case scanButton
        case refreshButton
        case scanStatus(String)
        case activityHistory
        case appVersion(String)
        case configItem(String, String)
    }

    private let api: APIClient
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var loadTask: Task<Void, Never>?
    private var wsTask: Task<Void, Never>?
    private var currentScanStatus: String = "Idle"

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
        connectWebSocket()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
        wsTask?.cancel()
    }

    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            switch item {
            case .serverURL(let url):
                var config = UIListContentConfiguration.valueCell()
                config.text = "Server"
                config.secondaryText = url
                cell.contentConfiguration = config
                cell.accessories = [.disclosureIndicator()]

            case .serverVersion(let version):
                var config = UIListContentConfiguration.valueCell()
                config.text = "Server Version"
                config.secondaryText = version
                cell.contentConfiguration = config
                cell.accessories = []

            case .stat(let label, let value):
                var config = UIListContentConfiguration.valueCell()
                config.text = label
                config.secondaryText = value
                cell.contentConfiguration = config
                cell.accessories = []

            case .scanButton:
                var config = UIListContentConfiguration.cell()
                config.text = "Scan Library"
                config.image = UIImage(systemName: "arrow.clockwise")
                config.textProperties.color = .systemBlue
                cell.contentConfiguration = config
                cell.accessories = []

            case .refreshButton:
                var config = UIListContentConfiguration.cell()
                config.text = "Refresh Metadata"
                config.image = UIImage(systemName: "arrow.triangle.2.circlepath")
                config.textProperties.color = .systemBlue
                cell.contentConfiguration = config
                cell.accessories = []

            case .scanStatus(let status):
                var config = UIListContentConfiguration.cell()
                config.text = status
                config.textProperties.color = .secondaryLabel
                config.textProperties.font = .systemFont(ofSize: 14)
                cell.contentConfiguration = config
                cell.accessories = []

            case .activityHistory:
                var config = UIListContentConfiguration.cell()
                config.text = "Activity History"
                config.image = UIImage(systemName: "clock")
                cell.contentConfiguration = config
                cell.accessories = [.disclosureIndicator()]

            case .appVersion(let version):
                var config = UIListContentConfiguration.valueCell()
                config.text = "App Version"
                config.secondaryText = version
                cell.contentConfiguration = config
                cell.accessories = []

            case .configItem(let label, let value):
                var config = UIListContentConfiguration.valueCell()
                config.text = label
                config.secondaryText = value
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
            case .library: config.text = "Library"
            case .activity: config.text = "Activity"
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

            var healthVersion = "Unknown"
            var statsItems = [Item]()
            var configItems = [Item]()

            do {
                async let healthReq: HealthResponse = api.request(.health)
                async let statsReq: StatsResponse = api.request(.stats)
                async let configReq: SystemConfigResponse = api.request(.config)

                let (health, stats, config) = try await (healthReq, statsReq, configReq)
                guard !Task.isCancelled else { return }

                healthVersion = health.version

                statsItems = [
                    .stat("Movies", "\(stats.movies)"),
                    .stat("Episodes", "\(stats.episodes)"),
                    .stat("Shows", "\(stats.shows)"),
                    .stat("Total Size", Formatters.fileSize(stats.totalSizeBytes)),
                    .stat("Total Duration", Formatters.duration(stats.totalDurationSecs)),
                ]

                configItems = [
                    .configItem("Scan Interval", "\(config.library.scanIntervalSecs / 60) min"),
                    .configItem("Max Transcodes", "\(config.transcoding.maxConcurrentTranscodes)"),
                    .configItem("TMDB", config.tmdb.hasApiKey ? "Configured" : "Not configured"),
                ]
            } catch {
                guard !Task.isCancelled else { return }
            }

            var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()

            snapshot.appendSections([.server])
            snapshot.appendItems([
                .serverURL(api.baseURL.absoluteString),
                .serverVersion(healthVersion),
            ], toSection: .server)

            snapshot.appendSections([.library])
            snapshot.appendItems(statsItems, toSection: .library)
            snapshot.appendItems([.scanButton, .refreshButton, .scanStatus(currentScanStatus)], toSection: .library)

            snapshot.appendSections([.activity])
            snapshot.appendItems([.activityHistory], toSection: .activity)

            snapshot.appendSections([.about])
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            snapshot.appendItems([.appVersion(appVersion)], toSection: .about)
            snapshot.appendItems(configItems, toSection: .about)

            await dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    private func connectWebSocket() {
        wsTask?.cancel()
        wsTask = Task { [weak self] in
            guard let self else { return }
            guard var components = URLComponents(url: api.baseURL.appendingPathComponent("/api/system/ws"), resolvingAgainstBaseURL: false) else { return }
            components.scheme = api.baseURL.scheme == "https" ? "wss" : "ws"
            guard let wsURL = components.url else { return }

            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: wsURL)
            task.resume()

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase

            defer { task.cancel(with: .goingAway, reason: nil) }

            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard !Task.isCancelled else { return }
                    if case .string(let text) = message,
                       let data = text.data(using: .utf8),
                       let status = try? decoder.decode(ScanStatusResponse.self, from: data)
                    {
                        let statusText: String
                        switch status.status {
                        case "scanning":
                            if let items = status.itemsFound {
                                statusText = "Scanning... \(items) items found"
                            } else {
                                statusText = "Scanning..."
                            }
                        case "fetching_metadata":
                            statusText = "Fetching metadata..."
                        default:
                            statusText = "Idle"
                        }
                        currentScanStatus = statusText
                        updateScanStatusInSnapshot(statusText)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    private func updateScanStatusInSnapshot(_ status: String) {
        Task { [weak self] in
            guard let self else { return }
            var snapshot = dataSource.snapshot()
            let oldItems = snapshot.itemIdentifiers(inSection: .library)
            if let oldStatus = oldItems.first(where: {
                if case .scanStatus = $0 { return true }
                return false
            }) {
                snapshot.deleteItems([oldStatus])
                snapshot.appendItems([.scanStatus(status)], toSection: .library)
                await dataSource.apply(snapshot, animatingDifferences: false)
            }
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .serverURL:
            let setup = ServerSetupViewController()
            setup.onConnected = { [weak self] _ in
                guard let self else { return }
                if let scene = self.view.window?.windowScene?.delegate as? SceneDelegate {
                    scene.reconfigureRoot()
                }
            }
            let nav = UINavigationController(rootViewController: setup)
            present(nav, animated: true)

        case .scanButton:
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await api.requestVoid(.triggerScan)
                } catch let error as APIError {
                    if case .httpError(409, _) = error {
                        let alert = UIAlertController(title: nil, message: "Scan already in progress", preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "OK", style: .default))
                        present(alert, animated: true)
                    }
                }
            }

        case .refreshButton:
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await api.requestVoid(.triggerRefresh)
                } catch let error as APIError {
                    let message: String
                    switch error {
                    case .httpError(400, _): message = "No TMDB API key configured"
                    case .httpError(409, _): message = "Scan already in progress"
                    default: message = error.localizedDescription
                    }
                    let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    present(alert, animated: true)
                }
            }

        case .activityHistory:
            let vc = ActivityHistoryViewController(api: api)
            navigationController?.pushViewController(vc, animated: true)

        default:
            break
        }
    }
}

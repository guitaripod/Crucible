import UIKit

/// Server & Connection screen: the active server, every known route with its latency, and the
/// connection preferences.
final class ServerDetailViewController: UIViewController {
    private enum Section: Int, CaseIterable {
        case server, connections, preferences, test, actions
    }

    private enum Item: Hashable {
        case server
        case route(URL)
        case preferLocal
        case allowRelay
        case test
        case addServer
        case switchServer
    }

    private enum ProbeState {
        case probing
        case reachable(Int)
        case unreachable
    }

    private let api: APIClient
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var routes: [URL] = []
    private var probes: [URL: ProbeState] = [:]
    private var relayRoutes: Set<URL> = []
    private var version: String?
    private var isOwned: Bool?
    private var isTesting = false
    private var probeTask: Task<Void, Never>?

    init(api: APIClient) {
        self.api = api
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { probeTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Server"
        navigationItem.largeTitleDisplayMode = .always
        view.backgroundColor = Theme.Color.canvas

        routes = Self.currentRoutes(activeURL: activeRouteURL)

        configureCollectionView()
        configureDataSource()
        applySnapshot()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if probeTask == nil && probes.isEmpty {
            runProbes()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed {
            probeTask?.cancel()
            probeTask = nil
        }
    }

    /// The route the app is pinned to; failover repins update the persisted connection.
    private var activeRouteURL: URL {
        ServerBootstrap.connection()?.serverURI ?? URL(string: "http://localhost:32400")!
    }

    private static func currentRoutes(activeURL: URL) -> [URL] {
        var routes = ServerBootstrap.connection()?.candidateURIs ?? []
        if !routes.contains(activeURL) {
            routes.insert(activeURL, at: 0)
        }
        return routes
    }

    private func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { sectionIndex, environment in
            var config = Theme.groupedListConfiguration()
            let section = Section(rawValue: sectionIndex)
            config.headerMode = section == .connections ? .supplementary : .none
            config.showsSeparators = section != .server && section != .test
            let layoutSection = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            if section == .test {
                layoutSection.contentInsets.top = Theme.Space.s
            }
            return layoutSection
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.showsVerticalScrollIndicator = false
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.runProbes() }, for: .valueChanged)
        collectionView.refreshControl = refresh
    }

    private func configureDataSource() {
        let serverCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.contentConfiguration = serverCardConfiguration()
            cell.backgroundConfiguration = Theme.groupedCellBackground()
        }

        let routeCell = UICollectionView.CellRegistration<UICollectionViewListCell, URL> { [weak self] cell, _, url in
            guard let self else { return }
            cell.contentConfiguration = routeConfiguration(for: url)
            cell.backgroundConfiguration = Theme.groupedCellBackground()
        }

        let toggleCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            let isPreferLocal = item == .preferLocal
            var content = UIListContentConfiguration.cell()
            content.text = isPreferLocal ? "Prefer Local Connection" : "Allow Relay"
            content.textProperties.font = Theme.Font.scaled(.body, 16, .regular)
            content.textProperties.color = Theme.Color.label

            let toggle = UISwitch()
            toggle.isOn = isPreferLocal ? Preferences.preferLocalConnection : Preferences.allowRelayConnection
            toggle.onTintColor = Theme.Color.accent
            toggle.accessibilityLabel = content.text
            toggle.addAction(UIAction { action in
                guard let toggle = action.sender as? UISwitch else { return }
                if isPreferLocal {
                    Preferences.preferLocalConnection = toggle.isOn
                } else {
                    Preferences.allowRelayConnection = toggle.isOn
                }
                Haptics.selection()
            }, for: .valueChanged)

            cell.contentConfiguration = content
            cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing(displayed: .always)))]
            cell.backgroundConfiguration = Theme.groupedCellBackground()
        }

        let testCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.contentConfiguration = TestButtonConfiguration(isTesting: isTesting) { [weak self] in self?.runProbes() }
            cell.backgroundConfiguration = .clear()
        }

        let actionCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            switch item {
            case .addServer:
                cell.contentConfiguration = ActionRowConfiguration(symbol: "plus", title: "Add Server by Address…", isAccent: true)
            default:
                cell.contentConfiguration = ActionRowConfiguration(symbol: "arrow.left.arrow.right", title: "Switch Server", showsChevron: true)
            }
            cell.backgroundConfiguration = Theme.groupedCellBackground()
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .server:
                return collectionView.dequeueConfiguredReusableCell(using: serverCell, for: indexPath, item: item)
            case .route(let url):
                return collectionView.dequeueConfiguredReusableCell(using: routeCell, for: indexPath, item: url)
            case .preferLocal, .allowRelay:
                return collectionView.dequeueConfiguredReusableCell(using: toggleCell, for: indexPath, item: item)
            case .test:
                return collectionView.dequeueConfiguredReusableCell(using: testCell, for: indexPath, item: item)
            case .addServer, .switchServer:
                return collectionView.dequeueConfiguredReusableCell(using: actionCell, for: indexPath, item: item)
            }
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { header, _, _ in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = "Connections"
            content.textProperties.font = Theme.Font.footnoteSemibold
            content.textProperties.color = Theme.Color.labelSecondary
            content.textProperties.transform = .uppercase
            header.contentConfiguration = content
            header.accessibilityTraits = .header
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems([.server], toSection: .server)
        snapshot.appendItems(routes.map { .route($0) }, toSection: .connections)
        snapshot.appendItems([.preferLocal, .allowRelay], toSection: .preferences)
        snapshot.appendItems([.test], toSection: .test)
        snapshot.appendItems([.addServer, .switchServer], toSection: .actions)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func reconfigureLive() {
        var snapshot = dataSource.snapshot()
        let live: [Item] = [.server, .test] + routes.map { .route($0) }
        snapshot.reconfigureItems(live.filter { snapshot.indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func kind(of url: URL) -> ConnectionKind {
        relayRoutes.contains(url) ? .relay : ConnectionRoute.kind(of: url)
    }

    private func serverCardConfiguration() -> ServerCardConfiguration {
        let connection = ServerBootstrap.connection()
        var subtitle = "Plex Media Server"
        if let version { subtitle += " \(version)" }
        if let isOwned { subtitle += isOwned ? " · Owned by you" : " · Shared with you" }

        let activeURL = activeRouteURL
        let status: String
        let color: UIColor
        switch probes[activeURL] {
        case .reachable(let milliseconds):
            let https = ConnectionRoute.isHTTPS(activeURL) ? "HTTPS" : "HTTP"
            status = "Connected · \(kind(of: activeURL).title) · \(https) · \(milliseconds) ms"
            color = Theme.Color.statusOK
        case .unreachable:
            status = "Unreachable · \(kind(of: activeURL).title)"
            color = Theme.Color.destructive
        case .probing, nil:
            status = "Checking connection…"
            color = Theme.Color.labelTertiary
        }
        return ServerCardConfiguration(name: connection?.serverName ?? "Plex Server", subtitle: subtitle, status: status, statusColor: color)
    }

    private func routeConfiguration(for url: URL) -> RouteRowConfiguration {
        let routeKind = kind(of: url)
        let isRelay = routeKind == .relay
        let state = probes[url]

        let latency: String
        switch state {
        case .reachable(let milliseconds): latency = "\(milliseconds) ms"
        case .unreachable: latency = "Unreachable"
        case .probing, nil: latency = "…"
        }

        var isUnreachable = false
        if case .unreachable = state { isUnreachable = true }

        return RouteRowConfiguration(
            kindTitle: routeKind.title,
            isInUse: url == activeRouteURL,
            detail: isRelay ? "Bandwidth limited, may force transcoding" : url.absoluteString,
            detailIsMonospaced: !isRelay,
            latencyText: latency,
            showsWarning: isRelay,
            isDimmed: isRelay || isUnreachable
        )
    }

    private func runProbes() {
        probeTask?.cancel()
        let urls = routes
        let token = ServerBootstrap.connection()?.authToken ?? ""
        for url in urls { probes[url] = .probing }
        isTesting = true
        reconfigureLive()

        probeTask = Task { [weak self] in
            async let resources = Self.fetchServerResource(token: token)
            await withTaskGroup(of: (URL, ConnectionProbe?).self) { group in
                for url in urls {
                    group.addTask { (url, await ConnectionProber.probe(baseURL: url, token: token)) }
                }
                for await (url, probe) in group {
                    guard !Task.isCancelled else { return }
                    self?.record(probe, for: url)
                }
            }
            let resource = await resources
            guard !Task.isCancelled, let self else { return }
            apply(resource)
            finishProbing()
        }
    }

    private func record(_ probe: ConnectionProbe?, for url: URL) {
        if let probe {
            probes[url] = .reachable(probe.latencyMs)
            if let found = probe.version, version == nil || url == activeRouteURL { version = found }
        } else {
            probes[url] = .unreachable
        }
        reconfigureLive()
    }

    private func apply(_ resource: PlexResource?) {
        guard let resource else { return }
        isOwned = resource.owned
        relayRoutes = Set(resource.connections.filter { $0.relay == true }.compactMap { URL(string: $0.uri) })
    }

    private func finishProbing() {
        probeTask = nil
        isTesting = false
        reconfigureLive()
        if collectionView.refreshControl?.isRefreshing == true {
            collectionView.refreshControl?.endRefreshing()
            Haptics.soft()
        }
        AppLogger.info("Connection test finished: \(probes.count) routes", .networking)
    }

    /// The signed-in account's plex.tv record for the connected server, if plex.tv is reachable.
    private static func fetchServerResource(token: String) async -> PlexResource? {
        guard let machineIdentifier = ServerBootstrap.connection()?.machineIdentifier else { return nil }
        let resources: [PlexResource]? = try? await APIClient.plexTVRequest(.resources, token: token)
        return resources?.first { $0.clientIdentifier == machineIdentifier && $0.provides.contains("server") }
    }

    private func presentAddServer() {
        guard let token = ServerBootstrap.connection()?.authToken else { return }
        let sheet = AddServerSheetViewController(token: token)
        sheet.onSaved = { [weak self] in self?.reconfigureRoot() }
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.medium()]
            presentation.prefersGrabberVisible = true
        }
        present(sheet, animated: true)
    }

    private func presentServerSwitcher() {
        let setup = ServerSetupViewController()
        setup.allowsCancel = true
        setup.onConnected = { [weak self] _ in self?.reconfigureRoot() }
        let nav = UINavigationController(rootViewController: setup)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    private func reconfigureRoot() {
        let delegate = (view.window?.windowScene ?? presentedViewController?.view.window?.windowScene)?.delegate
        (delegate as? SceneDelegate)?.reconfigureRoot()
    }
}

extension ServerDetailViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .addServer, .switchServer: return true
        default: return false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .addServer: presentAddServer()
        case .switchServer: presentServerSwitcher()
        default: break
        }
    }
}

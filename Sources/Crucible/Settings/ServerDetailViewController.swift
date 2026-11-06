import CrucibleCore
import CrucibleDesign
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
        case tailnetAccess
        case switchServer
    }

    private let api: APIClient
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var model: ServerConnectionModel!

    init(api: APIClient) {
        self.api = api
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Server")
        navigationItem.largeTitleDisplayMode = .always
        view.backgroundColor = Theme.Color.canvas

        model = ServerConnectionModel()
        model.onChange = { [weak self] in self?.modelChanged() }
        model.onFinish = { [weak self] in self?.finishProbing() }

        configureCollectionView()
        configureDataSource()
        applySnapshot()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        model.startIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed {
            model.stop()
        }
    }

    private func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { sectionIndex, environment in
            var config = Theme.groupedListConfiguration()
            let section = Section(rawValue: sectionIndex)
            config.headerMode = section == .connections ? .supplementary : .none
            config.footerMode = section == .connections ? .supplementary : .none
            config.showsSeparators = section != .server && section != .test
            let layoutSection = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            if section == .test {
                layoutSection.contentInsets.top = Theme.Space.s
            }
            Theme.centerReadable(layoutSection, environment)
            return layoutSection
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.allowsKeyboardFocus()
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
        refresh.addAction(UIAction { [weak self] _ in self?.model.runTest() }, for: .valueChanged)
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
            let setting: PreferenceSetting = item == .preferLocal ? .preferLocalConnection : .allowRelayConnection
            var content = UIListContentConfiguration.cell()
            content.text = setting.title
            content.textProperties.font = Theme.Font.scaled(.body, 16, .regular)
            content.textProperties.color = Theme.Color.label

            let toggle = UISwitch()
            toggle.isOn = setting.isOn
            toggle.onTintColor = Theme.Color.accent
            toggle.accessibilityLabel = content.text
            toggle.addAction(UIAction { action in
                guard let toggle = action.sender as? UISwitch else { return }
                setting.setOn(toggle.isOn)
                Haptics.selection()
            }, for: .valueChanged)

            cell.contentConfiguration = content
            cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing(displayed: .always)))]
            cell.backgroundConfiguration = Theme.groupedCellBackground()
        }

        let testCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.contentConfiguration = TestButtonConfiguration(isTesting: model.isTesting) { [weak self] in self?.model.runTest() }
            cell.backgroundConfiguration = .clear()
        }

        let actionCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            switch item {
            case .addServer:
                cell.contentConfiguration = ActionRowConfiguration(symbol: "plus", title: String(localized: "Add Server by Address…"), isAccent: true)
            case .tailnetAccess:
                cell.contentConfiguration = ActionRowConfiguration(symbol: "network", title: String(localized: "Tailscale Search"), value: Self.tailnetAccessValue, showsChevron: true)
            default:
                cell.contentConfiguration = ActionRowConfiguration(symbol: "arrow.left.arrow.right", title: String(localized: "Switch Server"), showsChevron: true)
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
            case .addServer, .tailnetAccess, .switchServer:
                return collectionView.dequeueConfiguredReusableCell(using: actionCell, for: indexPath, item: item)
            }
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { header, _, _ in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = String(localized: "Connections")
            content.textProperties.font = Theme.Font.footnoteSemibold
            content.textProperties.color = Theme.Color.labelSecondary
            content.textProperties.transform = .uppercase
            header.contentConfiguration = content
            header.accessibilityTraits = .header
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { footer, _, _ in
            var content = UIListContentConfiguration.groupedFooter()
            content.text = ServerConnectionModel.routesFooter
            content.textProperties.color = Theme.Color.labelSecondary
            footer.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionFooter
                ? collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    /// Uses the route picked until the network changes; a route that does not answer as the server is refused with a word why.
    private func use(_ url: URL) {
        Task { [weak self] in
            guard let self else { return }
            if await model.use(url) {
                Haptics.success()
                reconfigureLive()
                return
            }
            Haptics.error()
            let alert = UIAlertController(
                title: String(localized: "Couldn\u{2019}t Use This Connection", comment: "Alert when a picked server connection does not answer"),
                message: String(localized: "It didn\u{2019}t answer as your server, so Crucible stays on the connection it uses now.", comment: "Alert when a picked server connection does not answer"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
            present(alert, animated: true)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems([.server], toSection: .server)
        snapshot.appendItems(model.routes.map { .route($0) }, toSection: .connections)
        snapshot.appendItems([.preferLocal, .allowRelay], toSection: .preferences)
        snapshot.appendItems([.test], toSection: .test)
        snapshot.appendItems([.addServer, .tailnetAccess, .switchServer], toSection: .actions)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// New or dropped routes rebuild the list; otherwise the rows on screen are redrawn in place.
    private func modelChanged() {
        let shown = dataSource.snapshot().itemIdentifiers(inSection: .connections)
        guard shown == model.routes.map({ .route($0) }) else {
            applySnapshot()
            return
        }
        reconfigureLive()
    }

    private func reconfigureLive() {
        var snapshot = dataSource.snapshot()
        let live: [Item] = [.server, .test] + model.routes.map { .route($0) }
        snapshot.reconfigureItems(live.filter { snapshot.indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func serverCardConfiguration() -> ServerCardConfiguration {
        let card = model.card
        return ServerCardConfiguration(name: card.name, subtitle: card.subtitle, status: card.status, statusColor: card.tone.color)
    }

    private func routeConfiguration(for url: URL) -> RouteRowConfiguration {
        let row = model.routeRow(for: url)
        return RouteRowConfiguration(
            kindTitle: row.kindTitle,
            isInUse: row.isInUse,
            detail: row.detail,
            detailIsMonospaced: row.detailIsMonospaced,
            latencyText: row.latencyText,
            showsWarning: row.showsWarning,
            isDimmed: row.isDimmed
        )
    }

    private func finishProbing() {
        if collectionView.refreshControl?.isRefreshing == true {
            collectionView.refreshControl?.endRefreshing()
            Haptics.soft()
        }
    }

    private func presentAddServer() {
        guard let token = model.authToken else { return }
        let sheet = AddServerSheetViewController(token: token)
        sheet.modalPresentationStyle = .formSheet
        sheet.onSaved = { [weak self] in self?.reconfigureRoot() }
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.medium()]
            presentation.prefersGrabberVisible = true
        }
        present(sheet, animated: true)
    }

    private static var tailnetAccessValue: String {
        switch TailnetAccess.state {
        case .none: return String(localized: "Off")
        case .saved: return String(localized: "On")
        case .rejected: return String(localized: "Needs a new token")
        }
    }

    private func presentTailnetAccess() {
        let sheet = TailnetAccessSheetViewController()
        sheet.onChange = { [weak self] in
            guard let self else { return }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems([.tailnetAccess])
            dataSource.apply(snapshot, animatingDifferences: false)
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
        case .addServer, .tailnetAccess, .switchServer: return true
        case .route: return true
        default: return false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .addServer: presentAddServer()
        case .tailnetAccess: presentTailnetAccess()
        case .switchServer: presentServerSwitcher()
        case .route(let url): use(url)
        default: break
        }
    }
}

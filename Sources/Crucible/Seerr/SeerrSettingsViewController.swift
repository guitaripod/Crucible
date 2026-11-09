import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

/// Settings › Integrations › Seerr: finds the viewer's Seerr next to their Plex server and signs in with their Plex account,
/// then shows who they are there, what they may request and their requests.
final class SeerrSettingsViewController: UICollectionViewController {
    private enum Section: Int {
        case about, connect, account
    }

    private enum Row: Hashable {
        case pitch(Int)
        case privacy
        case message(String)
        case searching
        case found
        case connect
        case guide
        case enterAddress
        case apiKey
        case connecting
        case user
        case address
        case rights
        case requests
        case disconnect
    }

    private enum Discovery: Equatable {
        case idle
        case searching
        case found(URL, SeerrPublicSettings)
        case notFound
    }

    private let api: APIClient
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!
    private var observation: UUID?
    private var discovery = Discovery.idle
    private var isConnecting = false
    private var pendingApprovals = 0

    init(api: APIClient) {
        self.api = api
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observation { Task { @MainActor in SeerrAccount.shared.stopObserving(observation) } }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = SeerrCopy.name
        navigationItem.largeTitleDisplayMode = .never
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.accessibilityIdentifier = "settings.seerr"
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            var config = UICollectionLayoutListConfiguration.wellRows()
            config.footerMode = .supplementary
            if self?.dataSource?.sectionIdentifier(for: index) == .about { config.itemSeparatorHandler = nil }
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            Theme.centerReadable(section, environment)
            return section
        }
        configureDataSource()
        applySnapshot()
        observation = SeerrAccount.shared.observe { [weak self] in
            self?.applySnapshot()
            self?.loadApprovals()
        }
        discoverIfNeeded()
        loadApprovals()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        lookAgainIfNothingUsable()
        applySnapshot()
    }

    /// Coming back from the guide or another app, a Seerr that was missing or unfinished may be ready now.
    private func lookAgainIfNothingUsable() {
        switch discovery {
        case .notFound: break
        case .found(_, let settings) where settings.initialized == false: break
        default: return
        }
        discovery = .idle
        discoverIfNeeded()
    }

    private var account: SeerrAccount { .shared }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        switch account.status {
        case .restricted:
            snapshot.appendSections([.about])
            snapshot.appendItems([.message(SeerrCopy.restricted)], toSection: .about)
        case .disconnected:
            snapshot.appendSections([.about, .connect])
            snapshot.appendItems([.pitch(0), .pitch(1), .pitch(2), .privacy], toSection: .about)
            snapshot.appendItems(connectRows, toSection: .connect)
        case .needsReconnect:
            snapshot.appendSections([.about, .account])
            snapshot.appendItems([.message(SeerrCopy.needsReconnect), isConnecting ? .connecting : .connect], toSection: .about)
            snapshot.appendItems([.address, .disconnect], toSection: .account)
        case .connected:
            snapshot.appendSections([.account])
            snapshot.appendItems([.user, .address, .rights, .requests, .disconnect], toSection: .account)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private var connectRows: [Row] {
        if isConnecting { return [.connecting] }
        switch discovery {
        case .idle, .searching: return [.searching, .guide, .enterAddress]
        case .found(_, let settings) where settings.initialized == false: return [.message(SeerrGuide.needsSetup), .guide, .enterAddress]
        case .found: return [.found, .connect, .enterAddress, .apiKey]
        case .notFound: return [.message(SeerrCopy.notFound), .guide, .enterAddress, .apiKey]
        }
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            self?.configure(cell, row: row)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: row)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] cell, _, indexPath in
            var content = UIListContentConfiguration.groupedFooter()
            guard let self else { return }
            content.text = indexPath.section == dataSource.snapshot().numberOfSections - 1 ? SeerrCopy.worksWith : nil
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func configure(_ cell: UICollectionViewListCell, row: Row) {
        cell.accessories = []
        cell.applyThemedBackground()
        cell.accessibilityIdentifier = "seerr.\(Self.identifier(row))"
        cell.accessibilityTraits = []
        switch row {
        case .pitch(let index):
            let lines = [("plus.circle", SeerrCopy.pitchRequest), ("arrow.down.circle", SeerrCopy.pitchState), ("bell.badge", SeerrCopy.pitchArrival)]
            var content = UIListContentConfiguration.cell()
            content.image = UIImage(systemName: lines[index].0)
            content.imageProperties.tintColor = Theme.Color.accent
            content.text = lines[index].1
            content.textProperties.font = Theme.Font.subheadline
            content.textProperties.color = Theme.Color.label
            cell.contentConfiguration = content
        case .privacy:
            var content = UIListContentConfiguration.cell()
            content.image = UIImage(systemName: "house")
            content.imageProperties.tintColor = Theme.Color.labelSecondary
            content.text = SeerrCopy.privacy
            content.textProperties.font = Theme.Font.footnote
            content.textProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
        case .message(let text):
            cell.contentConfiguration = IconRowContentConfiguration(symbol: "info.circle", title: text)
        case .searching:
            cell.contentConfiguration = IconRowContentConfiguration(symbol: "dot.radiowaves.left.and.right", title: SeerrCopy.searching)
            cell.accessories = [.customView(configuration: .init(customView: Self.spinner(), placement: .trailing()))]
        case .found:
            guard case .found(let address, let settings) = discovery else { break }
            let name = SeerrConnection(address: address, auth: .plex, title: settings.applicationTitle).displayName
            cell.contentConfiguration = IconRowContentConfiguration(symbol: "checkmark.circle.fill", title: SeerrCopy.found, subtitle: name)
        case .connect:
            cell.contentConfiguration = Self.button(account.status == .disconnected ? SeerrCopy.connect : SeerrCopy.reconnect, color: Theme.Color.accentText, bold: true)
            cell.accessibilityTraits = .button
        case .guide:
            cell.contentConfiguration = IconRowContentConfiguration(symbol: "list.number", title: SeerrGuide.title, subtitle: SeerrCopy.guideSubtitle)
            cell.accessories = [.disclosureIndicator()]
            cell.accessibilityTraits = .button
        case .enterAddress:
            cell.contentConfiguration = IconRowContentConfiguration(symbol: "keyboard", title: SeerrCopy.enterAddress)
            cell.accessibilityTraits = .button
        case .apiKey:
            cell.contentConfiguration = IconRowContentConfiguration(symbol: "key", title: SeerrCopy.useAPIKey)
            cell.accessibilityTraits = .button
        case .connecting:
            cell.contentConfiguration = IconRowContentConfiguration(symbol: "arrow.triangle.2.circlepath", title: SeerrCopy.connecting)
            cell.accessories = [.customView(configuration: .init(customView: Self.spinner(), placement: .trailing()))]
        case .user:
            let connection = account.connection
            let name = connection?.auth == .apiKey ? SeerrCopy.apiKeyAccount : (connection?.user?.name ?? SeerrCopy.name)
            cell.contentConfiguration = IconRowContentConfiguration(symbol: "person.crop.circle.fill", title: name, subtitle: SeerrCopy.signedInAs)
        case .address:
            cell.contentConfiguration = IconRowContentConfiguration(symbol: "server.rack", title: SeerrCopy.name, value: account.connection?.displayName)
        case .rights:
            cell.contentConfiguration = IconRowContentConfiguration(symbol: "checkmark.shield", title: SeerrCopy.canRequest, value: Self.rightsLabel(account.permissions))
        case .requests:
            var content = IconRowContentConfiguration(symbol: "tray.full", title: SeerrCopy.requests)
            content.value = pendingApprovals > 0 ? SeerrCopy.pendingCount(pendingApprovals) : nil
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        case .disconnect:
            cell.contentConfiguration = Self.button(SeerrCopy.disconnect, color: Theme.Color.destructive, bold: false)
            cell.accessibilityTraits = .button
        }
    }

    private static func identifier(_ row: Row) -> String {
        switch row {
        case .pitch(let index): return "pitch\(index)"
        case .message: return "message"
        default: return "\(row)"
        }
    }

    static func rightsLabel(_ permissions: SeerrPermissions) -> String {
        guard permissions.canRequest(.movie) || permissions.canRequest(.tv) else { return SeerrCopy.cannotRequest }
        return permissions.autoApproves(.movie) && permissions.autoApproves(.tv) ? SeerrCopy.autoApproved : SeerrCopy.needsApproval
    }

    private static func button(_ title: String, color: UIColor, bold: Bool) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.cell()
        content.text = title
        content.textProperties.font = bold ? Theme.Font.headline : Theme.Font.body
        content.textProperties.color = color
        content.textProperties.alignment = .center
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 15, leading: 16, bottom: 15, trailing: 16)
        return content
    }

    private static func spinner() -> UIActivityIndicatorView {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        return spinner
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .connect, .guide, .enterAddress, .apiKey, .requests, .disconnect: return true
        default: return false
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .connect: connectToFoundOrSaved()
        case .guide: openGuide()
        case .enterAddress: askForAddress(thenAPIKey: false)
        case .apiKey: askForAPIKey()
        case .requests: navigationController?.pushViewController(SeerrRequestsViewController(api: api), animated: true)
        case .disconnect: confirmDisconnect(from: collectionView.cellForItem(at: indexPath))
        default: break
        }
    }

    // MARK: - Connecting

    private func discoverIfNeeded() {
        guard account.status == .disconnected, discovery == .idle else { return }
        discovery = .searching
        applySnapshot()
        let routes = ServerBootstrap.connection()?.candidateURIs ?? [api.baseURL]
        Task { [weak self] in
            let found = await SeerrAccount.shared.discover(serverRoutes: routes)
            guard let self else { return }
            discovery = found.map { .found($0.0, $0.1) } ?? .notFound
            applySnapshot()
        }
    }

    /// The setup guide; once Seerr is ready there, the guide closes and connecting starts here.
    private func openGuide() {
        let guide = SeerrGuideViewController(api: api) { [weak self] address, settings in
            guard let self else { return }
            navigationController?.popToViewController(self, animated: true)
            discovery = .found(address, settings)
            connect(address: address, settings: settings, apiKey: nil)
        }
        navigationController?.pushViewController(guide, animated: true)
    }

    private func connectToFoundOrSaved() {
        if case .found(let address, let settings) = discovery {
            connect(address: address, settings: settings, apiKey: nil)
        } else if let connection = account.connection {
            connect(address: connection.address, settings: SeerrPublicSettings(applicationTitle: connection.title, partialRequestsEnabled: connection.partialRequests), apiKey: nil)
        }
    }

    private func connect(address: URL, settings: SeerrPublicSettings, apiKey: String?) {
        isConnecting = true
        applySnapshot()
        Task { [weak self] in
            do {
                try await SeerrAccount.shared.connect(address: address, settings: settings, apiKey: apiKey)
                Haptics.success()
                self?.isConnecting = false
                self?.applySnapshot()
            } catch {
                Haptics.error()
                guard let self else { return }
                isConnecting = false
                discovery = .found(address, settings)
                applySnapshot()
                presentFailure(error, address: address, settings: settings)
            }
        }
    }

    private func presentFailure(_ error: Error, address: URL, settings: SeerrPublicSettings) {
        let alert = UIAlertController(title: SeerrCopy.connectFailed, message: error.localizedDescription, preferredStyle: .alert)
        if error as? SeerrError == .plexSignInOff || error as? SeerrError == .accessDenied {
            alert.addAction(UIAlertAction(title: SeerrCopy.useAPIKey, style: .default) { [weak self] _ in self?.askForAPIKey() })
        }
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        present(alert, animated: true)
    }

    private func askForAddress(thenAPIKey: Bool) {
        let alert = UIAlertController(title: SeerrCopy.addressTitle, message: SeerrCopy.addressMessage, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = SeerrCopy.addressPlaceholder
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.textContentType = .URL
            field.accessibilityIdentifier = "seerr.addressField"
            if case .found(let address, _) = self.discovery { field.text = SeerrDiscovery.displayAddress(address) }
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: thenAPIKey ? String(localized: "Next") : SeerrCopy.connect, style: .default) { [weak self, weak alert] _ in
            guard let typed = alert?.textFields?.first?.text else { return }
            self?.resolve(typed, thenAPIKey: thenAPIKey)
        })
        present(alert, animated: true)
    }

    private func resolve(_ typed: String, thenAPIKey: Bool) {
        isConnecting = true
        applySnapshot()
        Task { [weak self] in
            let result = await SeerrDiscovery.resolve(typed: typed)
            guard let self else { return }
            isConnecting = false
            switch result {
            case .success(let (address, settings)):
                discovery = .found(address, settings)
                applySnapshot()
                if thenAPIKey { askForAPIKey() } else { connect(address: address, settings: settings, apiKey: nil) }
            case .failure(let error):
                Haptics.error()
                applySnapshot()
                presentSimpleAlert(title: SeerrCopy.connectFailed, message: error.localizedDescription)
            }
        }
    }

    private func askForAPIKey() {
        guard case .found(let address, let settings) = discovery else { return askForAddress(thenAPIKey: true) }
        let alert = UIAlertController(title: SeerrCopy.apiKeyTitle, message: SeerrCopy.apiKeyMessage, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = SeerrCopy.apiKeyPlaceholder
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.isSecureTextEntry = true
            field.accessibilityIdentifier = "seerr.apiKeyField"
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Connect", comment: "Button that connects Seerr with the API key"), style: .default) { [weak self, weak alert] _ in
            guard let key = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
            self?.connect(address: address, settings: settings, apiKey: key)
        })
        present(alert, animated: true)
    }

    private func confirmDisconnect(from source: UIView?) {
        let alert = UIAlertController(title: SeerrCopy.disconnectTitle, message: SeerrCopy.disconnectMessage, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: SeerrCopy.disconnect, style: .destructive) { [weak self] _ in
            Task {
                await SeerrAccount.shared.disconnect()
                self?.discovery = .idle
                self?.discoverIfNeeded()
            }
        })
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.popoverPresentationController?.sourceView = source ?? view
        alert.popoverPresentationController?.sourceRect = source?.bounds ?? .zero
        present(alert, animated: true)
    }

    private func loadApprovals() {
        guard account.managesRequests else {
            pendingApprovals = 0
            return
        }
        Task { [weak self] in
            let count = await SeerrRequests.shared.pendingCount()
            guard let self, count != pendingApprovals else { return }
            pendingApprovals = count
            applySnapshot()
        }
    }
}

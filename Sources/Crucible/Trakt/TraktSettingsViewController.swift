import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

/// Settings › Integrations › Trakt: what connecting does and what Trakt receives, then the account and what is sent.
/// Nothing reaches Trakt before the viewer connects here.
final class TraktSettingsViewController: UICollectionViewController {
    private enum Section: Int {
        case about, account, sending, status
    }

    private enum Row: Hashable {
        case hero
        case benefit(Int)
        case consent
        case connect
        case message(String)
        case profile
        case disconnect
        case scrobble, sendChanges, removeOnUnwatch, anotherApp
        case pending
        case unmatched
    }

    private let api: APIClient
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!
    private var observation: UUID?

    init(api: APIClient) {
        self.api = api
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observation { Task { @MainActor in TraktAccount.shared.stopObserving(observation) } }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = TraktCopy.name
        navigationItem.largeTitleDisplayMode = .never
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.accessibilityIdentifier = "settings.trakt"
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            var config = UICollectionLayoutListConfiguration.wellRows()
            config.headerMode = .supplementary
            config.footerMode = .supplementary
            if self?.dataSource?.sectionIdentifier(for: index) == .about { config.itemSeparatorHandler = nil }
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            Theme.centerReadable(section, environment)
            return section
        }
        configureDataSource()
        applySnapshot()
        observation = TraktAccount.shared.observe { [weak self] in self?.applySnapshot() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applySnapshot()
    }

    private var account: TraktAccount { .shared }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        switch account.status {
        case .unavailable:
            snapshot.appendSections([.about])
            snapshot.appendItems([.message(TraktCopy.unavailable)], toSection: .about)
        case .restricted:
            snapshot.appendSections([.about])
            snapshot.appendItems([.message(TraktCopy.restricted)], toSection: .about)
        case .disconnected:
            snapshot.appendSections([.about])
            let benefits = TraktCopy.pitch.benefits.indices.map(Row.benefit)
            snapshot.appendItems([.hero] + benefits + [.consent, .connect], toSection: .about)
        case .needsReconnect:
            snapshot.appendSections([.about, .sending])
            snapshot.appendItems([.message(TraktCopy.needsReconnect), .connect], toSection: .about)
            snapshot.appendItems(sendingRows, toSection: .sending)
        case .connected:
            snapshot.appendSections([.account, .sending])
            snapshot.appendItems([.profile, .disconnect], toSection: .account)
            snapshot.appendItems(sendingRows, toSection: .sending)
            var status: [Row] = []
            if !TraktOutbox.shared.pending.isEmpty { status.append(.pending) }
            if !TraktResolver.shared.unmatchedTitles.isEmpty { status.append(.unmatched) }
            if !status.isEmpty {
                snapshot.appendSections([.status])
                snapshot.appendItems(status, toSection: .status)
            }
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private var sendingRows: [Row] { [.scrobble, .sendChanges, .removeOnUnwatch, .anotherApp] }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            self?.configure(cell, row: row)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: row)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            switch self?.dataSource.sectionIdentifier(for: indexPath.section) {
            case .sending: content.text = TraktCopy.sectionFree
            default: content.text = nil
            }
            cell.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] cell, _, indexPath in
            var content = UIListContentConfiguration.groupedFooter()
            guard let self else { return }
            let snapshot = dataSource.snapshot()
            let isLast = indexPath.section == snapshot.numberOfSections - 1
            content.text = isLast ? TraktCopy.disclaimer : nil
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func configure(_ cell: UICollectionViewListCell, row: Row) {
        cell.accessories = []
        cell.applyThemedBackground()
        cell.accessibilityIdentifier = "trakt.\(row)"
        let choices = account.choices
        switch row {
        case .hero:
            let pitch = TraktCopy.pitch
            cell.contentConfiguration = IntegrationHeroContentConfiguration(mark: .trakt, headline: pitch.headline, story: pitch.story)
        case .benefit(let index):
            cell.contentConfiguration = IconRowContentConfiguration(benefit: TraktCopy.pitch.benefits[index])
        case .consent:
            var content = UIListContentConfiguration.subtitleCell()
            content.image = UIImage(systemName: "hand.raised")
            content.imageProperties.tintColor = Theme.Color.labelSecondary
            content.text = TraktCopy.consentTitle
            content.textProperties.font = Theme.Font.footnoteSemibold
            content.secondaryText = [TraktCopy.consentPlays, TraktCopy.consentRatings].map { "· \($0)" }.joined(separator: "\n") + "\n\n" + TraktCopy.consentNever
            content.secondaryTextProperties.font = Theme.Font.footnote
            content.secondaryTextProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
        case .connect:
            var content = UIListContentConfiguration.cell()
            content.text = account.status == .needsReconnect ? TraktCopy.reconnect : TraktCopy.connect
            content.textProperties.font = Theme.Font.headline
            content.textProperties.color = Theme.Color.accentText
            content.textProperties.alignment = .center
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 15, leading: 16, bottom: 15, trailing: 16)
            cell.contentConfiguration = content
            cell.accessibilityTraits = .button
        case .message(let text):
            cell.contentConfiguration = IconRowContentConfiguration(symbol: "info.circle", title: text)
        case .profile:
            let profile = account.profile
            var content = IconRowContentConfiguration(
                symbol: "person.crop.circle.fill",
                title: profile?.displayName ?? TraktCopy.name,
                subtitle: profile.map { "@\($0.username)" }
            )
            content.badge = profile?.isVIP == true ? "VIP" : nil
            cell.contentConfiguration = content
        case .disconnect:
            var content = UIListContentConfiguration.cell()
            content.text = TraktCopy.disconnect
            content.textProperties.color = Theme.Color.destructive
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.accessibilityTraits = .button
        case .scrobble:
            cell.contentConfiguration = toggle("play.circle", TraktCopy.scrobble, TraktCopy.scrobbleDetail, choices.scrobbles) { $0.scrobbles = $1 }
        case .sendChanges:
            cell.contentConfiguration = toggle("arrow.up.right.circle", TraktCopy.sendChanges, TraktCopy.sendChangesDetail, choices.sendsChanges) { $0.sendsChanges = $1 }
        case .removeOnUnwatch:
            cell.contentConfiguration = toggle("minus.circle", TraktCopy.removeOnUnwatch, TraktCopy.removeOnUnwatchDetail, choices.removesPlaysOnUnwatch) { $0.removesPlaysOnUnwatch = $1 }
        case .anotherApp:
            cell.contentConfiguration = toggle("arrow.triangle.2.circlepath", TraktCopy.anotherApp, TraktCopy.anotherAppDetail, choices.anotherAppScrobbles) { $0.anotherAppScrobbles = $1 }
        case .pending:
            cell.contentConfiguration = IconRowContentConfiguration(symbol: "tray.and.arrow.up", title: TraktCopy.waitingChanges, value: TraktCopy.pendingCount(TraktOutbox.shared.pending.count))
        case .unmatched:
            cell.contentConfiguration = IconRowContentConfiguration(symbol: "questionmark.circle", title: TraktCopy.unmatched, value: "\(TraktResolver.shared.unmatchedTitles.count)")
            cell.accessories = [.disclosureIndicator()]
        }
    }

    private func toggle(_ symbol: String, _ title: String, _ detail: String, _ isOn: Bool, _ set: @escaping (inout TraktChoices, Bool) -> Void) -> IconRowContentConfiguration {
        var content = IconRowContentConfiguration(symbol: symbol, title: title, subtitle: detail)
        content.toggle = .init(isOn: isOn, isEnabled: account.isConnected) { isOn in
            Haptics.selection()
            TraktAccount.shared.update { set(&$0, isOn) }
        }
        return content
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .connect, .disconnect, .unmatched: return true
        default: return false
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .connect: presentConnect()
        case .disconnect: confirmDisconnect(from: collectionView.cellForItem(at: indexPath))
        case .unmatched: navigationController?.pushViewController(TraktUnmatchedViewController(), animated: true)
        default: break
        }
    }

    private func presentConnect() {
        let connect = TraktConnectViewController { [weak self] in self?.connected() }
        let navigation = UINavigationController(rootViewController: connect)
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        present(navigation, animated: true)
    }

    /// After connecting, asks once whether Trakt's own Plex link should keep recording plays, if it does.
    private func connected() {
        applySnapshot()
        guard let server = ServerBootstrap.savedMachineIdentifier, !account.choices.askedAboutPlexLink.contains(server) else { return }
        Task { [weak self] in
            guard await TraktAccount.shared.traktRecordsPlexPlays(), let self else { return }
            let sheet = TraktDoublePlayViewController(server: server)
            sheet.sheetPresentationController?.detents = [.medium(), .large()]
            sheet.sheetPresentationController?.prefersGrabberVisible = true
            present(sheet, animated: true)
        }
    }

    private func confirmDisconnect(from source: UIView?) {
        let alert = UIAlertController(title: TraktCopy.disconnectTitle, message: TraktCopy.disconnectMessage, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: TraktCopy.disconnect, style: .destructive) { _ in
            Task { await TraktAccount.shared.disconnect() }
        })
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.popoverPresentationController?.sourceView = source ?? view
        alert.popoverPresentationController?.sourceRect = source?.bounds ?? .zero
        present(alert, animated: true)
    }
}

/// The titles Crucible could not find on Trakt, and why.
final class TraktUnmatchedViewController: UICollectionViewController {
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    init() {
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = TraktCopy.unmatched
        navigationItem.largeTitleDisplayMode = .never
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { _, environment in
            var config = UICollectionLayoutListConfiguration.wellRows()
            config.footerMode = .supplementary
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            Theme.centerReadable(section, environment)
            return section
        }
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { cell, _, title in
            cell.applyThemedBackground()
            var content = UIListContentConfiguration.cell()
            content.text = title
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, title in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: title)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { cell, _, _ in
            var content = UIListContentConfiguration.groupedFooter()
            content.text = TraktCopy.unmatchedDetail
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(Array(Set(TraktResolver.shared.unmatchedTitles)).sorted())
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

/// The viewer's Seerr requests and where each stands; whoever approves requests also sees everyone's and decides on them,
/// which is part of Crucible Pro.
final class SeerrRequestsViewController: UICollectionViewController {
    private enum Filter: Int, CaseIterable {
        case mine, everyone, awaiting

        var title: String {
            switch self {
            case .mine: return SeerrCopy.myRequests
            case .everyone: return SeerrCopy.everyone
            case .awaiting: return SeerrCopy.awaiting
            }
        }
    }

    private enum Row: Hashable {
        case entry(Int)
        case empty
        case message(String)
    }

    private let api: APIClient
    private var dataSource: UICollectionViewDiffableDataSource<Int, Row>!
    private var entries: [SeerrRequestEntry] = []
    private var posters: [Int: UIImage] = [:]
    private var filter = Filter.mine
    private var failure: String?
    private var loaded = false
    nonisolated(unsafe) private var changeObserver: (any NSObjectProtocol)?

    init(api: APIClient) {
        self.api = api
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = SeerrCopy.requests
        navigationItem.largeTitleDisplayMode = .never
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.accessibilityIdentifier = "seerr.requests"
        if SeerrAccount.shared.managesRequests {
            let control = UISegmentedControl(items: Filter.allCases.map(\.title))
            control.selectedSegmentIndex = filter.rawValue
            control.accessibilityIdentifier = "seerr.requests.filter"
            control.addAction(UIAction { [weak self, weak control] _ in
                guard let self, let control, let chosen = Filter(rawValue: control.selectedSegmentIndex) else { return }
                Haptics.selection()
                filter = chosen
                reload()
            }, for: .valueChanged)
            navigationItem.titleView = control
        }
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { [weak self] _, environment in
            var config = UICollectionLayoutListConfiguration.wellRows()
            config.trailingSwipeActionsConfigurationProvider = { indexPath in self?.swipeActions(at: indexPath) }
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            Theme.centerReadable(section, environment)
            return section
        }
        collectionView.refreshControl = UIRefreshControl(frame: .zero, primaryAction: UIAction { [weak self] _ in self?.reload() })
        configureDataSource()
        applySnapshot()
        reload()
        changeObserver = NotificationCenter.default.addObserver(forName: .seerrRequestsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    private func reload() {
        let scope: SeerrRequests.Scope = filter == .mine ? .mine : .everyone
        let pendingOnly = filter == .awaiting
        Task { [weak self] in
            do {
                let entries = try await SeerrRequests.shared.load(scope: scope, pendingOnly: pendingOnly)
                guard let self else { return }
                self.entries = entries
                failure = nil
            } catch {
                self?.failure = error.localizedDescription
            }
            guard let self else { return }
            loaded = true
            collectionView.refreshControl?.endRefreshing()
            applySnapshot()
            loadPosters()
        }
    }

    private func loadPosters() {
        guard let base = SeerrAccount.shared.connection?.address else { return }
        for entry in entries where posters[entry.id] == nil {
            guard let url = SeerrImage.poster(entry.posterPath, base: base) else { continue }
            Task { [weak self] in
                guard let image = await RemoteImageLoader.shared.image(at: url), let self else { return }
                posters[entry.id] = image
                var snapshot = dataSource.snapshot()
                guard snapshot.itemIdentifiers.contains(.entry(entry.id)) else { return }
                snapshot.reconfigureItems([.entry(entry.id)])
                await dataSource.apply(snapshot, animatingDifferences: false)
            }
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0])
        if let failure {
            snapshot.appendItems([.message(failure)])
        } else if loaded, entries.isEmpty {
            snapshot.appendItems([.empty])
        } else {
            snapshot.appendItems(entries.map { .entry($0.id) })
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            self?.configure(cell, row: row)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: row)
        }
    }

    private func entry(_ id: Int) -> SeerrRequestEntry? {
        entries.first { $0.id == id }
    }

    private func configure(_ cell: UICollectionViewListCell, row: Row) {
        cell.applyThemedBackground()
        cell.accessories = []
        switch row {
        case .entry(let id):
            guard let entry = entry(id) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.image = posters[id] ?? UIImage(systemName: entry.request.kind == .tv ? "tv" : "film")
            content.imageProperties.maximumSize = CGSize(width: 46, height: 69)
            content.imageProperties.reservedLayoutSize = CGSize(width: 46, height: 69)
            content.imageProperties.cornerRadius = Theme.Radius.xs
            content.imageProperties.tintColor = Theme.Color.labelTertiary
            content.text = [entry.title, entry.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
            content.textProperties.font = Theme.Font.headline
            var lines = [[SeerrCopy.label(entry.availability), entry.seasonsLabel].compactMap { $0 }.joined(separator: " · ")]
            if let detail = SeerrCopy.detail(entry.availability) { lines.append(detail) }
            if !entry.isMine, let name = entry.request.requestedBy?.name { lines.append(SeerrCopy.requestedBy(name)) }
            content.secondaryText = lines.joined(separator: "\n")
            content.secondaryTextProperties.color = Theme.Color.labelSecondary
            content.secondaryTextProperties.font = Theme.Font.footnote
            cell.contentConfiguration = content
            let icon = UIImageView(image: UIImage(systemName: SeerrCopy.symbol(entry.availability)))
            icon.tintColor = entry.availability == .available ? Theme.Color.accent : Theme.Color.labelSecondary
            cell.accessories = [.customView(configuration: .init(customView: icon, placement: .trailing()))]
            cell.accessibilityIdentifier = "seerr.requests.\(id)"
            cell.accessibilityTraits = entry.ratingKey != nil ? .button : .staticText
        case .empty:
            var content = IconRowContentConfiguration(symbol: "tray", title: SeerrCopy.noRequestsTitle, subtitle: SeerrCopy.noRequestsText)
            content.exposesToAccessibility = true
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "seerr.requests.empty"
        case .message(let text):
            cell.contentConfiguration = IconRowContentConfiguration(symbol: "exclamationmark.triangle", title: text)
        }
    }

    // MARK: - Actions

    /// One thing the viewer can do to a request, shown both as a swipe action and in the long-press menu.
    private struct RequestAction {
        let title: String
        let symbol: String
        let isDestructive: Bool
        let run: () -> Void
    }

    private func actions(for entry: SeerrRequestEntry) -> [RequestAction] {
        var actions: [RequestAction] = []
        let manages = SeerrAccount.shared.managesRequests
        if manages, entry.request.requestStatus == .pending {
            actions.append(RequestAction(title: SeerrCopy.approve, symbol: "checkmark", isDestructive: false) { [weak self] in self?.decide(entry, approve: true) })
            actions.append(RequestAction(title: SeerrCopy.decline, symbol: "xmark", isDestructive: true) { [weak self] in self?.decide(entry, approve: false) })
        } else if manages, entry.request.requestStatus == .failed {
            actions.append(RequestAction(title: SeerrCopy.retry, symbol: "arrow.clockwise", isDestructive: false) { [weak self] in self?.retry(entry) })
        }
        if (entry.isMine && entry.request.requestStatus == .pending) || manages {
            let title = entry.isMine && entry.request.requestStatus == .pending ? SeerrCopy.withdraw : SeerrCopy.remove
            actions.append(RequestAction(title: title, symbol: "trash", isDestructive: true) { [weak self] in self?.remove(entry) })
        }
        return actions
    }

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard case .entry(let id) = dataSource.itemIdentifier(for: indexPath), let entry = entry(id) else { return nil }
        let actions = actions(for: entry).map { action in
            let contextual = UIContextualAction(style: action.isDestructive ? .destructive : .normal, title: action.title) { _, _, done in
                action.run()
                done(true)
            }
            contextual.image = UIImage(systemName: action.symbol)
            if !action.isDestructive { contextual.backgroundColor = Theme.Color.accent }
            return contextual
        }
        guard !actions.isEmpty else { return nil }
        let configuration = UISwipeActionsConfiguration(actions: actions)
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, case .entry(let id) = dataSource.itemIdentifier(for: indexPath), let entry = entry(id) else { return nil }
        let menu = actions(for: entry).map { action in
            UIAction(title: action.title, image: UIImage(systemName: action.symbol), attributes: action.isDestructive ? .destructive : []) { _ in action.run() }
        }
        guard !menu.isEmpty else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in UIMenu(children: menu) })
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard case .entry(let id) = dataSource.itemIdentifier(for: indexPath) else { return false }
        return entry(id)?.ratingKey != nil
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .entry(let id) = dataSource.itemIdentifier(for: indexPath), let ratingKey = entry(id)?.ratingKey else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let item = try await api.requestContainer(.metadata(ratingKey: ratingKey)).Metadata?.first else { return }
                HomeMediaActions.openDetail(item, api: api, from: navigationController)
            } catch {
                presentSimpleAlert(title: String(localized: "Couldn\u{2019}t Load"), message: error.localizedDescription)
            }
        }
    }

    /// Approving and declining is Pro; the paywall opens first when it is not unlocked.
    private func decide(_ entry: SeerrRequestEntry, approve: Bool) {
        ProAccess.shared.requestUnlock(.manageRequests) { [weak self] unlocked in
            guard unlocked else { return }
            self?.run { try await SeerrRequests.shared.decide(entry, approve: approve) }
        }
    }

    private func retry(_ entry: SeerrRequestEntry) {
        ProAccess.shared.requestUnlock(.manageRequests) { [weak self] unlocked in
            guard unlocked else { return }
            self?.run { try await SeerrRequests.shared.retry(entry) }
        }
    }

    private func remove(_ entry: SeerrRequestEntry) {
        run { try await SeerrRequests.shared.remove(entry) }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        Task { [weak self] in
            do {
                try await work()
                Haptics.success()
            } catch {
                Haptics.error()
                self?.presentSimpleAlert(title: SeerrCopy.connectFailed, message: error.localizedDescription)
            }
        }
    }
}

import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// The owner's server dashboard: how hard the server is working, what it is busy with (scans, refreshes, conversions, with
/// a way to cancel), and whether a newer version of Plex Media Server is waiting, with its release notes and Install.
/// Refreshes every few seconds while it is open.
final class ServerDashboardViewController: UICollectionViewController {
    private enum Section: Int, CaseIterable {
        case load, tasks, software
    }

    private enum Item: Hashable {
        case load
        case activity(String)
        case idle
        case version
        case update
        case checkForUpdates
    }

    private let api: APIClient
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var sample: PlexResourceSample?
    private var activities: [PlexActivity] = []
    private var release: PlexServerRelease?
    private var version: String?
    private var refreshTask: Task<Void, Never>?

    init(api: APIClient) {
        self.api = api
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { refreshTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Server Dashboard", comment: "Title of the owner's server dashboard")
        navigationItem.largeTitleDisplayMode = .never
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.accessibilityIdentifier = "dashboard"
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            var config = UICollectionLayoutListConfiguration.wellRows()
            config.headerMode = .supplementary
            config.trailingSwipeActionsConfigurationProvider = { indexPath in self?.swipeActions(at: indexPath) }
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            Theme.centerReadable(section, environment)
            return section
        }
        configureDataSource()
        applySnapshot()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTask?.cancel()
    }

    private func refresh() async {
        async let sample = try? LibraryManagement.load(api: api)
        async let activities = try? LibraryManagement.activities(api: api)
        async let release = try? LibraryManagement.availableUpdate(api: api)
        async let identity: PlexIdentity? = try? api.request(.identity)
        let loaded = await (sample, activities, release, identity)
        self.sample = loaded.0 ?? nil
        self.activities = loaded.1 ?? []
        self.release = loaded.2 ?? nil
        version = loaded.3?.MediaContainer.version ?? version
        applySnapshot()
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems([.load], toSection: .load)
        snapshot.appendItems(activities.isEmpty ? [.idle] : activities.map { .activity($0.uuid) }, toSection: .tasks)
        snapshot.appendItems([.version] + (release == nil ? [] : [.update]) + [.checkForUpdates], toSection: .software)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { dataSource.snapshot().indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            var content = UIListContentConfiguration.valueCell()
            content.textProperties.font = Theme.Font.callout
            content.secondaryTextProperties.color = Theme.Color.labelSecondary
            cell.accessories = []
            switch item {
            case .load:
                content.text = String(localized: "Load", comment: "Server dashboard row for CPU and memory use")
                content.secondaryText = Self.loadText(sample)
                content.image = UIImage(systemName: "gauge.with.dots.needle.33percent")
            case .activity(let id):
                let activity = activities.first { $0.uuid == id }
                content = UIListContentConfiguration.subtitleCell()
                content.text = activity?.title ?? ""
                content.secondaryText = [activity?.subtitle, activity?.progress.map { "\($0)%" }].compactMap { $0 }.joined(separator: " · ")
                content.image = UIImage(systemName: "gearshape.2")
            case .idle:
                content.text = String(localized: "Nothing running", comment: "Server dashboard: the server has no background tasks")
                content.textProperties.color = Theme.Color.labelSecondary
            case .version:
                content.text = String(localized: "Plex Media Server", comment: "Server dashboard row showing the server version")
                content.secondaryText = version
                content.image = UIImage(systemName: "server.rack")
            case .update:
                content.text = String(localized: "Update Available", comment: "Server dashboard row when a server update is waiting")
                content.secondaryText = release?.version
                content.textProperties.color = Theme.Color.accent
                content.image = UIImage(systemName: "arrow.down.app")
                cell.accessories = [.disclosureIndicator()]
            case .checkForUpdates:
                content.text = String(localized: "Check for Updates", comment: "Server dashboard action")
                content.textProperties.color = Theme.Color.accent
                content.image = UIImage(systemName: "arrow.clockwise")
            }
            content.imageProperties.tintColor = Theme.Color.labelSecondary
            cell.contentConfiguration = content
            cell.applyThemedBackground()
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { cell, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            switch Section(rawValue: indexPath.section) {
            case .load: content.text = String(localized: "Right Now", comment: "Server dashboard section")
            case .tasks: content.text = String(localized: "Background Tasks", comment: "Server dashboard section")
            case .software: content.text = String(localized: "Software", comment: "Server dashboard section")
            case nil: content.text = nil
            }
            content.textProperties.transform = .uppercase
            content.textProperties.font = Theme.Font.footnoteSemibold
            content.textProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private static func loadText(_ sample: PlexResourceSample?) -> String {
        guard let sample else { return "—" }
        let cpu = Int((sample.processCpuUtilization ?? sample.hostCpuUtilization ?? 0).rounded())
        let memory = Int((sample.processMemoryUtilization ?? sample.hostMemoryUtilization ?? 0).rounded())
        return String(localized: "CPU \(cpu)% · Memory \(memory)%", comment: "Server load, e.g. CPU 12% · Memory 34%")
    }

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard case .activity(let id)? = dataSource.itemIdentifier(for: indexPath),
              let activity = activities.first(where: { $0.uuid == id }), activity.cancellable == true else { return nil }
        let cancel = UIContextualAction(style: .destructive, title: String(localized: "Cancel", comment: "Swipe action that cancels a server task")) { [weak self] _, _, done in
            guard let self else { return done(false) }
            let api = api
            ManageMenus.run(host: self) { [weak self] in
                try await LibraryManagement.cancel(activity, api: api)
                await self?.refresh()
            }
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [cancel])
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        let api = api
        switch dataSource.itemIdentifier(for: indexPath) {
        case .checkForUpdates:
            ManageMenus.run(host: self) { [weak self] in
                try await LibraryManagement.checkForUpdates(api: api)
                try? await Task.sleep(for: .seconds(2))
                await self?.refresh()
            }
        case .update:
            showRelease()
        default:
            break
        }
    }

    private func showRelease() {
        guard let release else { return }
        let notes = [
            release.added.map { String(localized: "New:\n\($0)", comment: "Server release notes section of new features") },
            release.fixed.map { String(localized: "Fixed:\n\($0)", comment: "Server release notes section of fixes") },
        ].compactMap { $0 }.joined(separator: "\n\n")
        let alert = UIAlertController(
            title: String(localized: "Plex Media Server \(release.version ?? "")", comment: "Title of the server update sheet, e.g. Plex Media Server 1.43.5"),
            message: notes.isEmpty ? nil : notes,
            preferredStyle: .alert
        )
        let api = api
        alert.addAction(UIAlertAction(title: String(localized: "Install Now", comment: "Button that installs a server update"), style: .default) { [weak self] _ in
            guard let self else { return }
            ManageMenus.run(host: self) { try await LibraryManagement.installUpdate(api: api) }
        })
        alert.addAction(UIAlertAction(title: String(localized: "Later", comment: "Button that leaves a server update for later"), style: .cancel))
        present(alert, animated: true)
    }
}

@preconcurrency import UIKit

/// "See All" for a library's Recently Watched rail: the same play history as a poster grid, with far
/// more titles than the rail holds. It opens on the rail's items and fills in once the longer
/// history arrives.
final class RecentlyWatchedGridViewController: UICollectionViewController {
    private let api: APIClient
    private let sectionId: String
    private let kind: LibraryGridKind
    private var items: [PlexMetadata]
    private var itemsById: [String: PlexMetadata] = [:]
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var loadTask: Task<Void, Never>?
    private var playerCoordinator: PlayerCoordinator?

    init(api: APIClient, sectionId: String, kind: LibraryGridKind, items: [PlexMetadata]) {
        self.api = api
        self.sectionId = sectionId
        self.kind = kind
        self.items = items
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout { _, environment in
            Theme.gridLayout(environment: environment)
        })
        title = "Recently Watched"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { loadTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .always
        collectionView.backgroundColor = Theme.Color.canvas
        view.backgroundColor = Theme.Color.canvas
        configureDataSource()
        apply(items)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        loadHistory()
    }

    private func loadHistory() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let loaded = await RecentlyWatched.load(api: api, sectionId: sectionId, groupingByShow: kind == .show, limit: RecentlyWatched.gridLimit)
            guard !Task.isCancelled, !loaded.isEmpty else { return }
            apply(loaded)
        }
    }

    private func apply(_ newItems: [PlexMetadata]) {
        items = newItems
        itemsById = Dictionary(newItems.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var seen = Set<String>()
        let ids = newItems.map(\.id).filter { seen.insert($0).inserted }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids, toSection: 0)
        snapshot.reconfigureItems(ids.filter { dataSource.snapshot().indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: view.window != nil && !UIAccessibility.isReduceMotionEnabled)
        updateEmptyState(isEmpty: ids.isEmpty)
    }

    private func updateEmptyState(isEmpty: Bool) {
        guard isEmpty else {
            contentUnavailableConfiguration = nil
            return
        }
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: kind.placeholderIcon)
        config.text = "Nothing Watched Yet"
        config.secondaryText = "Titles you watch from this library appear here."
        contentUnavailableConfiguration = config
    }

    private func configureDataSource() {
        let kind = kind
        let registration = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let item = self?.itemsById[id] else {
                cell.contentConfiguration = PosterContentConfiguration()
                return
            }
            cell.contentConfiguration = RecentlyWatchedActions.posterConfiguration(for: item, kind: kind)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let item = itemsById[id] else { return }
        let detail = RecentlyWatchedActions.destination(for: item, kind: kind, api: api)
        if #available(iOS 18.0, *) {
            detail.preferredTransition = .zoom { [weak self] _ in
                self?.dataSource.indexPath(for: id).flatMap { self?.collectionView.cellForItem(at: $0) }
            }
        }
        navigationController?.pushViewController(detail, animated: true)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let id = dataSource.itemIdentifier(for: indexPath),
              let item = itemsById[id] else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return RecentlyWatchedActions.contextMenu(
                for: item,
                kind: kind,
                api: api,
                open: { [weak self] in self?.navigationController?.pushViewController($0, animated: true) },
                play: { [weak self] item in self?.play(item) }
            )
        })
    }

    private func play(_ item: PlexMetadata) {
        Haptics.light()
        playerCoordinator = Theme.quickPlay(api: api, item: item, from: self)
    }
}

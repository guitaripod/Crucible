@preconcurrency import UIKit

/// "See All" destination for a Home rail: the rail's items as a poster grid.
final class HomeSectionGridViewController: UICollectionViewController {
    let bucket: HomeBucket
    private let api: APIClient
    private let onChange: @MainActor () -> Void
    private var items: [PlexMetadata]
    private var mediaById: [String: PlexMetadata] = [:]
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var playerCoordinator: PlayerCoordinator?

    init(api: APIClient, title: String, bucket: HomeBucket, items: [PlexMetadata], onChange: @escaping @MainActor () -> Void) {
        self.api = api
        self.bucket = bucket
        self.items = items
        self.onChange = onChange
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout { _, environment in
            Theme.gridLayout(environment: environment)
        })
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .always
        collectionView.backgroundColor = Theme.Color.canvas
        view.backgroundColor = Theme.Color.canvas
        configureDataSource()
        update(items: items)
    }

    func update(items newItems: [PlexMetadata]) {
        items = newItems
        guard isViewLoaded else { return }
        mediaById = Dictionary(newItems.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var seen = Set<String>()
        let ids = newItems.map(\.id).filter { seen.insert($0).inserted }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids, toSection: 0)
        snapshot.reconfigureItems(ids.filter { dataSource.snapshot().indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)

        if ids.isEmpty {
            var empty = UIContentUnavailableConfiguration.empty()
            empty.image = UIImage(systemName: "rectangle.stack")
            empty.text = "Nothing Here"
            empty.secondaryText = "This list is empty right now."
            contentUnavailableConfiguration = empty
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    private func configureDataSource() {
        let bucket = bucket
        let registration = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let item = self?.mediaById[id] else { return }
            cell.contentConfiguration = HomeMediaActions.posterConfiguration(for: item, bucket: bucket)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let item = mediaById[id] else { return }
        HomeMediaActions.openDetail(item, api: api, from: navigationController)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let id = dataSource.itemIdentifier(for: indexPath),
              let item = mediaById[id] else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return HomeMediaActions.contextMenu(
                for: item,
                api: api,
                navigation: { [weak self] in self?.navigationController },
                play: { [weak self] item in self?.play(item) },
                didChange: { [weak self] in self?.onChange() }
            )
        })
    }

    private func play(_ item: PlexMetadata) {
        Haptics.light()
        playerCoordinator = Theme.quickPlay(api: api, item: item, from: self)
    }
}

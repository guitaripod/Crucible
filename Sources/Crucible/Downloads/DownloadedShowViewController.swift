@preconcurrency import UIKit

/// The downloaded episodes of one show. Built only from local download records, so it works offline.
final class DownloadedShowViewController: UICollectionViewController {
    private let api: APIClient
    private let groupKey: String
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var observerToken: UUID?
    private var pendingSnapshot = false
    private var playerCoordinator: PlayerCoordinator?

    init(api: APIClient, groupKey: String, title: String) {
        self.api = api
        self.groupKey = groupKey
        super.init(collectionViewLayout: UICollectionViewLayout())
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observerToken {
            Task { @MainActor in DownloadManager.shared.removeObserver(observerToken) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        collectionView.backgroundColor = Theme.Color.canvas
        view.backgroundColor = Theme.Color.canvas
        collectionView.collectionViewLayout = makeLayout()
        configureDataSource()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if observerToken == nil {
            observerToken = DownloadManager.shared.addObserver { [weak self] event in
                if case .progress = event { return }
                self?.scheduleSnapshot()
            }
        }
        applySnapshot()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let observerToken {
            DownloadManager.shared.removeObserver(observerToken)
            self.observerToken = nil
        }
    }

    private var group: DownloadedShowGroup? {
        DownloadedShowGroup.groups(from: DownloadManager.shared.items).first { $0.key == groupKey }
    }

    private func scheduleSnapshot() {
        guard !pendingSnapshot else { return }
        pendingSnapshot = true
        DispatchQueue.main.async { [weak self] in
            self?.pendingSnapshot = false
            self?.applySnapshot()
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] _, environment in
            var config = Theme.groupedListConfiguration()
            config.separatorConfiguration.color = Theme.Color.separator
            config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.swipeActions(at: indexPath)
            }
            return NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        }
    }

    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> { cell, _, ratingKey in
            cell.configurationUpdateHandler = { cell, state in
                var background = UIBackgroundConfiguration.listGroupedCell().updated(for: state)
                background.cornerRadius = 20
                background.backgroundColor = state.isHighlighted ? Theme.Color.surfaceRaised : Theme.Color.surface
                cell.backgroundConfiguration = background
            }
            guard let item = DownloadManager.shared.item(for: ratingKey) else { return }
            cell.contentConfiguration = DownloadRowFactory.episode(item)
            cell.accessories = [.disclosureIndicator()]
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, ratingKey in
            cv.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: ratingKey)
        }
    }

    private func applySnapshot() {
        guard let group else {
            if isViewLoaded, navigationController?.topViewController === self {
                navigationController?.popViewController(animated: true)
            }
            return
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(group.ratingKeys, toSection: 0)
        snapshot.reconfigureItems(group.ratingKeys)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let ratingKey = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { _, _, completion in
            DownloadManager.shared.delete(ratingKey)
            completion(true)
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let ratingKey = dataSource.itemIdentifier(for: indexPath),
              let item = DownloadManager.shared.item(for: ratingKey) else { return }
        let detail = MediaDetailViewController(
            api: api,
            ratingKey: item.ratingKey,
            mediaType: item.mediaType,
            showRatingKey: item.grandparentRatingKey,
            seasonRatingKey: item.parentRatingKey
        )
        navigationController?.pushViewController(detail, animated: true)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let ratingKey = dataSource.itemIdentifier(for: indexPath),
              let item = DownloadManager.shared.item(for: ratingKey) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [
                UIAction(title: item.resumeSecs > 1 ? "Resume" : "Play", image: UIImage(systemName: "play.fill")) { _ in
                    guard let self else { return }
                    self.playerCoordinator = OfflinePlayback.start(item, api: self.api, from: self)
                },
                UIAction(title: "Delete Download", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    DownloadManager.shared.delete(ratingKey)
                },
            ])
        })
    }
}

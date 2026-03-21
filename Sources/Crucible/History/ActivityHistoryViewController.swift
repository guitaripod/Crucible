import UIKit

struct HistoryItem: Hashable, Sendable {
    let ratingKey: String
    let title: String
    let type: String?
    let viewedAt: Int?
    let thumb: String?
    let grandparentTitle: String?
    let parentIndex: Int?
    let index: Int?
    let uniqueId: String
}

final class ActivityHistoryViewController: UICollectionViewController {
    private let api: APIClient
    private var dataSource: UICollectionViewDiffableDataSource<Int, HistoryItem>!
    private var loadTask: Task<Void, Never>?
    private var currentOffset = 0
    private var totalSize = 0
    private var isLoadingMore = false
    private let pageSize = 50

    init(api: APIClient) {
        self.api = api
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Activity History"
        navigationItem.largeTitleDisplayMode = .never

        var listConfig = UICollectionLayoutListConfiguration(appearance: .plain)
        listConfig.showsSeparators = true
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout.list(using: listConfig)

        configureDataSource()

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [unowned self] _ in resetAndLoad() }, for: .valueChanged)
        collectionView.refreshControl = refresh
        collectionView.prefetchDataSource = self
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if dataSource.snapshot().numberOfItems == 0 {
            loadPage(offset: 0)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
    }

    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewListCell, HistoryItem> { cell, _, entry in
            var config = UIListContentConfiguration.subtitleCell()
            var titleParts = [String]()
            if let show = entry.grandparentTitle { titleParts.append(show) }
            titleParts.append(entry.title)
            config.text = titleParts.joined(separator: " — ")

            var details = [String]()
            if let code = Formatters.episodeCode(entry.parentIndex, entry.index) {
                details.append(code)
            }
            if let relative = Formatters.unixRelativeDate(entry.viewedAt) {
                details.append(relative)
            }
            config.secondaryText = details.isEmpty ? nil : details.joined(separator: " · ")

            config.image = UIImage(systemName: "checkmark.circle.fill")
            config.imageProperties.tintColor = .systemOrange

            cell.contentConfiguration = config
            cell.accessories = [.disclosureIndicator()]
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, item in
            cv.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: item)
        }
    }

    private func resetAndLoad() {
        currentOffset = 0
        totalSize = 0
        loadPage(offset: 0)
    }

    private func loadPage(offset: Int) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await api.requestContainer(.history(start: offset, size: pageSize))
                guard !Task.isCancelled else { return }

                totalSize = container.totalSize ?? 0
                let items = (container.Metadata ?? []).enumerated().map { idx, m in
                    HistoryItem(
                        ratingKey: m.id,
                        title: m.title,
                        type: m.type,
                        viewedAt: m.lastViewedAt ?? m.addedAt,
                        thumb: m.thumb,
                        grandparentTitle: m.grandparentTitle,
                        parentIndex: m.parentIndex,
                        index: m.index,
                        uniqueId: "\(m.id)-\(offset + idx)"
                    )
                }
                currentOffset = offset + items.count

                var snapshot = dataSource.snapshot()
                if offset == 0 {
                    snapshot = NSDiffableDataSourceSnapshot<Int, HistoryItem>()
                    snapshot.appendSections([0])
                }
                snapshot.appendItems(items, toSection: 0)
                await dataSource.apply(snapshot, animatingDifferences: offset > 0)

                if items.isEmpty && offset == 0 {
                    var config = UIContentUnavailableConfiguration.empty()
                    config.image = UIImage(systemName: "clock")
                    config.text = "No activity yet"
                    contentUnavailableConfiguration = config
                } else {
                    contentUnavailableConfiguration = nil
                }

                isLoadingMore = false
                collectionView.refreshControl?.endRefreshing()
            } catch {
                guard !Task.isCancelled else { return }
                isLoadingMore = false
                collectionView.refreshControl?.endRefreshing()
            }
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let entry = dataSource.itemIdentifier(for: indexPath) else { return }

        switch entry.type {
        case "episode":
            let vc = MediaDetailViewController(api: api, ratingKey: entry.ratingKey, mediaType: "episode")
            navigationController?.pushViewController(vc, animated: true)
        case "show":
            let vc = ShowDetailViewController(api: api, showRatingKey: entry.ratingKey)
            navigationController?.pushViewController(vc, animated: true)
        default:
            let vc = MediaDetailViewController(api: api, ratingKey: entry.ratingKey, mediaType: "movie")
            navigationController?.pushViewController(vc, animated: true)
        }
    }
}

extension ActivityHistoryViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let itemCount = dataSource.snapshot().numberOfItems
        let threshold = itemCount - 10
        if indexPaths.contains(where: { $0.item >= threshold }),
           currentOffset < totalSize,
           !isLoadingMore
        {
            isLoadingMore = true
            loadPage(offset: currentOffset)
        }
    }
}

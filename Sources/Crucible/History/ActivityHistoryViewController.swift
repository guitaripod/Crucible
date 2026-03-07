import UIKit

final class ActivityHistoryViewController: UICollectionViewController {
    private let api: APIClient
    private var dataSource: UICollectionViewDiffableDataSource<Int, HistoryEntry>!
    private var loadTask: Task<Void, Never>?
    private var currentOffset = 0
    private var total: Int64 = 0
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
        let cellReg = UICollectionView.CellRegistration<UICollectionViewListCell, HistoryEntry> { cell, _, entry in
            var config = UIListContentConfiguration.subtitleCell()
            config.text = entry.title ?? entry.mediaId
            var details = [String]()
            details.append(entry.eventType.replacingOccurrences(of: "_", with: " ").capitalized)
            details.append(Formatters.timestamp(entry.positionSecs))
            if let relative = Formatters.relativeDate(entry.createdAt) {
                details.append(relative)
            }
            config.secondaryText = details.joined(separator: " · ")

            let iconName: String
            switch entry.eventType {
            case "play": iconName = "play.circle"
            case "pause": iconName = "pause.circle"
            case "complete": iconName = "checkmark.circle"
            default: iconName = "clock"
            }
            config.image = UIImage(systemName: iconName)
            config.imageProperties.tintColor = .secondaryLabel

            cell.contentConfiguration = config
            cell.accessories = entry.mediaType != nil ? [.disclosureIndicator()] : []
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, item in
            cv.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: item)
        }
    }

    private func resetAndLoad() {
        currentOffset = 0
        total = 0
        loadPage(offset: 0)
    }

    private func loadPage(offset: Int) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response: HistoryResponse = try await api.request(
                    .activityHistory(limit: pageSize, offset: offset)
                )
                guard !Task.isCancelled else { return }
                total = response.total
                currentOffset = offset + response.entries.count

                var snapshot = dataSource.snapshot()
                if offset == 0 {
                    snapshot = NSDiffableDataSourceSnapshot<Int, HistoryEntry>()
                    snapshot.appendSections([0])
                }
                snapshot.appendItems(response.entries, toSection: 0)
                await dataSource.apply(snapshot, animatingDifferences: offset > 0)

                if response.entries.isEmpty && offset == 0 {
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
        guard let entry = dataSource.itemIdentifier(for: indexPath),
              let mediaType = entry.mediaType else { return }

        switch mediaType {
        case "episode":
            let vc = MediaDetailViewController(api: api, mediaId: entry.mediaId, mediaType: "episode")
            navigationController?.pushViewController(vc, animated: true)
        default:
            let vc = MediaDetailViewController(api: api, mediaId: entry.mediaId, mediaType: "movie")
            navigationController?.pushViewController(vc, animated: true)
        }
    }
}

extension ActivityHistoryViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let itemCount = dataSource.snapshot().numberOfItems
        let threshold = itemCount - 10
        if indexPaths.contains(where: { $0.item >= threshold }),
           currentOffset < Int(total),
           !isLoadingMore
        {
            isLoadingMore = true
            loadPage(offset: currentOffset)
        }
    }
}

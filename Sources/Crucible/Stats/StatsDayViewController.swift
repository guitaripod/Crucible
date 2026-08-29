@preconcurrency import UIKit

/// The heatmap drill-down: a poster grid of everything watched on one local day.
final class StatsDayViewController: UICollectionViewController {
    private let api: APIClient
    private let store: StatsStore
    private let dayEpoch: Int
    private var dataSource: UICollectionViewDiffableDataSource<Int, OnThisDayItem>!
    private var loadTask: Task<Void, Never>?

    init(api: APIClient, store: StatsStore, dayEpoch: Int, date: Date) {
        self.api = api
        self.store = store
        self.dayEpoch = dayEpoch
        super.init(collectionViewLayout: UICollectionViewLayout())
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        title = formatter.string(from: date)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { _, environment in
            Theme.gridLayout(environment: environment)
        }
        configureDataSource()
        load()
    }

    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewCell, OnThisDayItem> { cell, _, item in
            var config = PosterContentConfiguration()
            config.posterPath = item.thumb ?? item.grandparentThumb
            if item.type == "episode" {
                config.title = item.grandparentTitle ?? item.title
                config.subtitle = item.title
                config.placeholderIcon = "tv"
            } else {
                config.title = item.title
                config.placeholderIcon = "film"
            }
            cell.contentConfiguration = config
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, item in
            cv.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: item)
        }
    }

    private func load() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let rows = try await store.plays(onDayEpoch: dayEpoch)
                guard !Task.isCancelled else { return }
                var seen = Set<String>()
                let items = rows.filter { seen.insert($0.ratingKey).inserted }
                var snapshot = NSDiffableDataSourceSnapshot<Int, OnThisDayItem>()
                snapshot.appendSections([0])
                snapshot.appendItems(items, toSection: 0)
                await dataSource.apply(snapshot, animatingDifferences: false)
            } catch {}
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item.type {
        case "episode":
            navigationController?.pushViewController(
                MediaDetailViewController(api: api, ratingKey: item.ratingKey, mediaType: "episode", showRatingKey: item.grandparentRatingKey),
                animated: true
            )
        case "show":
            navigationController?.pushViewController(ShowDetailViewController(api: api, showRatingKey: item.ratingKey), animated: true)
        default:
            navigationController?.pushViewController(MediaDetailViewController(api: api, ratingKey: item.ratingKey, mediaType: "movie"), animated: true)
        }
    }
}

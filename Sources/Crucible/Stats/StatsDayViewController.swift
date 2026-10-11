import CrucibleCore
import CrucibleDesign
import CrucibleStats
@preconcurrency import UIKit

/// The heatmap drill-down: a poster grid of everything watched on one local day.
final class StatsDayViewController: UICollectionViewController {
    private let api: APIClient
    private let loader: StatsPageLoader
    private let dayEpoch: Int
    private var dataSource: UICollectionViewDiffableDataSource<Int, StatsPoster>!
    private var loadTask: Task<Void, Never>?

    init(api: APIClient, loader: StatsPageLoader, dayEpoch: Int, date: Date) {
        self.api = api
        self.loader = loader
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
        collectionView.showsVerticalScrollIndicator = false
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { _, environment in
            Theme.gridLayout(environment: environment)
        }
        configureDataSource()
        load()
    }

    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewCell, StatsPoster> { cell, _, poster in
            cell.contentConfiguration = StatisticsViewController.posterConfiguration(poster)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, poster in
            cv.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: poster)
        }
    }

    private func load() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let posters = try await loader.playedOnDay(dayEpoch)
                guard !Task.isCancelled else { return }
                var snapshot = NSDiffableDataSourceSnapshot<Int, StatsPoster>()
                snapshot.appendSections([0])
                snapshot.appendItems(posters, toSection: 0)
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
        guard let poster = dataSource.itemIdentifier(for: indexPath) else { return }
        navigationController?.pushViewController(poster.destination.makeViewController(api: api), animated: true)
    }
}

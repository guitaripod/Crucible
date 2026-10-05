@preconcurrency import UIKit

final class GenreBrowseViewController: UICollectionViewController {
    private let api: APIClient
    private let genre: SearchGenre
    private var dataSource: UICollectionViewDiffableDataSource<Int, PlexMetadata>!
    private var loadTask: Task<Void, Never>?
    private var items: [PlexMetadata] = []
    private var playerCoordinator: PlayerCoordinator?

    init(api: APIClient, genre: SearchGenre) {
        self.api = api
        self.genre = genre
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { loadTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = genre.title
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = Theme.Color.canvas
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { _, environment in
            Theme.gridLayout(environment: environment)
        }
        configureDataSource()
        load()
    }

    private func configureDataSource() {
        let reg = UICollectionView.CellRegistration<UICollectionViewCell, PlexMetadata> { cell, _, item in
            cell.contentConfiguration = PosterContentConfiguration.search(item)
            SearchCellEffects.installPressEffect(on: cell)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, item in
            cv.dequeueConfiguredReusableCell(using: reg, for: indexPath, item: item)
        }
    }

    private func load() {
        loadTask?.cancel()
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await SearchLoader.items(api: api, genre: genre)
                guard !Task.isCancelled else { return }
                items = loaded
                applySnapshot()
            } catch {
                guard !Task.isCancelled, (error as? URLError)?.code != .cancelled else { return }
                AppLogger.error("Genre browse failed genre=\(genre.title): \(error.localizedDescription)", .networking)
                showFailure(error)
            }
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, PlexMetadata>()
        snapshot.appendSections([0])
        snapshot.appendItems(items, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: false)

        if items.isEmpty {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "film.stack")
            config.text = "No \(genre.title) Titles"
            config.secondaryText = "Nothing in your libraries is tagged with this genre."
            contentUnavailableConfiguration = config
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    private func showFailure(_ error: Error) {
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "wifi.exclamationmark")
        config.text = "Couldn\u{2019}t Load \(genre.title)"
        config.secondaryText = error.localizedDescription
        var button = UIButton.Configuration.filled()
        button.title = "Try Again"
        button.cornerStyle = .capsule
        button.baseBackgroundColor = Theme.Color.accent
        button.baseForegroundColor = Theme.Color.onAccent
        config.button = button
        config.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.load() }
        contentUnavailableConfiguration = config
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        let controller: UIViewController
        if item.mediaType == "show" {
            controller = ShowDetailViewController(api: api, showRatingKey: item.id)
        } else {
            controller = MediaDetailViewController(api: api, ratingKey: item.id, mediaType: "movie")
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let item = dataSource.itemIdentifier(for: indexPath), item.mediaType == "movie" else {
            return nil
        }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            let play = UIAction(title: item.positionSecs > 0 ? "Resume" : "Play", image: UIImage(systemName: "play.fill")) { _ in
                Haptics.light()
                guard let self else { return }
                self.playerCoordinator = Theme.quickPlay(api: self.api, item: item, from: self)
            }
            return UIMenu(children: [play, DownloadMenu.action(for: item)])
        })
    }
}

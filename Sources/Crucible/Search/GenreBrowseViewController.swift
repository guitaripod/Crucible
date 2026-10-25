import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

final class GenreBrowseViewController: UICollectionViewController {
    private let api: APIClient
    private let genre: SearchGenre
    private let session: GenreBrowseSession
    private var dataSource: UICollectionViewDiffableDataSource<Int, PlexMetadata>!
    private var playerCoordinator: PlayerCoordinator?
    private lazy var mediaDrag = MediaDragSource { [weak self] indexPath in self?.dataSource.itemIdentifier(for: indexPath) }

    init(api: APIClient, genre: SearchGenre) {
        self.api = api
        self.genre = genre
        session = GenreBrowseSession(genre: genre, loader: SearchLoader(api: api))
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = genre.title
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = Theme.Color.canvas
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.allowsKeyboardFocus()
        collectionView.dragDelegate = mediaDrag
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { _, environment in
            Theme.gridLayout(environment: environment)
        }
        configureDataSource()
        session.onChange = { [weak self] state in self?.render(state) }
        session.load()
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

    private func render(_ state: GenreBrowseState) {
        switch state {
        case .loading: contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        case .loaded(let items): applySnapshot(items)
        case .empty: applySnapshot([])
        case .failed(let message): showFailure(message: message)
        }
    }

    private func applySnapshot(_ items: [PlexMetadata]) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, PlexMetadata>()
        snapshot.appendSections([0])
        snapshot.appendItems(items, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: false)

        if items.isEmpty {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "film.stack")
            config.text = SearchCopy.genreEmptyTitle(genre.title)
            config.secondaryText = SearchCopy.genreEmptyMessage
            contentUnavailableConfiguration = config
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    private func showFailure(message: String) {
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "wifi.exclamationmark")
        config.text = SearchCopy.genreFailureTitle(genre.title)
        config.secondaryText = message
        var button = UIButton.Configuration.filled()
        button.title = SearchCopy.retry
        button.cornerStyle = .capsule
        button.baseBackgroundColor = Theme.Color.accent
        button.baseForegroundColor = Theme.Color.onAccent
        config.button = button
        config.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.session.load() }
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
            let play = UIAction(title: SearchItemActions.playTitle(for: item), image: UIImage(systemName: "play.fill")) { _ in
                Haptics.light()
                guard let self else { return }
                self.playerCoordinator = Theme.quickPlay(api: self.api, item: item, from: self)
            }
            return UIMenu(children: [play, DownloadMenu.action(for: item)]).addingNewWindow(for: item)
        })
    }
}

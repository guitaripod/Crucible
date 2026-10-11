import CrucibleCore
import CrucibleDesign
import UIKit

/// Every title of one genre as a poster grid, sorted by title, with the same loading, empty and
/// error states as the rest of Search.
final class TVGenreBrowseViewController: UIViewController, UICollectionViewDelegate {
    private let env: TVAppEnvironment
    private let genre: SearchGenre
    private let session: GenreBrowseSession
    private lazy var collectionView = TVCollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private let stateView = TVStateView()
    private var dataSource: UICollectionViewDiffableDataSource<Int, PlexMetadata>!
    private var itemCount = 0

    init(env: TVAppEnvironment, genre: SearchGenre) {
        self.env = env
        self.genre = genre
        session = GenreBrowseSession(genre: genre, loader: SearchLoader(api: env.api))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        collectionView.delegate = self
        collectionView.onPlayPause = { [weak self] indexPath in self?.playFocused(at: indexPath) }
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateView.isHidden = true
        view.addSubview(collectionView)
        view.addSubview(stateView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.tabBarClearance),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        configureDataSource()
        session.onChange = { [weak self] state in self?.render(state) }
        session.load()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        stateView.isHidden ? [collectionView] : [stateView]
    }

    /// The tab bar floats over the top 150pt of a pushed screen; the grid starts below it, and scrolls up under it.
    private static let tabBarClearance: CGFloat = 164

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, _ in
            TVShelf.grid(columns: 6, header: true)
        }
    }

    private func configureDataSource() {
        let posters = TVPosterCell.registration()
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: posters, for: indexPath, item: TVSearchCards.poster(item))
        }
        let headers = TVSectionHeaderView.registration { [weak self] _ in
            guard let self else { return nil }
            return TVSectionHeader(title: genre.title, secondaryText: itemCount == 1 ? "1 title" : "\(itemCount) titles")
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headers, for: indexPath)
        }
    }

    private func render(_ state: GenreBrowseState) {
        switch state {
        case .loading:
            showState(.loading(title: nil))
        case .loaded(let items):
            itemCount = items.count
            var snapshot = NSDiffableDataSourceSnapshot<Int, PlexMetadata>()
            snapshot.appendSections([0])
            snapshot.appendItems(items, toSection: 0)
            dataSource.apply(snapshot, animatingDifferences: false)
            stateView.isHidden = true
            collectionView.isHidden = false
            setNeedsFocusUpdate()
        case .empty:
            showState(.empty(
                title: SearchCopy.genreEmptyTitle(genre.title),
                message: SearchCopy.genreEmptyMessage,
                symbol: "film.stack",
                action: TVStateView.Action(title: "Back") { [weak self] in self?.navigationController?.popViewController(animated: true) }
            ))
        case .failed(let message):
            showState(.error(title: SearchCopy.genreFailureTitle(genre.title), message: message, retryTitle: SearchCopy.retry) { [weak self] in
                self?.session.load()
            })
        }
    }

    private func showState(_ state: TVStateView.State) {
        dataSource.apply(NSDiffableDataSourceSnapshot<Int, PlexMetadata>(), animatingDifferences: false)
        stateView.show(state)
        stateView.isHidden = false
        collectionView.isHidden = true
        setNeedsFocusUpdate()
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        let screen: UIViewController
        switch SearchDestination(item: item) {
        case .show(let ratingKey, let initialSeasonKey):
            screen = TVScreens.showDetail(env, ratingKey: ratingKey, initialSeasonKey: initialSeasonKey)
        case .movie, .episode:
            screen = TVScreens.movieDetail(env, ratingKey: item.id, mediaType: "movie")
        }
        navigationController?.pushViewController(screen, animated: true)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let item = dataSource.itemIdentifier(for: indexPath), item.mediaType == "movie" else {
            return nil
        }
        let play = UIAction(title: SearchItemActions.playTitle(for: item), image: UIImage(systemName: "play.fill")) { [weak self] _ in
            self?.play(item)
        }
        return TVContextMenu.configuration(menu: UIMenu(children: [play]))
    }

    private func playFocused(at indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath), item.mediaType == "movie" else { return }
        play(item)
    }

    private func play(_ item: PlexMetadata) {
        TVScreens.play(env, request: TVPlaybackRequest(item: item), from: tabBarController ?? self)
    }
}

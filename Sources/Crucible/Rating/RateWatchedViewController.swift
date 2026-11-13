import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// Everything the viewer finished lately and has not rated, each row with its own stars: tap or slide across them to rate,
/// swipe for Not Now, tap the row for the title's details. Rating reminders and the Home row's See All open it. A title
/// rated here keeps its row and its stars until the screen closes, so nothing moves under the finger and a slip can be
/// put right.
final class RateWatchedViewController: UICollectionViewController {
    private enum Section: Hashable {
        case asks
    }

    private let api: APIClient
    private let feed: RatingAsksFeed
    private let leadingKey: String?
    private var asks: [RatingAsk] = []
    private var ratings: [String: UserRating] = [:]
    private var dataSource: UICollectionViewDiffableDataSource<Section, String>!
    private var ledgerObserver: UUID?
    private var visibilityObserver: UUID?
    private var loadTask: Task<Void, Never>?

    /// `leadingKey` is the title a reminder named, shown first while it is still waiting.
    init(api: APIClient, leadingKey: String? = nil) {
        self.api = api
        self.feed = RatingAsksFeed(api: api)
        self.leadingKey = leadingKey
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        loadTask?.cancel()
        if let ledgerObserver {
            Task { @MainActor in FinishedTitlesLedger.shared.removeObserver(ledgerObserver) }
        }
        if let visibilityObserver {
            Task { @MainActor in LibraryVisibility.removeObserver(visibilityObserver) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = RatingAskCopy.rowTitle
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = Theme.Color.canvas
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.accessibilityIdentifier = "rateWatched.list"
        collectionView.collectionViewLayout = makeLayout()
        configureDataSource()
        ledgerObserver = FinishedTitlesLedger.shared.addObserver { [weak self] in
            guard let self else { return }
            adopt(feed.current())
        }
        visibilityObserver = LibraryVisibility.addObserver { [weak self] in
            guard let self else { return }
            adopt(feed.current())
        }
        adopt(feed.current())
        loadTask = Task { [weak self] in
            guard let self else { return }
            let loaded = await feed.load()
            guard !Task.isCancelled else { return }
            adopt(loaded)
        }
    }

    // MARK: - Layout

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] _, environment in
            var config = Theme.groupedListConfiguration()
            config.headerMode = .supplementary
            config.separatorConfiguration.color = Theme.Color.separator
            config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.swipeActions(at: indexPath)
            }
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            Theme.centerReadable(section, environment)
            return section
        }
    }

    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let self, let ask = asks.first(where: { $0.id == id }) else { return }
            cell.contentConfiguration = RateAskRowConfiguration(
                ask: ask,
                rating: ratings[id],
                onRate: { [weak self] rating in self?.rate(ask, rating) },
                onShare: { [weak self] in self?.shareCard(ask) }
            )
            cell.accessories = [.disclosureIndicator(options: .init(tintColor: Theme.Color.labelTertiary))]
            cell.accessibilityIdentifier = "rateWatched.row.\(id)"
            cell.configurationUpdateHandler = { cell, state in
                var background = UIBackgroundConfiguration.listGroupedCell().updated(for: state)
                background.backgroundColor = state.isHighlighted || state.isSelected ? Theme.Color.surfaceRaised : Theme.Color.surface
                cell.backgroundConfiguration = background
            }
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: id)
        }

        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { cell, _, _ in
            var content = UIListContentConfiguration.groupedFooter()
            content.text = RatingAskCopy.listHint
            content.textProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
            cell.backgroundConfiguration = .clear()
        }

        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    // MARK: - Content

    /// Takes what the ledger asks about now. Rows rated on this screen stay where they were, so the list holds still while
    /// the viewer works down it.
    private func adopt(_ current: [RatingAsk]) {
        let currentIDs = Set(current.map(\.id))
        let ratedHere = asks.enumerated().filter { ratings[$0.element.id] != nil && !currentIDs.contains($0.element.id) }
        var next = leadingFirst(current)
        for (index, ask) in ratedHere {
            next.insert(ask, at: min(index, next.count))
        }
        guard next != asks || dataSource.snapshot().numberOfSections == 0 else { return }
        let changed = Set(next.filter { new in asks.contains { $0.id == new.id && $0 != new } }.map(\.id))
        asks = next
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        if !next.isEmpty {
            snapshot.appendSections([.asks])
            snapshot.appendItems(next.map(\.id))
            snapshot.reconfigureItems(next.map(\.id).filter(changed.contains))
        }
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
        updateEmptyState()
    }

    private func leadingFirst(_ list: [RatingAsk]) -> [RatingAsk] {
        guard let leadingKey, let index = list.firstIndex(where: { $0.id == leadingKey }) else { return list }
        var ordered = list
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }

    private func updateEmptyState() {
        guard asks.isEmpty else {
            contentUnavailableConfiguration = nil
            return
        }
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "star.bubble")
        config.imageProperties.tintColor = Theme.Color.accentText
        config.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .light)
        config.text = RatingAskCopy.emptyTitle
        config.textProperties.font = Theme.Font.title3
        config.textProperties.color = Theme.Color.label
        config.secondaryText = RatingAskCopy.emptyMessage
        config.secondaryTextProperties.font = Theme.Font.subheadline
        config.secondaryTextProperties.color = Theme.Color.labelSecondary
        contentUnavailableConfiguration = config
    }

    // MARK: - Rating

    /// Shows the rating at once and saves it; a rating the server refuses goes back to what the row showed before.
    private func rate(_ ask: RatingAsk, _ rating: UserRating) {
        let previous = ratings[ask.id]
        ratings[ask.id] = rating
        Task { @MainActor [weak self, api] in
            do {
                try await RatingService.setRating(rating, ratingKey: ask.ratingKey, api: api)
                Haptics.success()
            } catch {
                Haptics.error()
                guard let self, ratings[ask.id] == rating else { return }
                ratings[ask.id] = previous
                reconfigure(ask.id)
            }
        }
    }

    private func reconfigure(_ id: String) {
        var snapshot = dataSource.snapshot()
        guard snapshot.indexOfItem(id) != nil else { return }
        snapshot.reconfigureItems([id])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The card of a title on this list, opening on what the viewer rated here (the show, for a season they closed) with
    /// the stars they gave, which the server may still be saving.
    private func shareCard(_ ask: RatingAsk) {
        let origin = WatchCardOrigin(ask: ask)
        guard let rating = ratings[ask.id] else {
            WatchCardScreens.present(origin, api: api, from: self)
            return
        }
        WatchCardScreens.present(origin.starting(at: ask.isShow ? .show : .movie), api: api, from: self, rated: (ask.ratingKey, rating))
    }

    private func notNow(_ ask: RatingAsk) {
        Haptics.light()
        FinishedTitlesLedger.shared.dismiss(ask.ratingKey)
    }

    // MARK: - Interaction

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), ratings[id] == nil,
              let ask = asks.first(where: { $0.id == id }) else { return nil }
        let action = UIContextualAction(style: .normal, title: RatingAskCopy.notNow) { [weak self] _, _, done in
            self?.notNow(ask)
            done(true)
        }
        action.image = UIImage(systemName: "xmark.circle")
        action.backgroundColor = Theme.Color.labelTertiary
        return UISwipeActionsConfiguration(actions: [action])
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let ask = asks.first(where: { $0.id == id }) else { return }
        RateAskActions.openDetail(ask, api: api, from: navigationController)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let id = dataSource.itemIdentifier(for: indexPath),
              let ask = asks.first(where: { $0.id == id }) else { return nil }
        let isRated = ratings[id] != nil
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            let details = UIAction(title: String(localized: "View Details"), image: UIImage(systemName: "info.circle")) { [weak self] _ in
                guard let self else { return }
                RateAskActions.openDetail(ask, api: api, from: navigationController)
            }
            let notNow = UIAction(title: RatingAskCopy.notNow, image: UIImage(systemName: "xmark.circle")) { [weak self] _ in
                self?.notNow(ask)
            }
            let share = UIAction(title: WatchCardScreens.title, image: UIImage(systemName: WatchCardScreens.symbol)) { [weak self] _ in
                self?.shareCard(ask)
            }
            return UIMenu(children: isRated ? [details, share] : [details, share, notNow])
        })
    }
}

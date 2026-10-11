import CrucibleCore
import CrucibleDesign
import UIKit

/// The shared body of the movie, episode and show detail screens: a backdrop with scrims, a hero
/// block, the synopsis with More, an action row and the shelves below, driven by one
/// `TVDetailContent` value. Subclasses fetch and map their model, then call `present(_:)`.
///
/// Items carry only stable identities; their content is looked up from the current `TVDetailContent`
/// when a cell is configured, so a refresh after playback or a watched change reconfigures cells in
/// place and never moves the focus.
@MainActor
class TVDetailViewController: UIViewController, UICollectionViewDelegate {
    enum Section: Int, Hashable {
        case header
        case synopsis
        case actions
        case seasons
        case episodes
        case cast
        case related
        case information
    }

    enum Item: Hashable {
        case header
        case synopsis
        case action(TVDetailAction.Kind)
        case season(String)
        case episode(String)
        case person(String)
        case related(String)
        case information
        case emptyEpisodes
        case episodePlaceholder(Int)
        case episodesFailed
    }

    static let heroHeight: CGFloat = 400

    let env: TVAppEnvironment
    private(set) var content: TVDetailContent?
    private(set) var hasContent = false
    private var isShowingState: Bool { stateView.superview != nil && !stateView.isHidden }

    private let collectionView: TVCollectionView
    private let backdrop = TVBackdropView()
    private let stateView = TVStateView()
    private let skeleton = TVDetailSkeletonView()
    private let focusAnchor = TVFocusAnchorView()
    private let focusMemory = TVFocusMemory()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var loadTask: Task<Void, Never>?
    private var backdropTask: Task<Void, Never>?
    private var shownBackdropPath: String?

    init(env: TVAppEnvironment) {
        self.env = env
        collectionView = TVCollectionView(frame: .zero, collectionViewLayout: UICollectionViewLayout())
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        loadTask?.cancel()
        backdropTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)

        collectionView.collectionViewLayout = makeLayout()
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.onPlayPause = { [weak self] indexPath in self?.playPause(at: indexPath) }
        view.addSubview(collectionView)
        configureDataSource()

        [skeleton, stateView, focusAnchor].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            skeleton.topAnchor.constraint(equalTo: view.topAnchor),
            skeleton.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            skeleton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            skeleton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            focusAnchor.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            focusAnchor.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            focusAnchor.widthAnchor.constraint(equalToConstant: 2),
            focusAnchor.heightAnchor.constraint(equalToConstant: 2),
        ])
        stateView.isHidden = true
        collectionView.isHidden = true
        showLoading()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if hasContent, !collectionView.isHidden { return [collectionView] }
        if isShowingState { return [stateView] }
        return [focusAnchor]
    }

    func fetch() async {}

    func playPause(at indexPath: IndexPath) {}

    func didSelect(_ item: Item) {}

    func contextMenu(for item: Item) -> UIMenu? { nil }

    func retryEpisodes() {}

    /// Starts a fresh load, cancelling one in flight. While content is on screen it is refreshed in place.
    func reload() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.fetch()
        }
    }

    func showLoading() {
        hasContent = false
        collectionView.isHidden = true
        stateView.isHidden = true
        skeleton.isHidden = false
        focusAnchor.isHidden = false
        moveFocusIntoScreen()
    }

    func showUnavailable(_ message: String) {
        hasContent = false
        collectionView.isHidden = true
        skeleton.isHidden = true
        focusAnchor.isHidden = true
        stateView.isHidden = false
        stateView.show(.empty(
            title: "Not Available",
            message: message,
            symbol: "questionmark.circle",
            action: TVStateView.Action(title: "Go Back") { [weak self] in
                self?.navigationController?.popViewController(animated: !UIAccessibility.isReduceMotionEnabled)
            }
        ))
        moveFocusIntoScreen()
    }

    func showFailure(title: String, message: String) {
        hasContent = false
        collectionView.isHidden = true
        skeleton.isHidden = true
        focusAnchor.isHidden = true
        stateView.isHidden = false
        stateView.show(.error(title: title, message: message, retryTitle: "Retry") { [weak self] in
            self?.showLoading()
            self?.reload()
        })
        moveFocusIntoScreen()
    }

    func itemIdentifier(at indexPath: IndexPath) -> Item? {
        dataSource.itemIdentifier(for: indexPath)
    }

    /// Pushes the screen for `route` unless this screen is no longer on top or a transition is running,
    /// so mashing Select or a lookup that finishes after Back cannot stack screens.
    func push(_ route: DetailRoute) {
        guard let navigation = navigationController, navigation.topViewController === self, navigation.transitionCoordinator == nil else { return }
        navigation.pushViewController(TVDetailNavigation.viewController(for: route, env: env), animated: true)
    }

    func play(_ request: TVPlaybackRequest) {
        TVDetailNavigation.play(request, env: env, from: self)
    }

    /// Marks `ratingKey` (a movie, episode, season or show) watched or unwatched, then refreshes the screen.
    func markWatched(_ watched: Bool, ratingKey: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await WatchedService.setWatched(watched, ratingKey: ratingKey, api: env.api)
                reload()
            } catch {
                presentAlert(title: "Couldn\u{2019}t Update", message: error.localizedDescription)
            }
        }
    }

    func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    func presentSynopsis() {
        guard let content, let text = content.synopsis else { return }
        present(TVSynopsisViewController(title: content.synopsisTitle, text: text), animated: !UIAccessibility.isReduceMotionEnabled)
    }

    /// Shows `content`, reconfiguring the cells already on screen. The first content moves focus to
    /// the primary action; later refreshes leave focus where the viewer put it.
    func present(_ content: TVDetailContent) {
        let isFirst = !hasContent
        self.content = content
        hasContent = true
        skeleton.isHidden = true
        stateView.isHidden = true
        focusAnchor.isHidden = true
        collectionView.isHidden = false
        showBackdrop(content.artwork)
        applySnapshot(for: content)
        if isFirst {
            collectionView.layoutIfNeeded()
            moveFocusIntoScreen()
        }
    }

    /// Moves focus to the screen's preferred item. When the tab bar holds focus (a link opened this
    /// screen from outside) the system keeps it there and the viewer presses Down, as in other tvOS apps.
    private func moveFocusIntoScreen() {
        guard isViewLoaded, let system = UIFocusSystem.focusSystem(for: view) else { return }
        system.requestFocusUpdate(to: self)
    }

    private func showBackdrop(_ artwork: DetailArtwork) {
        guard artwork.path != shownBackdropPath else { return }
        shownBackdropPath = artwork.path
        backdropTask?.cancel()
        guard let path = artwork.path else {
            backdrop.show(image: nil, animated: true)
            return
        }
        let kind: TVImagePipeline.Kind = artwork.isBackdrop ? .backdrop : .poster
        let scale = max(traitCollection.displayScale, 1)
        backdropTask = Task { [weak self] in
            let image = await TVImagePipeline.load(path: path, pointWidth: 1920, scale: scale, kind: kind)
            guard !Task.isCancelled, let self, self.shownBackdropPath == path else { return }
            self.backdrop.show(image: image, animated: true)
        }
    }

    private func applySnapshot(for content: TVDetailContent) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.header])
        snapshot.appendItems([.header], toSection: .header)
        if !(content.synopsis ?? "").isEmpty {
            snapshot.appendSections([.synopsis])
            snapshot.appendItems([.synopsis], toSection: .synopsis)
        }
        snapshot.appendSections([.actions])
        snapshot.appendItems(content.actions.map { .action($0.kind) }, toSection: .actions)
        if !content.seasons.isEmpty {
            snapshot.appendSections([.seasons])
            snapshot.appendItems(Self.unique(content.seasons.map { .season($0.id) }), toSection: .seasons)
        }
        if content.showsEpisodes {
            snapshot.appendSections([.episodes])
            snapshot.appendItems(Self.episodeItems(for: content), toSection: .episodes)
        }
        if !content.cast.isEmpty {
            snapshot.appendSections([.cast])
            snapshot.appendItems(Self.unique(content.cast.map { .person($0.id) }), toSection: .cast)
        }
        if !content.related.isEmpty {
            snapshot.appendSections([.related])
            snapshot.appendItems(Self.unique(content.related.map { .related($0.id) }), toSection: .related)
        }
        if !content.facts.isEmpty {
            snapshot.appendSections([.information])
            snapshot.appendItems([.information], toSection: .information)
        }
        let previous = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { previous.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: false)
        refreshHeaders()
    }

    private static func episodeItems(for content: TVDetailContent) -> [Item] {
        switch content.episodesState {
        case .loading: (0 ..< 4).map { .episodePlaceholder($0) }
        case .failed: [.episodesFailed]
        case .loaded: content.episodes.isEmpty ? [.emptyEpisodes] : unique(content.episodes.map { .episode($0.id) })
        }
    }

    /// A diffable snapshot traps on a repeated identifier, so a server that lists an item twice shows it once.
    private static func unique(_ items: [Item]) -> [Item] {
        var seen = Set<Item>()
        return items.filter { seen.insert($0).inserted }
    }

    /// Headers are supplementary views, which a snapshot does not reconfigure, so a new season title
    /// or episode count is pushed into the ones already on screen.
    private func refreshHeaders() {
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: TVShelf.headerKind) {
            (collectionView.supplementaryView(forElementKind: TVShelf.headerKind, at: indexPath) as? TVSectionHeaderView)?
                .configure(sectionHeader(at: indexPath))
        }
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, _ in
            guard let section = self?.dataSource?.sectionIdentifier(for: index) else { return Self.block(top: 0, bottom: 0) }
            switch section {
            case .header: return TVShelf.hero(height: Self.heroHeight)
            case .synopsis: return Self.block(top: 0, bottom: TVMetrics.shelfTopInset)
            case .actions: return Self.actionRow()
            case .seasons: return TVShelf.chips()
            case .episodes: return TVShelf.episode()
            case .cast: return TVShelf.person()
            case .related: return TVShelf.poster()
            case .information: return Self.informationSection()
            }
        }
    }

    private static func block(top: CGFloat, bottom: CGFloat) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(160))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: top, leading: 0, bottom: bottom, trailing: 0)
        return section
    }

    private static func actionRow() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .estimated(260), heightDimension: .absolute(TVMetrics.Control.primaryHeight))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
        section.interGroupSpacing = Theme.Space.m
        section.contentInsets = NSDirectionalEdgeInsets(
            top: TVMetrics.shelfTopInset,
            leading: 0,
            bottom: TVMetrics.shelfVerticalInset,
            trailing: 0
        )
        return section
    }

    private static func informationSection() -> NSCollectionLayoutSection {
        let section = block(top: 0, bottom: TVMetrics.shelfTopInset)
        section.boundarySupplementaryItems = [
            NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(TVMetrics.shelfHeaderHeight)),
                elementKind: TVShelf.headerKind,
                alignment: .top
            ),
        ]
        return section
    }

    private func configureDataSource() {
        let hero = TVHeroCell.registration { [weak self] info in
            info.configure(self?.content?.header)
        }
        let synopsis = TVDetailSynopsisCell.registration(
            text: { [weak self] in self?.content?.synopsis },
            onMore: { [weak self] in self?.presentSynopsis() }
        )
        let action = TVDetailActionCell.registration { [weak self] kind in
            self?.content?.actions.first { $0.kind == kind }
        }
        let season = TVChipCell.registration { [weak self] chip in
            self?.didSelect(.season(chip.id))
        }
        let episode = TVEpisodeCell.registration()
        let person = TVPersonCell.registration()
        let related = TVPosterCell.registration()
        let information = TVDetailInformationCell.registration { [weak self] in self?.content?.facts ?? [] }
        let placeholder = UICollectionView.CellRegistration<TVDetailEpisodePlaceholderCell, Int> { cell, _, index in
            cell.configure(index: index)
        }
        let failed = TVDetailEpisodesFailedCell.registration { [weak self] in self?.retryEpisodes() }
        let empty = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, _, _ in
            var configuration = UIListContentConfiguration.cell()
            configuration.text = "No episodes in this season"
            configuration.textProperties.font = Theme.Font.body
            configuration.textProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = configuration
            cell.backgroundConfiguration = .clear()
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
            let content = self?.content
            switch item {
            case .header:
                return collectionView.dequeueConfiguredReusableCell(using: hero, for: indexPath, item: 0)
            case .synopsis:
                return collectionView.dequeueConfiguredReusableCell(using: synopsis, for: indexPath, item: 0)
            case .action(let kind):
                return collectionView.dequeueConfiguredReusableCell(using: action, for: indexPath, item: kind)
            case .season(let id):
                let chip = content?.seasons.first { $0.id == id } ?? TVChipItem(id: id, title: "")
                return collectionView.dequeueConfiguredReusableCell(using: season, for: indexPath, item: chip)
            case .episode(let id):
                let card = content?.episodes.first { $0.id == id } ?? TVCardItem(id: id, title: "")
                return Self.identified(collectionView.dequeueConfiguredReusableCell(using: episode, for: indexPath, item: card), id)
            case .person(let id):
                let card = content?.cast.first { $0.id == id } ?? TVCardItem(id: id, title: "")
                let cell = Self.identified(collectionView.dequeueConfiguredReusableCell(using: person, for: indexPath, item: card), id)
                cell.accessibilityTraits = .staticText
                return cell
            case .related(let id):
                let card = content?.related.first { $0.id == id } ?? TVCardItem(id: id, title: "")
                return Self.identified(collectionView.dequeueConfiguredReusableCell(using: related, for: indexPath, item: card), id)
            case .information:
                return collectionView.dequeueConfiguredReusableCell(using: information, for: indexPath, item: 0)
            case .emptyEpisodes:
                return collectionView.dequeueConfiguredReusableCell(using: empty, for: indexPath, item: 0)
            case .episodePlaceholder(let index):
                return collectionView.dequeueConfiguredReusableCell(using: placeholder, for: indexPath, item: index)
            case .episodesFailed:
                return collectionView.dequeueConfiguredReusableCell(using: failed, for: indexPath, item: 0)
            }
        }

        let header = TVSectionHeaderView.registration { [weak self] indexPath in
            self?.sectionHeader(at: indexPath)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private static func identified(_ cell: UICollectionViewCell, _ id: String) -> UICollectionViewCell {
        cell.accessibilityIdentifier = "detail.\(id)"
        return cell
    }

    private func sectionHeader(at indexPath: IndexPath) -> TVSectionHeader? {
        guard let section = dataSource.sectionIdentifier(for: indexPath.section) else { return nil }
        switch section {
        case .episodes: return content?.episodesHeader
        case .cast: return TVSectionHeader(title: "Cast & Crew")
        case .related: return TVSectionHeader(title: "More Like This")
        case .information: return TVSectionHeader(title: "Information")
        default: return nil
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .episode, .related: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        didSelect(item)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return TVContextMenu.configuration(menu: contextMenu(for: item))
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        if let remembered = focusMemory.preferredIndexPath(in: collectionView) { return remembered }
        return primaryActionIndexPath()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        focusMemory.record(context)
        guard let next = context.nextFocusedIndexPath,
              let section = dataSource.sectionIdentifier(for: next.section),
              section == .synopsis || section == .actions
        else { return }
        coordinator.addCoordinatedAnimations({
            collectionView.contentOffset = CGPoint(x: collectionView.contentOffset.x, y: -collectionView.adjustedContentInset.top)
        })
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collectionView else { return }
        backdrop.dimming = scrollView.contentOffset.y / Self.heroHeight
    }

    private func primaryActionIndexPath() -> IndexPath? {
        let snapshot = dataSource.snapshot()
        guard let first = snapshot.itemIdentifiers(inSection: .actions).first(where: { item in
            guard case .action(let kind) = item else { return false }
            return content?.actions.first { $0.kind == kind }?.isEnabled == true
        }) else {
            return snapshot.itemIdentifiers(inSection: .seasons).first.flatMap { dataSource.indexPath(for: $0) }
        }
        return dataSource.indexPath(for: first)
    }
}

import CrucibleCore
import CrucibleDesign
import UIKit

/// The shared body of the movie, episode and show detail screens: a backdrop with scrims, a hero
/// block, the synopsis with More, an action row and the shelves below, driven by one
/// `TVDetailContent` value. Subclasses fetch and map their model, then call `present(_:)`.
///
/// The screen is a `TVScreenViewController`: the host owns the state view, the loading focus anchor,
/// identifier-keyed focus memory and task slots; Detail adds the backdrop and a skeleton for the
/// first load, and lays the collection out with its own sections.
///
/// Items carry only stable identities; their content is looked up from the current `TVDetailContent`
/// when a cell is configured, so a refresh after playback or a watched change reconfigures cells in
/// place and never moves the focus.
@MainActor
class TVDetailViewController: TVScreenViewController {
    enum Section: Int, Hashable, Sendable {
        case header
        case synopsis
        case actions
        case seasons
        case episodes
        case cast
        case related
        case information
    }

    enum Item: Hashable, Sendable {
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

    private let backdrop = TVBackdropView()
    private let skeleton = TVDetailSkeletonView()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private lazy var loadSlot = makeTaskSlot()

    init(env: TVAppEnvironment) {
        self.env = env
        super.init(layout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func installViews() {
        super.installViews()
        [backdrop, skeleton].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        view.insertSubview(backdrop, at: 0)
        view.insertSubview(skeleton, aboveSubview: collectionView)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            skeleton.topAnchor.constraint(equalTo: view.topAnchor),
            skeleton.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            skeleton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            skeleton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        collectionView.collectionViewLayout = makeLayout()
        configureDataSource()
        adopt(dataSource)
        showLoading()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    func fetch() async {}

    func didSelect(_ item: Item) {}

    func contextMenu(for item: Item) -> UIMenu? { nil }

    func retryEpisodes() {}

    /// Starts a fresh load, cancelling one in flight. While content is on screen it is refreshed in place.
    func reload() {
        loadSlot.run { [weak self] in
            await self?.fetch()
        }
    }

    func showLoading() {
        hasContent = false
        collectionView.isHidden = true
        stateView.isHidden = true
        skeleton.isHidden = false
    }

    func showUnavailable(_ message: String) {
        hasContent = false
        skeleton.isHidden = true
        show(state: .empty(
            title: "Not Available",
            message: message,
            symbol: "questionmark.circle",
            action: TVStateView.Action(title: "Go Back") { [weak self] in
                guard let self else { return }
                TVNavigation.pop(from: self)
            }
        ))
    }

    func showFailure(title: String, message: String) {
        hasContent = false
        skeleton.isHidden = true
        show(state: .error(title: title, message: message, retryTitle: "Retry") { [weak self] in
            self?.showLoading()
            self?.reload()
        })
    }

    func itemIdentifier(at indexPath: IndexPath) -> Item? {
        dataSource.itemIdentifier(for: indexPath)
    }

    func push(_ route: DetailRoute) {
        TVNavigation.push(TVScreens.screen(for: route, env: env), from: self)
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

    func presentSynopsis() {
        guard let content, let text = content.synopsis else { return }
        present(TVSynopsisViewController(title: content.synopsisTitle, text: text), animated: TVMotion.animationsEnabled)
    }

    /// Shows `content`, reconfiguring the cells already on screen. The first content moves focus to
    /// the primary action when focus was on this screen's loading state; later refreshes leave focus
    /// where the viewer put it.
    func present(_ content: TVDetailContent) {
        self.content = content
        hasContent = true
        skeleton.isHidden = true
        backdrop.show(path: content.artwork.path, kind: content.artwork.isBackdrop ? .backdrop : .poster, immediate: true)
        applySnapshot(for: content)
        showContent()
    }

    override func initialFocusIndexPath() -> IndexPath? {
        let snapshot = dataSource.snapshot()
        let enabled = snapshot.itemIdentifiers(inSection: .actions).first { item in
            guard case .action(let kind) = item else { return false }
            return content?.actions.first { $0.kind == kind }?.isEnabled == true
        }
        guard let first = enabled ?? snapshot.itemIdentifiers(inSection: .seasons).first else { return nil }
        return dataSource.indexPath(for: first)
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
        dataSource.applyReconfiguringExisting(snapshot)
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
        let person = TVDetailPersonCell.registration()
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
                let model = content?.cast.first { $0.id == id } ?? TVDetailPerson(id: id, name: "")
                return Self.identified(collectionView.dequeueConfiguredReusableCell(using: person, for: indexPath, item: model), id)
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

    override func collectionView(
        _ collectionView: UICollectionView,
        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        super.collectionView(collectionView, didUpdateFocusIn: context, with: coordinator)
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
}

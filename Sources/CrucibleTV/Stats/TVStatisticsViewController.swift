import CrucibleCore
import CrucibleDesign
import CrucibleStats
import CrucibleStatsUI
import UIKit

/// Year in Review on a 65-inch screen: range chips and the Libraries filter, the ember hero with its
/// count-up, KPI tiles, the activity heatmap, top titles, viewing patterns, momentum, libraries,
/// binges, taste, On This Day and Wrapped moments. Every section is focusable (cards and posters),
/// so the remote can scroll the whole page.
@MainActor
final class TVStatisticsViewController: UIViewController {
    private let env: TVAppEnvironment
    private let collectionView: TVCollectionView
    private let stateView = TVStateView()
    private let focusMemory = TVFocusMemory()
    private var dataSource: UICollectionViewDiffableDataSource<TVStatsSection, TVStatsItem>!
    private weak var controlsView: TVStatsControlsView?

    private var loader: StatsPageLoader? { StatsManager.shared.pageLoader }

    private var page = StatsPage.empty
    private var range = StatsRange.year
    private var dataVersion = 0
    private var heroShouldAnimate = true
    private var syncedAtLeastOnce = false
    private var loadTask: Task<Void, Never>?
    private var visibilityObserver: UUID?

    init(environment: TVAppEnvironment) {
        env = environment
        collectionView = TVCollectionView(frame: .zero, collectionViewLayout: UICollectionViewLayout())
        super.init(nibName: nil, bundle: nil)
        title = "Statistics"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let visibilityObserver {
            Task { @MainActor in LibraryVisibility.removeObserver(visibilityObserver) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        configureCollectionView()
        setContentScrollView(collectionView, for: .top)
        configureStateView()
        configureDataSource()
        collectionView.collectionViewLayout = makeLayout()
        visibilityObserver = LibraryVisibility.addObserver { [weak self] in
            self?.librariesChanged()
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        load(animateHero: true)
        Task { [weak self] in
            await StatsManager.shared.refreshNow()
            self?.syncedAtLeastOnce = true
            self?.load(animateHero: false)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        stateView.isHidden ? [collectionView] : [stateView]
    }

    private func configureCollectionView() {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "stats.collection"
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func configureStateView() {
        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateView.isHidden = true
        view.addSubview(stateView)
        NSLayoutConstraint.activate([
            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func load(animateHero: Bool) {
        guard let loader else {
            show(placeholder: .unavailable)
            return
        }
        loadTask?.cancel()
        let range = self.range
        loadTask = Task { [weak self] in
            do {
                let loaded = try await loader.load(range: range)
                guard !Task.isCancelled, let self else { return }
                apply(loaded, animateHero: animateHero)
            } catch {
                guard !Task.isCancelled, let self else { return }
                loadFailed()
            }
        }
    }

    private func apply(_ loaded: StatsPage, animateHero: Bool) {
        if !loaded.isEmpty, loaded == page, stateView.isHidden {
            return
        }
        page = loaded
        dataVersion += 1
        heroShouldAnimate = animateHero
        guard !loaded.isEmpty else {
            dataSource.apply(NSDiffableDataSourceSnapshot<TVStatsSection, TVStatsItem>(), animatingDifferences: false)
            show(placeholder: StatsPlaceholder.forEmptyPage(syncedAtLeastOnce: syncedAtLeastOnce, librariesFiltered: LibraryVisibility.isCustomized))
            return
        }
        hidePlaceholder()
        dataSource.apply(makeSnapshot(), animatingDifferences: false)
        controlsView?.configure(range: range, subtitle: loaded.hero.since, filter: StatsLibraryFilter.current())
        collectionView.collectionViewLayout.invalidateLayout()
    }

    private func loadFailed() {
        guard page.isEmpty else { return }
        stateView.show(.error(
            title: "Couldn't Load Statistics",
            message: "The local statistics store could not be read.",
            retryTitle: "Try Again"
        ) { [weak self] in
            self?.load(animateHero: true)
        })
        revealState()
    }

    private func librariesChanged() {
        controlsView?.updateLibraries(StatsLibraryFilter.current())
        load(animateHero: false)
    }

    private func selectRange(_ newRange: StatsRange) {
        guard newRange != range else { return }
        range = newRange
        load(animateHero: true)
    }

    private func show(placeholder: StatsPlaceholder) {
        switch placeholder {
        case .loading:
            stateView.show(.loading(title: placeholder.title))
        case .unavailable:
            stateView.show(.empty(title: placeholder.title, message: placeholder.message, symbol: placeholder.symbol ?? "exclamationmark.triangle", action: nil))
        case .empty(let filtered):
            stateView.show(.empty(
                title: placeholder.title,
                message: placeholder.message,
                symbol: placeholder.symbol ?? "chart.bar.xaxis",
                action: filtered ? includeAllLibrariesAction() : nil
            ))
        }
        revealState()
    }

    private func includeAllLibrariesAction() -> TVStateView.Action {
        TVStateView.Action(title: "Include All Libraries") {
            let filter = StatsLibraryFilter.current()
            filter.entries.filter { !$0.isIncluded }.forEach { filter.toggle($0) }
        }
    }

    private func revealState() {
        stateView.isHidden = false
        collectionView.isHidden = true
        setNeedsFocusUpdate()
    }

    private func hidePlaceholder() {
        guard !stateView.isHidden else { return }
        stateView.isHidden = true
        collectionView.isHidden = false
        setNeedsFocusUpdate()
    }

    private func makeSnapshot() -> NSDiffableDataSourceSnapshot<TVStatsSection, TVStatsItem> {
        var snapshot = NSDiffableDataSourceSnapshot<TVStatsSection, TVStatsItem>()
        snapshot.appendSections([.controls])
        snapshot.appendItems([.controls], toSection: .controls)
        for section in TVStatsSection.allCases {
            guard let pageSection = section.pageSection, page.sections.contains(pageSection) else { continue }
            snapshot.appendSections([section])
            snapshot.appendItems(items(for: section), toSection: section)
        }
        return snapshot
    }

    private func items(for section: TVStatsSection) -> [TVStatsItem] {
        let version = dataVersion
        switch section {
        case .controls:
            return [.controls]
        case .hero:
            return [.hero(version)]
        case .kpis:
            return page.tiles.map { .tile($0) }
        case .heatmap, .clock, .momentum, .libraries, .genres:
            return [.panel(section, version)]
        case .topShows:
            return page.topShows.map { show in
                .poster(section, Self.card(for: show), .show(ratingKey: show.ratingKey))
            }
        case .topMovies:
            return page.topMovies.map { .poster(section, Self.card($0, id: "movie-\($0.destination)"), $0.destination) }
        case .onThisDay:
            return page.onThisDay.enumerated().map { index, poster in
                .poster(section, Self.card(poster, id: "day-\(index)-\(poster.destination)"), poster.destination)
            }
        case .binges:
            return page.binges.enumerated().map { .binge($1, $0) }
        case .superlatives:
            return page.superlatives.map { .wrapped($0) }
        }
    }

    private static func card(for show: StatsPage.ShowRow) -> TVCardItem {
        var subtitle = show.valueText
        if let completion = show.completion {
            subtitle += " · \(Int((completion * 100).rounded()))%"
        }
        return TVCardItem(
            id: "show-\(show.ratingKey)",
            artworkPath: show.thumb,
            title: show.title,
            subtitle: subtitle,
            badgeText: "#\(show.rank)",
            placeholderSymbol: "tv"
        )
    }

    private static func card(_ poster: StatsPoster, id: String) -> TVCardItem {
        TVCardItem(
            id: id,
            artworkPath: poster.posterPath,
            title: poster.title,
            subtitle: poster.subtitle,
            placeholderSymbol: poster.placeholderSymbol
        )
    }

    private func configureDataSource() {
        let hostRegistration = UICollectionView.CellRegistration<TVStatsHostCell, TVStatsItem> { [weak self] cell, _, item in
            guard let self, let view = hostedView(for: item) else { return }
            cell.host(view)
        }
        let posterRegistration = TVPosterCell.registration()
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .poster(_, let card, _):
                return collectionView.dequeueConfiguredReusableCell(using: posterRegistration, for: indexPath, item: card)
            default:
                return collectionView.dequeueConfiguredReusableCell(using: hostRegistration, for: indexPath, item: item)
            }
        }
        let headerRegistration = TVSectionHeaderView.registration { [weak self] indexPath in
            guard let section = self?.dataSource.snapshot().sectionIdentifiers[safe: indexPath.section] else { return nil }
            return section.headerTitle.map { TVSectionHeader(title: $0) }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
    }

    private func hostedView(for item: TVStatsItem) -> UIView? {
        switch item {
        case .controls:
            return makeControlsView()
        case .hero:
            return TVStatsContent.hero(page, animate: heroShouldAnimate)
        case .tile(let tile):
            return TVStatsContent.tile(tile)
        case .panel(let section, _):
            return panel(for: section)
        case .binge(let session, let index):
            return bingePanel(session, index: index)
        case .wrapped(let superlative):
            return TVStatsContent.wrapped(superlative)
        case .poster:
            return nil
        }
    }

    private func makeControlsView() -> UIView {
        let controls = TVStatsControlsView()
        controls.onRange = { [weak self] range in self?.selectRange(range) }
        controls.configure(range: range, subtitle: page.isEmpty ? nil : page.hero.since, filter: StatsLibraryFilter.current())
        controlsView = controls
        return controls
    }

    private func panel(for section: TVStatsSection) -> UIView? {
        switch section {
        case .heatmap: TVStatsContent.heatmap(page)
        case .clock: TVStatsContent.clock(page)
        case .momentum: TVStatsContent.momentum(page)
        case .libraries: TVStatsContent.libraries(page)
        case .genres: TVStatsContent.genres(page)
        default: nil
        }
    }

    private func bingePanel(_ session: BingeSession, index: Int) -> UIView {
        let panel = TVStatsContent.binge(session, colorIndex: index)
        if let showRatingKey = session.showRatingKey, let panel = panel as? TVStatsPanel {
            panel.onSelect = { [weak self] in self?.push(.show(ratingKey: showRatingKey)) }
        }
        return panel
    }

    private func push(_ destination: StatsDestination) {
        let ratingKey: String
        let mediaType: String
        switch destination {
        case .movie(let key):
            (ratingKey, mediaType) = (key, "movie")
        case .episode(let key, _):
            (ratingKey, mediaType) = (key, "episode")
        case .show(let key):
            (ratingKey, mediaType) = (key, "show")
        }
        navigationController?.pushViewController(TVScreens.detail(env, ratingKey: ratingKey, mediaType: mediaType), animated: true)
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, _ in
            guard let section = self?.dataSource.snapshot().sectionIdentifiers[safe: index] else { return nil }
            return Self.layout(for: section)
        }
    }

    private static func layout(for section: TVStatsSection) -> NSCollectionLayoutSection {
        switch section {
        case .controls:
            return fullWidth(estimatedHeight: 130, insets: NSDirectionalEdgeInsets(top: 100, leading: 0, bottom: 36, trailing: 0))
        case .hero:
            return fullWidth(estimatedHeight: 420, insets: NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 44, trailing: 0))
        case .kpis:
            return tiles()
        case .heatmap, .clock, .momentum, .libraries, .genres:
            return fullWidth(estimatedHeight: 500, insets: NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 44, trailing: 0))
        case .topShows, .topMovies, .onThisDay:
            return TVShelf.poster()
        case .binges:
            return shelf(
                width: .estimated(StatsMetrics.tv.bingeTimeline.minCardWidth),
                height: Self.bingeCardHeight
            )
        case .superlatives:
            return shelf(width: .absolute(Self.wrappedCardWidth), height: StatsMetrics.tv.wrappedCard.intrinsicHeight)
        }
    }

    private static let bingeCardHeight: CGFloat = 250
    private static let wrappedCardWidth: CGFloat = 620
    private static let tileColumns = 3

    private static func fullWidth(estimatedHeight: CGFloat, insets: NSDirectionalEdgeInsets) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(estimatedHeight))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = insets
        return section
    }

    private static func tiles() -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0 / CGFloat(tileColumns)),
            heightDimension: .estimated(StatsMetrics.tv.tile.minHeight)
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(StatsMetrics.tv.tile.minHeight)),
            repeatingSubitem: NSCollectionLayoutItem(layoutSize: itemSize),
            count: tileColumns
        )
        group.interItemSpacing = .fixed(TVMetrics.gutter)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = TVMetrics.gutter
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 44, trailing: 0)
        return section
    }

    private static func shelf(width: NSCollectionLayoutDimension, height: CGFloat) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: width, heightDimension: .absolute(height))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
        section.interGroupSpacing = TVMetrics.gutter
        section.contentInsets = NSDirectionalEdgeInsets(top: TVMetrics.shelfTopInset, leading: 0, bottom: TVMetrics.shelfBottomInset, trailing: 0)
        let header = NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(TVMetrics.shelfHeaderHeight)),
            elementKind: TVShelf.headerKind,
            alignment: .top
        )
        section.boundarySupplementaryItems = [header]
        return section
    }
}

extension TVStatisticsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard case .poster(_, _, let destination)? = dataSource.itemIdentifier(for: indexPath) else { return }
        push(destination)
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        focusMemory.preferredIndexPath(in: collectionView) ?? IndexPath(item: 0, section: 0)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        focusMemory.record(context)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

import CrucibleCore
import CrucibleDesign
import CrucibleStats
import CrucibleStatsUI
import UIKit

/// Year in Review on a 65-inch screen: range chips and the Libraries filter, the ember hero with its
/// count-up, KPI tiles, the activity heatmap, top titles, viewing patterns, momentum, libraries,
/// binges, taste, On This Day and Wrapped moments. Every section is focusable (cards and posters),
/// so the remote can scroll the whole page. Built on `TVScreenViewController`: Menu pops while the
/// first load runs, and focus is remembered by item.
@MainActor
final class TVStatisticsViewController: TVScreenViewController {
    private final class LayoutSource {
        weak var screen: TVStatisticsViewController?
    }

    private let env: TVAppEnvironment
    private var dataSource: UICollectionViewDiffableDataSource<TVStatsSection, TVStatsItem>!
    private let controlsView = TVStatsControlsView()
    private var hostedViews: [TVStatsItem: UIView] = [:]

    private lazy var loadSlot = makeTaskSlot()
    private lazy var syncSlot = makeTaskSlot()

    private var loader: StatsPageLoader? { StatsManager.shared.pageLoader }

    private var page = StatsPage.empty
    private var range = StatsRange.year
    private var dataVersion = 0
    private var heroShouldAnimate = true
    private var hasLoadedOnce = false
    private var syncedAtLeastOnce = false
    private var visibilityObserver: UUID?
    private var proObserver: UUID?

    init(environment: TVAppEnvironment) {
        env = environment
        let source = LayoutSource()
        let layout = Self.makeLayout(source)
        super.init(layout: layout)
        source.screen = self
        title = "Statistics"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let visibilityObserver {
            Task { @MainActor in LibraryVisibility.removeObserver(visibilityObserver) }
        }
        if let proObserver {
            Task { @MainActor in ProAccess.shared.stopObserving(proObserver) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.accessibilityIdentifier = "stats.collection"
        setContentScrollView(collectionView, for: .top)
        controlsView.onRange = { [weak self] range in self?.selectRange(range) }
        controlsView.onLocked = { [weak self] lock in self?.unlock(lock) }
        applyLocks()
        configureDataSource()
        visibilityObserver = LibraryVisibility.addObserver { [weak self] in
            self?.librariesChanged()
        }
        proObserver = ProAccess.shared.observe { [weak self] _ in self?.proStatusChanged() }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if !hasLoadedOnce {
            show(placeholder: .loading)
        }
        load(animateHero: true)
        syncSlot.run { [weak self] in
            let ran = await StatsManager.shared.refreshNow()
            guard !Task.isCancelled, let self else { return }
            syncedAtLeastOnce = syncedAtLeastOnce || ran
            load(animateHero: false)
        }
    }

    override func initialFocusIndexPath() -> IndexPath? {
        IndexPath(item: 0, section: 0)
    }

    private func load(animateHero: Bool) {
        guard let loader else {
            show(placeholder: .unavailable)
            return
        }
        let range = self.range
        loadSlot.run { [weak self] in
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
        hasLoadedOnce = true
        if !loaded.isEmpty, loaded == page, !isShowingState {
            return
        }
        page = loaded
        dataVersion += 1
        heroShouldAnimate = animateHero
        hostedViews.removeAll()
        guard !loaded.isEmpty else {
            dataSource.apply(NSDiffableDataSourceSnapshot<TVStatsSection, TVStatsItem>(), animatingDifferences: false)
            show(placeholder: StatsPlaceholder.forEmptyPage(syncedAtLeastOnce: syncedAtLeastOnce, librariesFiltered: LibraryVisibility.isCustomized))
            return
        }
        showContent()
        DemoTour.shared.record(.statistics)
        dataSource.apply(makeSnapshot(), animatingDifferences: false)
        controlsView.configure(range: range, since: loaded.hero.since, filter: StatsLibraryFilter.current())
        collectionView.collectionViewLayout.invalidateLayout()
    }

    private func loadFailed() {
        guard page.isEmpty else { return }
        show(state: .error(
            title: "Couldn\u{2019}t Load Statistics",
            message: "The local statistics store could not be read.",
            retryTitle: "Try Again"
        ) { [weak self] in
            self?.load(animateHero: true)
        })
    }

    private func librariesChanged() {
        controlsView.updateLibraries(StatsLibraryFilter.current())
        load(animateHero: false)
    }

    /// Statistics beyond the Week range are Crucible Pro: a free install opens on Week, with locks on the other chips and on the
    /// Libraries filter, until Pro is on.
    private func applyLocks() {
        let locks = ProAccess.shared.showsLocks
        controlsView.showsLocks = locks
        if TVStatsControlsView.isLocked(range, showsLocks: locks) {
            range = .week
        }
        controlsView.select(range: range)
    }

    private func proStatusChanged() {
        let previous = range
        applyLocks()
        if previous != range { load(animateHero: true) }
    }

    /// A press on a lock opens the paywall; once Pro is on, the range the user reached for opens.
    private func unlock(_ lock: TVStatsControlsView.StatsLock) {
        ProAccess.shared.requestUnlock(.fullStatistics) { [weak self] unlocked in
            guard unlocked, let self, case .range(let chosen) = lock else { return }
            controlsView.select(range: chosen)
            selectRange(chosen)
        }
    }

    private func selectRange(_ newRange: StatsRange) {
        guard newRange != range else { return }
        range = newRange
        load(animateHero: true)
    }

    private func show(placeholder: StatsPlaceholder) {
        switch placeholder {
        case .loading:
            show(state: .loading(title: placeholder.title))
        case .unavailable:
            show(state: .empty(title: placeholder.title, message: placeholder.message, symbol: placeholder.symbol ?? "exclamationmark.triangle", action: nil))
        case .empty(let filtered):
            show(state: .empty(
                title: placeholder.title,
                message: placeholder.message,
                symbol: placeholder.symbol ?? "chart.bar.xaxis",
                action: filtered ? includeAllLibrariesAction() : nil
            ))
        }
    }

    private func includeAllLibrariesAction() -> TVStateView.Action {
        TVStateView.Action(title: "Include All Libraries") {
            let filter = StatsLibraryFilter.current()
            filter.entries.filter { !$0.isIncluded }.forEach { filter.toggle($0) }
        }
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
            subtitle += " \u{00B7} \(Int((completion * 100).rounded()))%"
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
        let hostRegistration = TVHostCell.registration { [weak self] (item: TVStatsItem) -> UIView in
            self?.hostedView(for: item) ?? UIView()
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
        adopt(dataSource)
    }

    /// Building a chart is the expensive part of scrolling: each section's view is built once per page
    /// and handed to whichever cell shows it, so scrolling away and back neither rebuilds it nor
    /// replays its entrance animation.
    private func hostedView(for item: TVStatsItem) -> UIView? {
        if case .controls = item { return controlsView }
        if let cached = hostedViews[item] { return cached }
        guard let view = makeHostedView(for: item) else { return nil }
        hostedViews[item] = view
        return view
    }

    private func makeHostedView(for item: TVStatsItem) -> UIView? {
        switch item {
        case .controls, .poster:
            return nil
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
        }
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
        TVNavigation.push(TVScreens.detail(env, ratingKey: ratingKey, mediaType: mediaType), from: self)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard case .poster(_, _, let destination)? = dataSource.itemIdentifier(for: indexPath) else { return }
        push(destination)
    }

    private static func makeLayout(_ source: LayoutSource) -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [source] index, _ in
            guard let section = source.screen?.dataSource.snapshot().sectionIdentifiers[safe: index] else { return nil }
            return Self.layout(for: section)
        }
    }

    private static func layout(for section: TVStatsSection) -> NSCollectionLayoutSection {
        switch section {
        case .controls:
            return fullWidth(estimatedHeight: 130, insets: NSDirectionalEdgeInsets(top: TVMetrics.tabBarClearance, leading: 0, bottom: 36, trailing: 0))
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

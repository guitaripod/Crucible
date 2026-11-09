import CrucibleCore
import CrucibleDesign
import CrucibleStats
@preconcurrency import UIKit

final class StatisticsViewController: UICollectionViewController {
    enum StatSection: Hashable {
        case range, hero, kpis, heatmap, topShows, topMovies, clock, momentum
        case libraries, binges, genres, onThisDay, superlatives, share
    }

    enum Row: Hashable {
        case range(Int)
        case hero(Int)
        case kpi(StatsPage.Tile)
        case heatmap(Int)
        case clock(Int)
        case momentum(Int)
        case showsCard(Int)
        case moviePoster(StatsPoster)
        case libraries(Int)
        case binges(Int)
        case genresCard(Int)
        case onThisDayPoster(StatsPoster)
        case superlative(Superlative)
        case shareButton(Int)
    }

    let api: APIClient
    let loader: StatsPageLoader?
    let statsTime = StatsTime()

    var page = StatsPage.empty
    var range: StatsRange = .year
    var source: StatsSource = .plex
    var traktObservation: UUID?
    weak var sourceChips: StatsSourceChipsView?
    var dataVersion = 0
    private var syncedAtLeastOnce = false
    private var loadTask: Task<Void, Never>?
    var visibilityObserver: UUID?
    var proObservation: ProObservation?
    weak var rangeChips: StatsRangeChipsView?

    var dataSource: UICollectionViewDiffableDataSource<StatSection, Row>!

    static let sectionTitles: [StatSection: String] = [
        .topMovies: String(localized: "Top Movies"),
        .onThisDay: String(localized: "On This Day"),
        .superlatives: String(localized: "Wrapped Moments"),
    ]

    init(api: APIClient) {
        self.api = api
        self.loader = StatsManager.shared.pageLoader
        self.range = ProAccess.shared.hasFullAccess ? .year : .week
        self.source = StatsSourceChoice.initial()
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let visibilityObserver {
            Task { @MainActor in LibraryVisibility.removeObserver(visibilityObserver) }
        }
        if let traktObservation {
            Task { @MainActor in TraktAccount.shared.stopObserving(traktObservation) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Statistics", comment: "Navigation title of the Statistics screen")
        navigationItem.largeTitleDisplayMode = .always
        view.backgroundColor = Theme.Color.canvas
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.showsVerticalScrollIndicator = false
        collectionView.alwaysBounceVertical = true
        configureDataSource()
        collectionView.collectionViewLayout = createLayout()

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
        collectionView.refreshControl = refresh
        configureLibrariesItem()
        proObservation = ProObservation { [weak self] in self?.proChanged() }
        traktObservation = TraktAccount.shared.observe { [weak self] in self?.traktChanged() }
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        DemoTour.shared.record(.statistics)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
    }

    private func refresh() {
        Task { [weak self] in
            await StatsManager.shared.refreshNow()
            self?.syncedAtLeastOnce = true
            self?.load(animateHero: false)
            self?.collectionView.refreshControl?.endRefreshing()
        }
    }

    /// Switches range. Week is free; any other range sends a free install to the paywall and switches only if Pro comes on.
    func selectRange(_ newRange: StatsRange) {
        guard newRange != range else { return }
        guard newRange == .week || ProAccess.shared.hasFullAccess else {
            ProAccess.shared.requestUnlock(.fullStatistics) { [weak self] unlocked in
                guard unlocked else { return }
                self?.applyRange(newRange)
            }
            return
        }
        applyRange(newRange)
    }

    /// Switches between Plex's history and everything Trakt knows. Everything is part of Full Statistics, so a free install
    /// goes to the paywall first.
    func selectSource(_ newSource: StatsSource) {
        guard newSource != source else { return }
        guard newSource == .plex || ProAccess.shared.hasFullAccess else {
            ProAccess.shared.requestUnlock(.fullStatistics) { [weak self] unlocked in
                guard unlocked else { return }
                self?.applySource(newSource)
            }
            return
        }
        applySource(newSource)
    }

    private func applySource(_ newSource: StatsSource) {
        StatsSourceChoice.remember(newSource)
        show(newSource)
    }

    /// Shows `newSource` without remembering it: going back to Plex because Trakt or Pro went away keeps the viewer's choice
    /// for when they return.
    private func show(_ newSource: StatsSource) {
        guard newSource != source else { return }
        source = newSource
        sourceChips?.select(newSource)
        load(animateHero: true)
    }

    /// Trakt connecting adds the switch and brings back the source the viewer chose; disconnecting takes it away and goes back
    /// to Plex's history.
    private func traktChanged() {
        source = StatsSourceChoice.initial()
        reloadRangeRow()
        load(animateHero: false)
    }

    private func reloadRangeRow() {
        var snapshot = dataSource.snapshot()
        let rows = snapshot.itemIdentifiers.filter { if case .range = $0 { return true } else { return false } }
        guard !rows.isEmpty else { return }
        snapshot.reconfigureItems(rows)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func applyRange(_ newRange: StatsRange) {
        range = newRange
        rangeChips?.select(newRange)
        load(animateHero: true)
    }

    /// Pro turning on or off: the locks, the library filter and the share button follow, and a range that is no longer
    /// available falls back to the week.
    private func proChanged() {
        updateLibrariesMenu()
        rangeChips?.setLocked(lockedRanges)
        sourceChips?.setEverythingLocked(ProAccess.shared.showsLocks)
        reconfigureProRows()
        if !ProAccess.shared.hasFullAccess, range != .week { applyRange(.week) }
        show(StatsSourceChoice.initial())
    }

    var lockedRanges: Set<StatsRange> {
        ProAccess.shared.showsLocks ? [.month, .year, .allTime] : []
    }

    private func reconfigureProRows() {
        var snapshot = dataSource.snapshot()
        let rows = snapshot.itemIdentifiers.filter {
            switch $0 {
            case .shareButton: return true
            default: return false
            }
        }
        snapshot.reconfigureItems(rows)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func load(animateHero: Bool) {
        guard let loader else {
            show(.unavailable)
            return
        }
        loadTask?.cancel()
        let range = self.range
        let source = self.source
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await loader.load(range: range, source: source)
                guard !Task.isCancelled else { return }
                page = loaded
                dataVersion += 1
                applySnapshot(animateHero: animateHero)
                openPosterIfAsked()
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }

    // MARK: - Snapshot

    private func applySnapshot(animateHero: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<StatSection, Row>()
        guard !page.isEmpty else {
            dataSource.apply(snapshot, animatingDifferences: false)
            showEmptyOrLoading()
            return
        }
        contentUnavailableConfiguration = nil
        let v = dataVersion

        snapshot.appendSections([.range])
        snapshot.appendItems([.range(0)], toSection: .range)

        for section in page.sections {
            switch section {
            case .hero: append(.hero, [.hero(v)], to: &snapshot)
            case .kpis: append(.kpis, page.tiles.map { .kpi($0) }, to: &snapshot)
            case .heatmap: append(.heatmap, [.heatmap(v)], to: &snapshot)
            case .topShows: append(.topShows, [.showsCard(v)], to: &snapshot)
            case .topMovies: append(.topMovies, page.topMovies.map { .moviePoster($0) }, to: &snapshot)
            case .clock: append(.clock, [.clock(v)], to: &snapshot)
            case .momentum: append(.momentum, [.momentum(v)], to: &snapshot)
            case .binges: append(.binges, [.binges(v)], to: &snapshot)
            case .libraries: append(.libraries, [.libraries(v)], to: &snapshot)
            case .genres: append(.genres, [.genresCard(v)], to: &snapshot)
            case .onThisDay: append(.onThisDay, page.onThisDay.map { .onThisDayPoster($0) }, to: &snapshot)
            case .superlatives: append(.superlatives, page.superlatives.map { .superlative($0) }, to: &snapshot)
            }
        }

        snapshot.appendSections([.share])
        snapshot.appendItems([.shareButton(v)], toSection: .share)

        heroShouldAnimate = animateHero
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.collectionViewLayout.invalidateLayout()
    }

    private func append(_ section: StatSection, _ rows: [Row], to snapshot: inout NSDiffableDataSourceSnapshot<StatSection, Row>) {
        snapshot.appendSections([section])
        snapshot.appendItems(rows, toSection: section)
    }

    var heroShouldAnimate = true
    var opensPosterWhenLoaded = false

    private func showEmptyOrLoading() {
        show(StatsPlaceholder.forEmptyPage(syncedAtLeastOnce: syncedAtLeastOnce, librariesFiltered: LibraryVisibility.isCustomized))
    }

    private func show(_ placeholder: StatsPlaceholder) {
        var config = placeholder == .loading ? UIContentUnavailableConfiguration.loading() : UIContentUnavailableConfiguration.empty()
        config.image = placeholder.symbol.flatMap { UIImage(systemName: $0) }
        config.text = placeholder.title
        config.secondaryText = placeholder.message
        contentUnavailableConfiguration = config
    }
}

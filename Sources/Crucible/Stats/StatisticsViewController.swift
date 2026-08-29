@preconcurrency import UIKit

final class StatisticsViewController: UICollectionViewController {
    enum StatSection: Hashable {
        case hero, kpis, heatmap, clock, momentum, topShows, topMovies
        case libraries, binges, genres, onThisDay, superlatives, share
    }

    struct KPITile: Hashable {
        let key: String
        let title: String
        let value: String
        let systemImage: String
        let caption: String?
        let sparkline: [Int]
    }

    enum Row: Hashable {
        case hero(Int)
        case kpi(KPITile)
        case heatmap(Int)
        case clock(Int)
        case momentum(Int)
        case showRow(ShowStat)
        case moviePoster(MovieStat)
        case libraries(Int)
        case binges(Int)
        case genreRow(GenreStat)
        case genrePending(Int)
        case onThisDayPoster(OnThisDayItem)
        case superlative(Superlative)
        case shareButton(Int)
    }

    let api: APIClient
    let store: StatsStore?
    let statsTime = StatsTime()

    var current = StatsSnapshot()
    var heatmapModel = HeatmapModel()
    var range: StatsRange = .year
    var dataVersion = 0
    private var syncedAtLeastOnce = false
    private var loadTask: Task<Void, Never>?

    var dataSource: UICollectionViewDiffableDataSource<StatSection, Row>!

    static let sectionTitles: [StatSection: String] = [
        .kpis: "The Numbers",
        .heatmap: "Year in Orange",
        .clock: "When You Watch",
        .momentum: "Your Momentum",
        .topShows: "Top Shows",
        .topMovies: "Top Movies",
        .libraries: "Your Libraries",
        .binges: "Binges & Streaks",
        .genres: "Your Taste",
        .onThisDay: "On This Day",
        .superlatives: "Wrapped Moments",
    ]

    init(api: APIClient) {
        self.api = api
        self.store = StatsManager.shared.store
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Statistics"
        navigationItem.largeTitleDisplayMode = .never
        configureDataSource()
        collectionView.collectionViewLayout = createLayout()

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
        collectionView.refreshControl = refresh
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

    private func refresh() {
        Task { [weak self] in
            await StatsManager.shared.refreshNow()
            self?.syncedAtLeastOnce = true
            self?.load(animateHero: false)
            self?.collectionView.refreshControl?.endRefreshing()
        }
    }

    func selectRange(_ newRange: StatsRange) {
        guard newRange != range else { return }
        range = newRange
        load(animateHero: true)
    }

    private func load(animateHero: Bool) {
        guard let store else {
            showUnavailable()
            return
        }
        loadTask?.cancel()
        let range = self.range
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snap = try await store.snapshot(range: range)
                guard !Task.isCancelled else { return }
                let heat = statsTime.heatmapModel(days: snap.heatmap, today: statsTime.todayDayEpoch())
                current = snap
                heatmapModel = heat
                dataVersion += 1
                applySnapshot(animateHero: animateHero)
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }

    // MARK: - Snapshot

    private func applySnapshot(animateHero: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<StatSection, Row>()
        guard !current.isEmpty else {
            dataSource.apply(snapshot, animatingDifferences: false)
            showEmptyOrLoading()
            return
        }
        contentUnavailableConfiguration = nil
        let v = dataVersion

        snapshot.appendSections([.hero])
        snapshot.appendItems([.hero(v)], toSection: .hero)

        let tiles = buildTiles()
        if !tiles.isEmpty {
            snapshot.appendSections([.kpis])
            snapshot.appendItems(tiles.map { .kpi($0) }, toSection: .kpis)
        }

        if !heatmapModel.cells.isEmpty {
            snapshot.appendSections([.heatmap])
            snapshot.appendItems([.heatmap(v)], toSection: .heatmap)
        }

        snapshot.appendSections([.clock])
        snapshot.appendItems([.clock(v)], toSection: .clock)

        if current.monthly.count >= 2 {
            snapshot.appendSections([.momentum])
            snapshot.appendItems([.momentum(v)], toSection: .momentum)
        }

        if !current.topShows.isEmpty {
            snapshot.appendSections([.topShows])
            snapshot.appendItems(current.topShows.map { .showRow($0) }, toSection: .topShows)
        }

        if !current.topMovies.isEmpty {
            snapshot.appendSections([.topMovies])
            snapshot.appendItems(current.topMovies.map { .moviePoster($0) }, toSection: .topMovies)
        }

        if current.libraries.count >= 2 {
            snapshot.appendSections([.libraries])
            snapshot.appendItems([.libraries(v)], toSection: .libraries)
        }

        if !current.binges.isEmpty {
            snapshot.appendSections([.binges])
            snapshot.appendItems([.binges(v)], toSection: .binges)
        }

        if !current.genres.isEmpty {
            snapshot.appendSections([.genres])
            snapshot.appendItems(current.genres.map { .genreRow($0) }, toSection: .genres)
        } else if current.enrichment.genreCoverage < 0.5 {
            snapshot.appendSections([.genres])
            snapshot.appendItems([.genrePending(v)], toSection: .genres)
        }

        if !current.onThisDay.isEmpty {
            snapshot.appendSections([.onThisDay])
            snapshot.appendItems(current.onThisDay.map { .onThisDayPoster($0) }, toSection: .onThisDay)
        }

        if !current.superlatives.isEmpty {
            snapshot.appendSections([.superlatives])
            snapshot.appendItems(current.superlatives.map { .superlative($0) }, toSection: .superlatives)
        }

        snapshot.appendSections([.share])
        snapshot.appendItems([.shareButton(v)], toSection: .share)

        heroShouldAnimate = animateHero
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    var heroShouldAnimate = true

    private func buildTiles() -> [KPITile] {
        let o = current.overview
        var tiles: [KPITile] = [
            KPITile(key: "days", title: "Days Active", value: "\(o.daysActive)", systemImage: "calendar", caption: nil, sparkline: current.weeklySparkline),
            KPITile(key: "streak", title: "Current Streak", value: "\(o.currentStreak)", systemImage: "flame.fill", caption: o.longestStreak > o.currentStreak ? "best \(o.longestStreak)" : nil, sparkline: []),
            KPITile(key: "shows", title: "Shows", value: StatsStyle.abbreviatedCount(o.showsWatched), systemImage: "tv", caption: nil, sparkline: []),
            KPITile(key: "movies", title: "Movies", value: StatsStyle.abbreviatedCount(o.moviesWatched), systemImage: "film", caption: nil, sparkline: []),
            KPITile(key: "episodes", title: "Episodes", value: StatsStyle.abbreviatedCount(o.episodes), systemImage: "play.tv", caption: nil, sparkline: []),
        ]
        if let hours = o.estHours {
            let pct = Int((o.coverage * 100).rounded())
            tiles.append(KPITile(key: "hours", title: "Hours Watched", value: StatsStyle.hoursLabel(hours), systemImage: "clock", caption: "est · \(pct)% counted", sparkline: []))
        }
        return tiles
    }

    private func showEmptyOrLoading() {
        if syncedAtLeastOnce {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "chart.bar.xaxis")
            config.text = "No watch history yet"
            config.secondaryText = "Play something and your stats will appear here."
            contentUnavailableConfiguration = config
        } else {
            var config = UIContentUnavailableConfiguration.loading()
            config.text = "Building your statistics"
            config.secondaryText = "Mirroring your Plex watch history…"
            contentUnavailableConfiguration = config
        }
    }

    private func showUnavailable() {
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "exclamationmark.triangle")
        config.text = "Statistics unavailable"
        config.secondaryText = "The local statistics store could not be opened."
        contentUnavailableConfiguration = config
    }

    func subtitleText() -> String {
        guard let since = current.overview.memberSinceViewedAt else { return "Your viewing, visualized" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return "Watching since \(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(since))))"
    }

    func watchVerdict() -> String {
        let hours = current.hourHistogram
        let total = hours.reduce(0, +)
        guard total > 0 else { return "" }
        let lateNight = hours[0...4].reduce(0, +) + hours[22...23].reduce(0, +)
        let morning = hours[5...10].reduce(0, +)
        let wd = current.weekdayHistogram
        let weekend = wd[0] + wd[6]
        let weekdayTotal = max(1, wd.reduce(0, +))
        if Double(lateNight) / Double(total) > 0.33 { return "You're a Night Owl" }
        if Double(morning) / Double(total) > 0.33 { return "You're an Early Bird" }
        if Double(weekend) / Double(weekdayTotal) > 0.45 { return "You're a Weekend Warrior" }
        return "You're a Prime-Time Viewer"
    }
}

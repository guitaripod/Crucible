@preconcurrency import UIKit

final class StatisticsViewController: UICollectionViewController {
    enum StatSection: Hashable {
        case range, hero, kpis, heatmap, topShows, topMovies, clock, momentum
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
        case range(Int)
        case hero(Int)
        case kpi(KPITile)
        case heatmap(Int)
        case clock(Int)
        case momentum(Int)
        case showsCard(Int)
        case moviePoster(MovieStat)
        case libraries(Int)
        case binges(Int)
        case genresCard(Int)
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
    var visibilityObserver: UUID?

    var dataSource: UICollectionViewDiffableDataSource<StatSection, Row>!

    static let sectionTitles: [StatSection: String] = [
        .topMovies: "Top Movies",
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

    deinit {
        if let visibilityObserver {
            Task { @MainActor in LibraryVisibility.removeObserver(visibilityObserver) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Statistics"
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

    func load(animateHero: Bool) {
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

        snapshot.appendSections([.range])
        snapshot.appendItems([.range(0)], toSection: .range)

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

        if !current.topShows.isEmpty {
            snapshot.appendSections([.topShows])
            snapshot.appendItems([.showsCard(v)], toSection: .topShows)
        }

        if !current.topMovies.isEmpty {
            snapshot.appendSections([.topMovies])
            snapshot.appendItems(current.topMovies.map { .moviePoster($0) }, toSection: .topMovies)
        }

        snapshot.appendSections([.clock])
        snapshot.appendItems([.clock(v)], toSection: .clock)

        if current.monthly.count >= 2 {
            snapshot.appendSections([.momentum])
            snapshot.appendItems([.momentum(v)], toSection: .momentum)
        }

        if !current.binges.isEmpty {
            snapshot.appendSections([.binges])
            snapshot.appendItems([.binges(v)], toSection: .binges)
        }

        if current.libraries.count >= 2 {
            snapshot.appendSections([.libraries])
            snapshot.appendItems([.libraries(v)], toSection: .libraries)
        }

        if !current.genres.isEmpty || current.enrichment.genreCoverage < 0.5 {
            snapshot.appendSections([.genres])
            snapshot.appendItems([.genresCard(v)], toSection: .genres)
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
        collectionView.collectionViewLayout.invalidateLayout()
    }

    var heroShouldAnimate = true

    private func buildTiles() -> [KPITile] {
        let o = current.overview
        let streakCaption = o.longestStreak > o.currentStreak ? "days · best \(o.longestStreak)" : "days"
        var tiles: [KPITile] = [
            KPITile(key: "days", title: "Days Active", value: "\(o.daysActive)", systemImage: "calendar", caption: nil, sparkline: current.weeklySparkline),
            KPITile(key: "streak", title: "Streak", value: "\(o.currentStreak)", systemImage: "flame", caption: streakCaption, sparkline: []),
            KPITile(key: "shows", title: "Shows", value: StatsStyle.abbreviatedCount(o.showsWatched), systemImage: "tv", caption: nil, sparkline: []),
            KPITile(key: "movies", title: "Movies", value: StatsStyle.abbreviatedCount(o.moviesWatched), systemImage: "film", caption: nil, sparkline: []),
            KPITile(key: "episodes", title: "Episodes", value: StatsStyle.abbreviatedCount(o.episodes), systemImage: "play", caption: nil, sparkline: []),
        ]
        if let binge = longestBinge() {
            tiles.append(KPITile(key: "binge", title: "Longest Binge", value: binge.value, systemImage: "clock", caption: binge.date, sparkline: []))
        }
        return tiles
    }

    /// The longest session by wall-clock span, formatted as "9 h" / "45 min" plus its start date.
    func longestBinge() -> (value: String, date: String)? {
        guard let session = current.binges.max(by: { $0.endViewedAt - $0.startViewedAt < $1.endViewedAt - $1.startViewedAt }) else { return nil }
        let seconds = session.endViewedAt - session.startViewedAt
        guard seconds >= 60 else { return nil }
        let value = seconds >= 3600 ? "\(Int((Double(seconds) / 3600).rounded())) h" : "\(seconds / 60) min"
        let date = Date(timeIntervalSince1970: TimeInterval(session.startViewedAt)).formatted(.dateTime.month(.abbreviated).day())
        return (value, date)
    }

    /// Hero copy: the verdict as eyebrow, estimated hours (or plays while runtimes are unknown) as the big number.
    func heroContent() -> (eyebrow: String, value: Int, unit: String, detail: String) {
        let o = current.overview
        let eyebrow = watchVerdict().isEmpty ? "Your viewing" : watchVerdict()
        let phrase = rangePhrase()
        guard let hours = o.estHours, hours >= 0.5 else {
            return (eyebrow, o.totalPlays, o.totalPlays == 1 ? "play" : "plays", "watched \(phrase)")
        }
        let value = Int(hours.rounded())
        let pct = Int((o.coverage * 100).rounded())
        return (eyebrow, value, value == 1 ? "hour" : "hours", "watched \(phrase) · estimate, \(pct)% counted")
    }

    private func rangePhrase() -> String {
        switch range {
        case .week: return "in the last 7 days"
        case .month: return "in the last 30 days"
        case .year: return "in \(statsTime.calendar.component(.year, from: Date()))"
        case .allTime: return "in total"
        }
    }

    private func showEmptyOrLoading() {
        if syncedAtLeastOnce {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "chart.bar.xaxis")
            if LibraryVisibility.isCustomized {
                config.text = "No plays in these libraries"
                config.secondaryText = "Switch on more libraries with the filter button."
            } else {
                config.text = "No watch history yet"
                config.secondaryText = "Play something and your stats will appear here."
            }
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

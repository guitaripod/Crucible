@preconcurrency import UIKit

extension StatisticsViewController {
    func createLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self, let section = dataSource.snapshot().sectionIdentifiers[safe: index] else { return nil }
            return layoutSection(section, environment: environment)
        }
    }

    private func headerItem() -> NSCollectionLayoutBoundarySupplementaryItem {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44))
        return NSCollectionLayoutBoundarySupplementaryItem(layoutSize: size, elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
    }

    private func fullWidth(height: CGFloat, horizontalInset: CGFloat = 16, header: Bool) -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)), subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = .init(top: 4, leading: horizontalInset, bottom: 14, trailing: horizontalInset)
        if header { section.boundarySupplementaryItems = [headerItem()] }
        return section
    }

    private func rowList(height: CGFloat) -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)), subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 4
        section.contentInsets = .init(top: 4, leading: 16, bottom: 14, trailing: 16)
        section.boundarySupplementaryItems = [headerItem()]
        return section
    }

    private func posterRail() -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(140), heightDimension: .absolute(210)))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .absolute(140), heightDimension: .absolute(210)), subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
        section.interGroupSpacing = 12
        section.contentInsets = .init(top: 4, leading: 16, bottom: 14, trailing: 16)
        section.boundarySupplementaryItems = [headerItem()]
        return section
    }

    private func layoutSection(_ section: StatSection, environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        switch section {
        case .hero:
            return fullWidth(height: 210, horizontalInset: 0, header: false)
        case .kpis:
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(96)), repeatingSubitem: item, count: 2)
            group.interItemSpacing = .fixed(10)
            let s = NSCollectionLayoutSection(group: group)
            s.interGroupSpacing = 10
            s.contentInsets = .init(top: 4, leading: 16, bottom: 14, trailing: 16)
            s.boundarySupplementaryItems = [headerItem()]
            return s
        case .heatmap:
            return fullWidth(height: 140, header: true)
        case .clock:
            return fullWidth(height: 224, header: true)
        case .momentum:
            return fullWidth(height: 184, header: true)
        case .topShows:
            return rowList(height: 76)
        case .topMovies, .onThisDay:
            return posterRail()
        case .libraries:
            return fullWidth(height: 200, header: true)
        case .binges:
            return fullWidth(height: 140, horizontalInset: 4, header: true)
        case .genres:
            return rowList(height: 56)
        case .superlatives:
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(0.82), heightDimension: .absolute(150)), subitems: [item])
            let s = NSCollectionLayoutSection(group: group)
            s.orthogonalScrollingBehavior = .groupPagingCentered
            s.interGroupSpacing = 12
            s.contentInsets = .init(top: 4, leading: 16, bottom: 14, trailing: 16)
            s.boundarySupplementaryItems = [headerItem()]
            return s
        case .share:
            return fullWidth(height: 72, header: false)
        }
    }
}

extension StatisticsViewController {
    func configureDataSource() {
        let heroReg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            let hero = StatsHeroView()
            hero.onRange = { [weak self] newRange in self?.selectRange(newRange) }
            hero.configure(totalPlays: current.overview.totalPlays, subtitle: subtitleText(), range: range, animate: heroShouldAnimate)
            host(hero, in: cell)
        }

        let kpiReg = UICollectionView.CellRegistration<UICollectionViewCell, KPITile> { cell, _, tile in
            let tileView = StatTileView()
            tileView.configure(.init(title: tile.title, value: tile.value, systemImage: tile.systemImage, caption: tile.caption))
            tileView.setSparkline(tile.sparkline)
            Self.host(tileView, in: cell)
        }

        let heatmapReg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            let heatmap = ContributionHeatmapView()
            heatmap.setModel(heatmapModel)
            heatmap.onSelectDay = { [weak self] dayEpoch in self?.pushDayDetail(dayEpoch: dayEpoch) }
            host(heatmap, in: cell)
        }

        let clockReg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            host(makeClockView(), in: cell)
        }

        let momentumReg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            let trend = TrendAreaView()
            trend.showsAxes = true
            if let peak = current.monthly.max(by: { $0.count < $1.count }) {
                let (year, month) = StatsTime.monthEpochToYearMonth(peak.monthEpoch)
                trend.peakAnnotation = "\(StatsStyle.monthSymbols[max(0, min(11, month - 1))]) \(year)"
            }
            trend.setValues(current.monthly.map { Double($0.count) }, animated: true)
            host(trend, in: cell)
        }

        let showReg = UICollectionView.CellRegistration<UICollectionViewCell, ShowStat> { [weak self] cell, _, show in
            guard let self else { return }
            let row = RankedRowView()
            let maxCount = current.topShows.first?.count ?? 1
            let index = current.topShows.firstIndex(of: show) ?? 0
            var accessory: UIView?
            if let completion = show.completion {
                let ring = CompletionRingView()
                ring.setProgress(completion, animated: true)
                accessory = ring
            }
            let episodes = show.watchedEpisodes ?? show.count
            row.configure(title: show.title, valueText: episodes == 1 ? "1 ep" : "\(episodes) eps", fraction: Double(show.count) / Double(max(1, maxCount)), colorIndex: index, thumbPath: show.thumb, accessory: accessory)
            host(row, in: cell, insets: .init(top: 8, leading: 0, bottom: 8, trailing: 0))
        }

        let movieReg = UICollectionView.CellRegistration<UICollectionViewCell, MovieStat> { cell, _, movie in
            var config = PosterContentConfiguration()
            config.posterPath = movie.thumb
            config.title = movie.title
            config.placeholderIcon = "film"
            if movie.count > 1 { config.subtitle = "\(movie.count)× watched" }
            cell.contentConfiguration = config
        }

        let librariesReg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            host(makeLibrariesView(), in: cell)
        }

        let bingesReg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            let timeline = BingeTimelineView()
            timeline.setSessions(current.binges)
            host(timeline, in: cell)
        }

        let genreReg = UICollectionView.CellRegistration<UICollectionViewCell, GenreStat> { [weak self] cell, _, genre in
            guard let self else { return }
            let row = RankedRowView()
            let maxCount = current.genres.first?.count ?? 1
            let index = current.genres.firstIndex(of: genre) ?? 0
            row.configure(title: genre.genre, valueText: "\(genre.count)", fraction: Double(genre.count) / Double(max(1, maxCount)), colorIndex: index, thumbPath: nil)
            Self.host(row, in: cell)
        }

        let genrePendingReg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            Self.host(makePendingView(progress: current.enrichment.genreCoverage), in: cell)
        }

        let onThisDayReg = UICollectionView.CellRegistration<UICollectionViewCell, OnThisDayItem> { cell, _, item in
            var config = PosterContentConfiguration()
            config.posterPath = item.thumb ?? item.grandparentThumb
            config.title = item.grandparentTitle ?? item.title
            config.subtitle = item.yearsAgo == 1 ? "1 year ago" : "\(item.yearsAgo) years ago"
            config.placeholderIcon = item.type == "episode" ? "tv" : "film"
            cell.contentConfiguration = config
        }

        let superlativeReg = UICollectionView.CellRegistration<UICollectionViewCell, Superlative> { cell, _, superlative in
            let card = SuperlativeCardView()
            card.configure(superlative)
            Self.host(card, in: cell)
        }

        let shareReg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            host(makeShareButton(), in: cell, insets: .init(top: 4, leading: 0, bottom: 8, trailing: 0))
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, row in
            switch row {
            case .hero(let v): return collectionView.dequeueConfiguredReusableCell(using: heroReg, for: indexPath, item: v)
            case .kpi(let tile): return collectionView.dequeueConfiguredReusableCell(using: kpiReg, for: indexPath, item: tile)
            case .heatmap(let v): return collectionView.dequeueConfiguredReusableCell(using: heatmapReg, for: indexPath, item: v)
            case .clock(let v): return collectionView.dequeueConfiguredReusableCell(using: clockReg, for: indexPath, item: v)
            case .momentum(let v): return collectionView.dequeueConfiguredReusableCell(using: momentumReg, for: indexPath, item: v)
            case .showRow(let show): return collectionView.dequeueConfiguredReusableCell(using: showReg, for: indexPath, item: show)
            case .moviePoster(let movie): return collectionView.dequeueConfiguredReusableCell(using: movieReg, for: indexPath, item: movie)
            case .libraries(let v): return collectionView.dequeueConfiguredReusableCell(using: librariesReg, for: indexPath, item: v)
            case .binges(let v): return collectionView.dequeueConfiguredReusableCell(using: bingesReg, for: indexPath, item: v)
            case .genreRow(let genre): return collectionView.dequeueConfiguredReusableCell(using: genreReg, for: indexPath, item: genre)
            case .genrePending(let v): return collectionView.dequeueConfiguredReusableCell(using: genrePendingReg, for: indexPath, item: v)
            case .onThisDayPoster(let item): return collectionView.dequeueConfiguredReusableCell(using: onThisDayReg, for: indexPath, item: item)
            case .superlative(let s): return collectionView.dequeueConfiguredReusableCell(using: superlativeReg, for: indexPath, item: s)
            case .shareButton(let v): return collectionView.dequeueConfiguredReusableCell(using: shareReg, for: indexPath, item: v)
            }
        }

        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, indexPath in
            guard let section = self?.dataSource.snapshot().sectionIdentifiers[safe: indexPath.section],
                  let title = Self.titleFor(section) else { return }
            var config = SectionHeaderConfiguration()
            config.title = title
            cell.contentConfiguration = config
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    // MARK: - Composite subviews

    private func makeClockView() -> UIView {
        let clock = RadialClockView()
        clock.setHours(current.hourHistogram)
        clock.setContentHuggingPriority(.required, for: .horizontal)
        let clockWidth = clock.widthAnchor.constraint(equalToConstant: 150)
        clockWidth.priority = .required
        clockWidth.isActive = true

        let weekday = WeekdayColumnChartView()
        weekday.setValues(current.weekdayHistogram)

        let charts = UIStackView(arrangedSubviews: [clock, weekday])
        charts.axis = .horizontal
        charts.spacing = 12
        charts.alignment = .fill

        let verdict = UILabel()
        verdict.text = watchVerdict()
        verdict.font = .systemFont(ofSize: 14, weight: .semibold)
        verdict.textColor = StatsStyle.accent
        verdict.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [charts, verdict])
        stack.axis = .vertical
        stack.spacing = 6
        return stack
    }

    private func makeLibrariesView() -> UIView {
        let donut = DonutChartView()
        let segments = current.libraries.enumerated().map { DonutSegment(label: $0.element.title, value: $0.element.count, colorIndex: $0.offset) }
        donut.setSegments(segments)
        let total = current.libraries.reduce(0) { $0 + $1.count }
        donut.setCenter(title: StatsStyle.abbreviatedCount(total), subtitle: "plays")
        donut.setContentHuggingPriority(.required, for: .horizontal)
        donut.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let legend = UIStackView()
        legend.axis = .vertical
        legend.spacing = 8
        legend.alignment = .fill
        for (index, slice) in current.libraries.prefix(6).enumerated() {
            legend.addArrangedSubview(makeLegendRow(color: StatsStyle.categoricalColor(index), title: slice.title, value: StatsStyle.abbreviatedCount(slice.count)))
        }
        let legendWrap = UIStackView(arrangedSubviews: [UIView(), legend, UIView()])
        legendWrap.axis = .vertical
        legendWrap.distribution = .equalCentering

        let stack = UIStackView(arrangedSubviews: [donut, legendWrap])
        stack.axis = .horizontal
        stack.spacing = 16
        stack.alignment = .fill
        return stack
    }

    private func makeLegendRow(color: UIColor, title: String, value: String) -> UIView {
        let dot = UIView()
        dot.backgroundColor = color
        dot.layer.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1

        let valueLabel = UILabel()
        valueLabel.text = value
        valueLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        valueLabel.textColor = .secondaryLabel
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [dot, titleLabel, valueLabel])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        return row
    }

    private func makePendingView(progress: Double) -> UIView {
        let label = UILabel()
        label.text = "Analyzing your taste…"
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabel

        let bar = UIProgressView(progressViewStyle: .default)
        bar.progressTintColor = StatsStyle.accent
        bar.trackTintColor = UIColor.label.withAlphaComponent(0.1)
        bar.progress = Float(max(0.02, min(1, progress)))

        let stack = UIStackView(arrangedSubviews: [label, bar])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill
        let wrap = UIStackView(arrangedSubviews: [UIView(), stack, UIView()])
        wrap.axis = .vertical
        wrap.distribution = .equalCentering
        return wrap
    }

    private func makeShareButton() -> UIButton {
        var config = Glass.prominentButton {
            var fallback = UIButton.Configuration.filled()
            fallback.baseBackgroundColor = StatsStyle.accent
            fallback.baseForegroundColor = .white
            return fallback
        }
        config.title = "Share Your Year"
        config.image = UIImage(systemName: "square.and.arrow.up")
        config.imagePadding = 8
        config.cornerStyle = .large
        let button = UIButton(configuration: config)
        button.addAction(UIAction { [weak self] _ in self?.shareWrapped() }, for: .touchUpInside)
        return button
    }

    // MARK: - Hosting helpers

    private func host(_ view: UIView, in cell: UICollectionViewCell, insets: NSDirectionalEdgeInsets = .zero) {
        Self.host(view, in: cell, insets: insets)
    }

    static func host(_ view: UIView, in cell: UICollectionViewCell, insets: NSDirectionalEdgeInsets = .zero) {
        cell.contentView.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: insets.top),
            view.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: insets.leading),
            view.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -insets.trailing),
            view.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -insets.bottom),
        ])
    }

    // MARK: - Selection

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        switch row {
        case .showRow(let show):
            navigationController?.pushViewController(ShowDetailViewController(api: api, showRatingKey: show.ratingKey), animated: true)
        case .moviePoster(let movie):
            navigationController?.pushViewController(MediaDetailViewController(api: api, ratingKey: movie.ratingKey, mediaType: "movie"), animated: true)
        case .onThisDayPoster(let item):
            openOnThisDay(item)
        default:
            break
        }
    }

    private func openOnThisDay(_ item: OnThisDayItem) {
        switch item.type {
        case "episode":
            navigationController?.pushViewController(
                MediaDetailViewController(api: api, ratingKey: item.ratingKey, mediaType: "episode", showRatingKey: item.grandparentRatingKey),
                animated: true
            )
        case "show":
            navigationController?.pushViewController(ShowDetailViewController(api: api, showRatingKey: item.ratingKey), animated: true)
        default:
            navigationController?.pushViewController(MediaDetailViewController(api: api, ratingKey: item.ratingKey, mediaType: "movie"), animated: true)
        }
    }

    func pushDayDetail(dayEpoch: Int) {
        guard let store else { return }
        let date = statsTime.date(forDayEpoch: dayEpoch)
        navigationController?.pushViewController(StatsDayViewController(api: api, store: store, dayEpoch: dayEpoch, date: date), animated: true)
    }

    // MARK: - Share

    private func shareWrapped() {
        guard !current.isEmpty else { return }
        let snapshot = current
        let heatmap = heatmapModel
        let subtitle = subtitleText()
        Task { [weak self] in
            guard let self else { return }
            var posters = [UIImage]()
            let paths = snapshot.topShows.compactMap(\.thumb) + snapshot.topMovies.compactMap(\.thumb)
            for path in paths.prefix(3) {
                if let image = await ImageLoader.shared.loadImage(path: path, width: 300) {
                    posters.append(image)
                }
            }
            let input = WrappedShareCardRenderer.Input(
                title: "My Year in Crucible",
                subtitle: subtitle,
                overview: snapshot.overview,
                heatmap: heatmap.cells.isEmpty ? nil : heatmap,
                posters: posters
            )
            let image = WrappedShareCardRenderer().render(input)
            let activity = UIActivityViewController(activityItems: [image], applicationActivities: nil)
            if let popover = activity.popoverPresentationController {
                popover.sourceView = view
                popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 60, width: 0, height: 0)
            }
            present(activity, animated: true)
        }
    }

    static func titleFor(_ section: StatSection) -> String? {
        sectionTitles[section]
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private final class StatsHeroView: UIView {
    private let gradient = CAGradientLayer()
    private let captionLabel = UILabel()
    private let odometer = CountUpOdometerView()
    private let subtitleLabel = UILabel()
    private let segmented = UISegmentedControl(items: StatsRange.allCases.map(\.title))

    var onRange: ((StatsRange) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        gradient.colors = [StatsStyle.accent.withAlphaComponent(0.28).cgColor, UIColor.clear.cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(gradient)

        captionLabel.text = "TOTAL PLAYS"
        captionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        captionLabel.textColor = .secondaryLabel
        captionLabel.textAlignment = .center

        odometer.textColor = .label

        subtitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        subtitleLabel.textColor = .tertiaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 1

        segmented.selectedSegmentTintColor = StatsStyle.accent
        segmented.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        segmented.addAction(UIAction { [weak self] _ in
            guard let self, let selected = StatsRange(rawValue: segmented.selectedSegmentIndex) else { return }
            onRange?(selected)
        }, for: .valueChanged)

        let stack = UIStackView(arrangedSubviews: [captionLabel, odometer, subtitleLabel, segmented])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.setCustomSpacing(14, after: subtitleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            segmented.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }

    func configure(totalPlays: Int, subtitle: String, range: StatsRange, animate: Bool) {
        odometer.setValue(totalPlays, animated: animate)
        subtitleLabel.text = subtitle
        segmented.selectedSegmentIndex = range.rawValue
    }
}

import CrucibleCore
import CrucibleDesign
import CrucibleStats
import CrucibleStatsUI
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

    private func posterRail(_ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let width = Theme.Room(environment).posterRailWidth
        let height = width * Theme.Size.posterAspect + Theme.Size.captionBlockHeight
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(width), heightDimension: .estimated(height)))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .absolute(width), heightDimension: .estimated(height)), subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
        section.interGroupSpacing = 12
        section.contentInsets = Self.insets(environment, top: 4, bottom: 14)
        section.boundarySupplementaryItems = [headerItem()]
        return section
    }

    private func cardSection(_ environment: NSCollectionLayoutEnvironment, estimatedHeight: CGFloat = 160, top: CGFloat = 0, bottom: CGFloat = 14) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(estimatedHeight))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = Self.insets(environment, top: top, bottom: bottom)
        return section
    }

    /// The dashboard's column: 16 points from the edges on a phone, centred and at most `dashboardWidth` wide on a large screen so the
    /// charts keep their proportions.
    private static func insets(_ environment: NSCollectionLayoutEnvironment, top: CGFloat, bottom: CGFloat) -> NSDirectionalEdgeInsets {
        let room = Theme.Room(environment)
        guard room != .compact else { return .init(top: top, leading: 16, bottom: bottom, trailing: 16) }
        let width = environment.container.effectiveContentSize.width
        let side = max(room.gutter, (width - dashboardWidth) / 2)
        return .init(top: top, leading: side, bottom: bottom, trailing: side)
    }

    private static let dashboardWidth: CGFloat = 960

    private func layoutSection(_ section: StatSection, environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let room = Theme.Room(environment)
        switch section {
        case .range:
            return cardSection(environment, estimatedHeight: 44, top: 4, bottom: 12)
        case .hero:
            return cardSection(environment, estimatedHeight: 188, bottom: 10)
        case .kpis:
            let columns = room == .compact ? 2 : 4
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1 / CGFloat(columns)), heightDimension: .estimated(96))
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(96)), repeatingSubitem: item, count: columns)
            group.interItemSpacing = .fixed(10)
            let s = NSCollectionLayoutSection(group: group)
            s.interGroupSpacing = 10
            s.contentInsets = Self.insets(environment, top: 0, bottom: 14)
            return s
        case .heatmap, .topShows, .clock, .momentum, .libraries, .binges, .genres:
            return cardSection(environment)
        case .topMovies, .onThisDay:
            return posterRail(environment)
        case .superlatives:
            let width: NSCollectionLayoutDimension = room == .compact ? .fractionalWidth(0.82) : .absolute(380)
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: width, heightDimension: .absolute(150)), subitems: [item])
            let s = NSCollectionLayoutSection(group: group)
            s.orthogonalScrollingBehavior = room == .compact ? .groupPagingCentered : .continuousGroupLeadingBoundary
            s.interGroupSpacing = 12
            s.contentInsets = Self.insets(environment, top: 4, bottom: 14)
            s.boundarySupplementaryItems = [headerItem()]
            return s
        case .share:
            return cardSection(environment, estimatedHeight: Theme.Size.primaryButtonHeight, top: 2, bottom: 28)
        }
    }
}

extension StatisticsViewController {
    func configureDataSource() {
        let rangeReg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            let chips = StatsRangeChipsView()
            chips.select(range)
            chips.setLocked(lockedRanges)
            chips.onRange = { [weak self] newRange in self?.selectRange(newRange) }
            rangeChips = chips
            host(chips, in: cell)
        }

        let heroReg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            let hero = StatsHeroView()
            let content = page.hero
            hero.configure(eyebrow: content.eyebrow, value: content.value, unit: content.unit, detail: content.detail, since: content.since, animate: heroShouldAnimate)
            host(hero, in: cell)
        }

        let kpiReg = UICollectionView.CellRegistration<UICollectionViewCell, StatsPage.Tile> { cell, _, tile in
            let tileView = StatTileView()
            tileView.configure(.init(title: tile.title, value: tile.value, systemImage: tile.systemImage, caption: tile.caption))
            tileView.setSparkline(tile.sparkline)
            Self.host(tileView, in: cell)
        }

        let heatmapReg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            let heatmap = ContributionHeatmapView()
            heatmap.setModel(page.heatmap)
            heatmap.onSelectDay = { [weak self] dayEpoch in self?.pushDayDetail(dayEpoch: dayEpoch) }
            host(StatsCardView(title: "Activity", accessory: StatsHeatLegendView(), content: heatmap), in: cell)
        }

        let showsReg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            host(StatsCardView(title: "Top Shows", content: makeTopShowsView()), in: cell)
        }

        let clockReg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            host(StatsCardView(title: "When You Watch", content: makeClockView()), in: cell)
        }

        let momentumReg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self, let momentum = page.momentum else { return }
            let trend = TrendAreaView()
            trend.showsAxes = true
            trend.peakAnnotation = momentum.peakText
            trend.setValues(momentum.values, animated: true)
            trend.isAccessibilityElement = true
            trend.accessibilityTraits = .image
            trend.accessibilityLabel = momentum.summary
            host(StatsCardView(title: "Your Momentum", content: trend), in: cell)
        }

        let movieReg = UICollectionView.CellRegistration<UICollectionViewCell, StatsPoster> { cell, _, poster in
            cell.contentConfiguration = Self.posterConfiguration(poster)
        }

        let librariesReg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            host(StatsCardView(title: "Your Libraries", content: makeLibrariesView()), in: cell)
        }

        let bingesReg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            let timeline = BingeTimelineView()
            timeline.setSessions(page.binges)
            host(StatsCardView(title: "Binges & Streaks", content: timeline), in: cell)
        }

        let genresReg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            host(StatsCardView(title: "Your Taste", content: makeGenresView()), in: cell)
        }

        let onThisDayReg = UICollectionView.CellRegistration<UICollectionViewCell, StatsPoster> { cell, _, poster in
            cell.contentConfiguration = Self.posterConfiguration(poster)
        }

        let superlativeReg = UICollectionView.CellRegistration<UICollectionViewCell, Superlative> { cell, _, superlative in
            let card = SuperlativeCardView()
            card.configure(superlative)
            Self.host(card, in: cell)
        }

        let shareReg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            host(makeShareButton(), in: cell)
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, row in
            switch row {
            case .range(let v): return collectionView.dequeueConfiguredReusableCell(using: rangeReg, for: indexPath, item: v)
            case .hero(let v): return collectionView.dequeueConfiguredReusableCell(using: heroReg, for: indexPath, item: v)
            case .kpi(let tile): return collectionView.dequeueConfiguredReusableCell(using: kpiReg, for: indexPath, item: tile)
            case .heatmap(let v): return collectionView.dequeueConfiguredReusableCell(using: heatmapReg, for: indexPath, item: v)
            case .showsCard(let v): return collectionView.dequeueConfiguredReusableCell(using: showsReg, for: indexPath, item: v)
            case .clock(let v): return collectionView.dequeueConfiguredReusableCell(using: clockReg, for: indexPath, item: v)
            case .momentum(let v): return collectionView.dequeueConfiguredReusableCell(using: momentumReg, for: indexPath, item: v)
            case .moviePoster(let movie): return collectionView.dequeueConfiguredReusableCell(using: movieReg, for: indexPath, item: movie)
            case .libraries(let v): return collectionView.dequeueConfiguredReusableCell(using: librariesReg, for: indexPath, item: v)
            case .binges(let v): return collectionView.dequeueConfiguredReusableCell(using: bingesReg, for: indexPath, item: v)
            case .genresCard(let v): return collectionView.dequeueConfiguredReusableCell(using: genresReg, for: indexPath, item: v)
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

    private func makeTopShowsView() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 0
        for show in page.topShows {
            let row = RankedRowView()
            var accessory: UIView?
            if let completion = show.completion {
                let ring = CompletionRingView()
                ring.setProgress(completion, animated: true)
                accessory = ring
            }
            row.configure(
                title: show.title,
                valueText: show.valueText,
                fraction: show.fraction,
                colorIndex: 0,
                thumbPath: show.thumb,
                rank: show.rank,
                accessory: accessory
            )
            row.onTap = { [weak self] in
                guard let self else { return }
                pushDestination(.show(ratingKey: show.ratingKey))
            }
            stack.addArrangedSubview(row)
        }
        return stack
    }

    private func makeGenresView() -> UIView {
        switch page.genres {
        case .pending(let pending):
            return makePendingView(pending)
        case .ranked(let genres):
            let stack = UIStackView()
            stack.axis = .vertical
            for genre in genres {
                let row = RankedRowView()
                row.configure(title: genre.title, valueText: genre.valueText, fraction: genre.fraction, colorIndex: genre.colorIndex, thumbPath: nil)
                row.isAccessibilityElement = true
                row.accessibilityLabel = genre.accessibilityLabel
                stack.addArrangedSubview(row)
            }
            return stack
        }
    }

    private func makeClockView() -> UIView {
        let clock = RadialClockView()
        clock.setHours(page.clock.hours)
        clock.isAccessibilityElement = true
        clock.accessibilityTraits = .image
        clock.accessibilityLabel = page.clock.accessibilitySummary
        clock.setContentHuggingPriority(.required, for: .horizontal)
        let clockWidth = clock.widthAnchor.constraint(equalToConstant: 150)
        clockWidth.priority = .required
        clockWidth.isActive = true

        let weekday = WeekdayColumnChartView()
        weekday.setValues(page.clock.weekdays)

        let charts = UIStackView(arrangedSubviews: [clock, weekday])
        charts.axis = .horizontal
        charts.spacing = 12
        charts.alignment = .fill
        charts.heightAnchor.constraint(equalToConstant: 150).isActive = true

        let verdict = UILabel()
        verdict.text = page.clock.verdict
        verdict.font = Theme.Font.scaled(.callout, 14, .semibold)
        verdict.adjustsFontForContentSizeCategory = true
        verdict.textColor = Theme.Color.accentText
        verdict.textAlignment = .center
        verdict.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [charts, verdict])
        stack.axis = .vertical
        stack.spacing = 10
        return stack
    }

    private func makeLibrariesView() -> UIView {
        let libraries = page.libraries
        let donut = DonutChartView()
        donut.setSegments(libraries.segments)
        donut.setCenter(title: libraries.centerTitle, subtitle: libraries.centerSubtitle)
        donut.setContentHuggingPriority(.required, for: .horizontal)
        donut.widthAnchor.constraint(equalToConstant: 150).isActive = true
        donut.heightAnchor.constraint(equalToConstant: 150).isActive = true
        donut.isAccessibilityElement = false
        donut.accessibilityElementsHidden = true

        let legend = UIStackView()
        legend.axis = .vertical
        legend.spacing = 8
        legend.alignment = .fill
        for row in libraries.legend {
            legend.addArrangedSubview(makeLegendRow(color: StatsStyle.categoricalColor(row.colorIndex), title: row.title, value: row.value))
        }
        legend.isAccessibilityElement = true
        legend.accessibilityTraits = .image
        legend.accessibilityLabel = libraries.accessibilitySummary
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
        titleLabel.font = Theme.Font.footnote
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 1

        let valueLabel = UILabel()
        valueLabel.text = value
        valueLabel.font = Theme.Font.footnoteSemibold
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textColor = Theme.Color.labelSecondary
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [dot, titleLabel, valueLabel])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        return row
    }

    private func makePendingView(_ pending: StatsPage.GenresPending) -> UIView {
        let label = UILabel()
        label.text = pending.title
        label.font = Theme.Font.subheadline
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.labelSecondary

        let bar = UIProgressView(progressViewStyle: .default)
        bar.progressTintColor = Theme.Color.accent
        bar.trackTintColor = StatsStyle.trackBackground
        bar.progress = Float(pending.barFraction)

        let stack = UIStackView(arrangedSubviews: [label, bar])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill
        stack.isAccessibilityElement = true
        stack.accessibilityLabel = pending.accessibilityLabel
        return stack
    }

    private func makeShareButton() -> UIButton {
        let locked = ProAccess.shared.showsLocks
        let button = ThemeButton.primary(title: "Share Your Year", symbol: locked ? ProLock.symbolName : nil)
        button.accessibilityHint = locked ? "Requires Crucible Pro" : nil
        button.addAction(UIAction { [weak self] action in
            self?.shareWrapped(from: action.sender as? UIButton)
        }, for: .touchUpInside)
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
        case .moviePoster(let poster), .onThisDayPoster(let poster):
            pushDestination(poster.destination)
        default:
            break
        }
    }

    func pushDestination(_ destination: StatsDestination) {
        navigationController?.pushViewController(destination.makeViewController(api: api), animated: true)
    }

    func pushDayDetail(dayEpoch: Int) {
        guard let loader else { return }
        let date = statsTime.date(forDayEpoch: dayEpoch)
        navigationController?.pushViewController(StatsDayViewController(api: api, loader: loader, dayEpoch: dayEpoch, date: date), animated: true)
    }

    static func posterConfiguration(_ poster: StatsPoster) -> PosterContentConfiguration {
        var config = PosterContentConfiguration()
        config.posterPath = poster.posterPath
        config.title = poster.title
        config.subtitle = poster.subtitle
        config.placeholderIcon = poster.placeholderSymbol
        return config
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

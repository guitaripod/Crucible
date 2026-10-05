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

    private func posterRail() -> NSCollectionLayoutSection {
        let height = Theme.Size.posterRailWidth * Theme.Size.posterAspect + Theme.Size.captionBlockHeight
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(Theme.Size.posterRailWidth), heightDimension: .estimated(height)))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .absolute(Theme.Size.posterRailWidth), heightDimension: .estimated(height)), subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
        section.interGroupSpacing = 12
        section.contentInsets = .init(top: 4, leading: 16, bottom: 14, trailing: 16)
        section.boundarySupplementaryItems = [headerItem()]
        return section
    }

    private func cardSection(estimatedHeight: CGFloat = 160, top: CGFloat = 0, bottom: CGFloat = 14) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(estimatedHeight))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = .init(top: top, leading: 16, bottom: bottom, trailing: 16)
        return section
    }

    private func layoutSection(_ section: StatSection, environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        switch section {
        case .range:
            return cardSection(estimatedHeight: 44, top: 4, bottom: 12)
        case .hero:
            return cardSection(estimatedHeight: 188, bottom: 10)
        case .kpis:
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(0.5), heightDimension: .estimated(96))
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(96)), repeatingSubitem: item, count: 2)
            group.interItemSpacing = .fixed(10)
            let s = NSCollectionLayoutSection(group: group)
            s.interGroupSpacing = 10
            s.contentInsets = .init(top: 0, leading: 16, bottom: 14, trailing: 16)
            return s
        case .heatmap, .topShows, .clock, .momentum, .libraries, .binges, .genres:
            return cardSection()
        case .topMovies, .onThisDay:
            return posterRail()
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
            return cardSection(estimatedHeight: Theme.Size.primaryButtonHeight, top: 2, bottom: 28)
        }
    }
}

extension StatisticsViewController {
    func configureDataSource() {
        let rangeReg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            let control = StatsRangeControl()
            control.select(range)
            control.onRange = { [weak self] newRange in self?.selectRange(newRange) }
            host(control, in: cell)
        }

        let heroReg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            let hero = StatsHeroView()
            let content = heroContent()
            hero.configure(eyebrow: content.eyebrow, value: content.value, unit: content.unit, detail: content.detail, since: subtitleText(), animate: heroShouldAnimate)
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
            guard let self else { return }
            let trend = TrendAreaView()
            trend.showsAxes = true
            var summary = "Plays per month."
            if let peak = current.monthly.max(by: { $0.count < $1.count }) {
                let (year, month) = StatsTime.monthEpochToYearMonth(peak.monthEpoch)
                let peakText = "\(StatsStyle.monthSymbols[max(0, min(11, month - 1))]) \(year)"
                trend.peakAnnotation = peakText
                summary += " Peak in \(peakText) with \(peak.count) plays."
            }
            trend.setValues(current.monthly.map { Double($0.count) }, animated: true)
            trend.isAccessibilityElement = true
            trend.accessibilityTraits = .image
            trend.accessibilityLabel = summary
            host(StatsCardView(title: "Your Momentum", content: trend), in: cell)
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
            host(StatsCardView(title: "Your Libraries", content: makeLibrariesView()), in: cell)
        }

        let bingesReg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            let timeline = BingeTimelineView()
            timeline.setSessions(current.binges)
            host(StatsCardView(title: "Binges & Streaks", content: timeline), in: cell)
        }

        let genresReg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            host(StatsCardView(title: "Your Taste", content: makeGenresView()), in: cell)
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
        let maxCount = max(1, current.topShows.first?.count ?? 1)
        for (index, show) in current.topShows.enumerated() {
            let row = RankedRowView()
            var accessory: UIView?
            if let completion = show.completion {
                let ring = CompletionRingView()
                ring.setProgress(completion, animated: true)
                accessory = ring
            }
            let episodes = show.watchedEpisodes ?? show.count
            row.configure(
                title: show.title,
                valueText: episodes == 1 ? "1 ep" : "\(episodes) eps",
                fraction: Double(show.count) / Double(maxCount),
                colorIndex: 0,
                thumbPath: show.thumb,
                rank: index + 1,
                accessory: accessory
            )
            row.onTap = { [weak self] in
                guard let self else { return }
                navigationController?.pushViewController(ShowDetailViewController(api: api, showRatingKey: show.ratingKey), animated: true)
            }
            stack.addArrangedSubview(row)
        }
        return stack
    }

    private func makeGenresView() -> UIView {
        guard !current.genres.isEmpty else {
            return makePendingView(progress: current.enrichment.genreCoverage)
        }
        let stack = UIStackView()
        stack.axis = .vertical
        let maxCount = max(1, current.genres.first?.count ?? 1)
        for (index, genre) in current.genres.enumerated() {
            let row = RankedRowView()
            row.configure(title: genre.genre, valueText: "\(genre.count)", fraction: Double(genre.count) / Double(maxCount), colorIndex: index, thumbPath: nil)
            row.isAccessibilityElement = true
            row.accessibilityLabel = "\(genre.genre), \(genre.count) plays"
            stack.addArrangedSubview(row)
        }
        return stack
    }

    private func makeClockView() -> UIView {
        let clock = RadialClockView()
        clock.setHours(current.hourHistogram)
        clock.isAccessibilityElement = true
        clock.accessibilityTraits = .image
        clock.accessibilityLabel = clockSummary()
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
        charts.heightAnchor.constraint(equalToConstant: 150).isActive = true

        let verdict = UILabel()
        verdict.text = watchVerdict()
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

    /// VoiceOver summary for the 24-hour clock: the busiest hour and its share of plays.
    private func clockSummary() -> String {
        let hours = current.hourHistogram
        let total = hours.reduce(0, +)
        guard total > 0, let peak = hours.max(), let hour = hours.firstIndex(of: peak) else { return "Plays by hour of day." }
        let label = "\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")"
        let share = Int((Double(peak) / Double(total) * 100).rounded())
        return "Plays by hour of day. Busiest at \(label), \(share) percent of plays."
    }

    private func makeLibrariesView() -> UIView {
        let donut = DonutChartView()
        let segments = current.libraries.enumerated().map { DonutSegment(label: $0.element.title, value: $0.element.count, colorIndex: $0.offset) }
        donut.setSegments(segments)
        let total = current.libraries.reduce(0) { $0 + $1.count }
        donut.setCenter(title: StatsStyle.abbreviatedCount(total), subtitle: "plays")
        donut.setContentHuggingPriority(.required, for: .horizontal)
        donut.widthAnchor.constraint(equalToConstant: 150).isActive = true
        donut.heightAnchor.constraint(equalToConstant: 150).isActive = true
        donut.isAccessibilityElement = false
        donut.accessibilityElementsHidden = true

        let legend = UIStackView()
        legend.axis = .vertical
        legend.spacing = 8
        legend.alignment = .fill
        for (index, slice) in current.libraries.prefix(6).enumerated() {
            legend.addArrangedSubview(makeLegendRow(color: StatsStyle.categoricalColor(index), title: slice.title, value: StatsStyle.abbreviatedCount(slice.count)))
        }
        legend.isAccessibilityElement = true
        legend.accessibilityTraits = .image
        legend.accessibilityLabel = "Plays by library. " + current.libraries.prefix(6).map { "\($0.title), \($0.count)" }.joined(separator: ". ")
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

    private func makePendingView(progress: Double) -> UIView {
        let label = UILabel()
        label.text = "Analyzing your taste…"
        label.font = Theme.Font.subheadline
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.labelSecondary

        let bar = UIProgressView(progressViewStyle: .default)
        bar.progressTintColor = Theme.Color.accent
        bar.trackTintColor = StatsStyle.trackBackground
        bar.progress = Float(max(0.02, min(1, progress)))

        let stack = UIStackView(arrangedSubviews: [label, bar])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill
        stack.isAccessibilityElement = true
        stack.accessibilityLabel = "Analyzing your taste, \(Int((progress * 100).rounded())) percent"
        return stack
    }

    private func makeShareButton() -> UIButton {
        let button = ThemeButton.primary(title: "Share Your Year")
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

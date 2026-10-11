import CrucibleDesign
import CrucibleStats
import CrucibleStatsUI
import UIKit

/// Builds the focusable cards of the Statistics screen from a `StatsPage`: every chart is the shared
/// `CrucibleStatsUI` view with the TV metrics, wrapped in a `TVStatsPanel`.
@MainActor
enum TVStatsContent {
    private static let metrics = StatsMetrics.tv

    static func hero(_ page: StatsPage, animate: Bool) -> UIView {
        let hero = StatsHeroView(metrics: metrics)
        let content = page.hero
        hero.configure(eyebrow: content.eyebrow, value: content.value, unit: content.unit, detail: content.detail, since: content.since, animate: animate)
        addHeatStrip(for: page, to: hero)
        return TVReadOnlyPanel(wrapping: hero, label: { [weak hero] in hero?.accessibilityLabel })
    }

    private static func addHeatStrip(for page: StatsPage, to hero: UIView) {
        let strip = HeatStripView(strip: metrics.heroStrip)
        strip.levels = YearInReviewSummary.stripLevels(from: page.snapshot.heatmap, today: StatsTime().todayDayEpoch())
        strip.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.trailingAnchor.constraint(equalTo: hero.trailingAnchor, constant: -metrics.hero.inset),
            strip.centerYAnchor.constraint(equalTo: hero.centerYAnchor),
        ])
    }

    static func tile(_ tile: StatsPage.Tile) -> UIView {
        let view = StatTileView(metrics: metrics)
        view.backgroundColor = .clear
        view.layer.borderWidth = 0
        view.configure(.init(title: tile.title, value: tile.value, systemImage: tile.systemImage, caption: tile.caption))
        view.setSparkline(tile.sparkline)
        let summary = [tile.title, tile.value, tile.caption].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        return TVStatsPanel(content: view, margins: TVStatsPanel.flushMargins, summary: summary)
    }

    static func heatmap(_ page: StatsPage) -> UIView {
        let heatmap = ContributionHeatmapView(metrics: metrics)
        heatmap.setModel(page.heatmap)
        let active = page.heatmap.cells.count
        let busiest = page.heatmap.cells.map(\.count).max() ?? 0
        return TVStatsPanel(
            title: "Activity",
            accessory: StatsHeatLegendView(metrics: metrics),
            content: heatmap,
            summary: "Activity heatmap. \(active) active days, busiest day with \(busiest) plays."
        )
    }

    static func clock(_ page: StatsPage) -> UIView {
        let clock = RadialClockView(metrics: metrics)
        clock.setHours(page.clock.hours)
        let side = metrics.clock.intrinsicSide
        clock.setContentHuggingPriority(.required, for: .horizontal)
        clock.widthAnchor.constraint(equalToConstant: side).isActive = true
        clock.heightAnchor.constraint(equalToConstant: side).isActive = true

        let weekday = WeekdayColumnChartView(metrics: metrics)
        weekday.setValues(page.clock.weekdays)

        let charts = UIStackView(arrangedSubviews: [clock, weekday])
        charts.axis = .horizontal
        charts.spacing = Theme.Space.l
        charts.alignment = .fill

        let verdict = UILabel()
        verdict.text = page.clock.verdict
        verdict.font = Theme.Font.scaled(.callout, 35, .semibold)
        verdict.textColor = Theme.Color.accentText
        verdict.textAlignment = .center
        verdict.isHidden = page.clock.verdict.isEmpty

        let stack = UIStackView(arrangedSubviews: [charts, verdict])
        stack.axis = .vertical
        stack.spacing = Theme.Space.m
        return TVStatsPanel(title: "When You Watch", content: stack, summary: "\(page.clock.verdict). \(page.clock.accessibilitySummary)")
    }

    static func momentum(_ page: StatsPage) -> UIView? {
        guard let momentum = page.momentum else { return nil }
        let trend = TrendAreaView(metrics: metrics)
        trend.showsAxes = true
        trend.peakAnnotation = momentum.peakText
        trend.setValues(momentum.values, animated: true)
        return TVStatsPanel(title: "Your Momentum", content: trend, summary: momentum.summary)
    }

    static func libraries(_ page: StatsPage) -> UIView {
        let libraries = page.libraries
        let donut = DonutChartView(metrics: metrics)
        donut.setSegments(libraries.segments)
        donut.setCenter(title: libraries.centerTitle, subtitle: libraries.centerSubtitle)
        let side = metrics.donut.intrinsicSide
        donut.setContentHuggingPriority(.required, for: .horizontal)
        donut.widthAnchor.constraint(equalToConstant: side).isActive = true
        donut.heightAnchor.constraint(equalToConstant: side).isActive = true

        let total = max(1, libraries.segments.reduce(0) { $0 + $1.value })
        let shares = libraries.segments.map { Int((Double($0.value) / Double(total) * 100).rounded()) }
        let legend = UIStackView(arrangedSubviews: libraries.legend.enumerated().map { legendRow($1, share: shares[$0]) })
        legend.axis = .vertical
        legend.spacing = Theme.Space.s
        legend.alignment = .fill
        let legendColumn = UIStackView(arrangedSubviews: [UIView(), legend, UIView()])
        legendColumn.axis = .vertical
        legendColumn.distribution = .equalCentering

        legendColumn.widthAnchor.constraint(equalToConstant: 880).isActive = true
        let stack = UIStackView(arrangedSubviews: [donut, legendColumn, UIView()])
        stack.axis = .horizontal
        stack.spacing = Theme.Space.xl
        stack.alignment = .fill
        return TVStatsPanel(title: "Your Libraries", content: stack, summary: libraries.accessibilitySummary)
    }

    private static func legendRow(_ row: StatsPage.LegendRow, share: Int) -> UIView {
        let dot = UIView()
        dot.backgroundColor = StatsStyle.categoricalColor(row.colorIndex)
        dot.layer.cornerRadius = 12
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 24),
            dot.heightAnchor.constraint(equalToConstant: 24),
        ])
        let title = UILabel()
        title.text = row.title
        title.font = Theme.Font.callout
        title.textColor = Theme.Color.label
        let value = UILabel()
        value.text = row.value
        value.font = Theme.Font.scaled(.callout, 31, .semibold)
        value.textColor = Theme.Color.labelSecondary
        value.setContentHuggingPriority(.required, for: .horizontal)
        let percent = UILabel()
        percent.text = share == 0 ? "<1%" : "\(share)%"
        percent.font = Theme.Font.callout
        percent.textColor = Theme.Color.labelTertiary
        percent.textAlignment = .right
        percent.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let stack = UIStackView(arrangedSubviews: [dot, title, UIView(), value, percent])
        stack.axis = .horizontal
        stack.spacing = Theme.Space.s
        stack.alignment = .center
        return stack
    }

    static func genres(_ page: StatsPage) -> UIView {
        switch page.genres {
        case .pending(let pending):
            return TVStatsPanel(title: "Your Taste", content: pendingView(pending), summary: pending.accessibilityLabel)
        case .ranked(let rows):
            let columns = rankedColumns(rows)
            let summary = rows.map(\.accessibilityLabel).joined(separator: ". ")
            return TVStatsPanel(title: "Your Taste", content: columns, summary: "Top genres. \(summary)")
        }
    }

    private static func rankedColumns(_ rows: [StatsPage.GenreRow]) -> UIView {
        let perColumn = max(1, (rows.count + 1) / 2)
        let columns = stride(from: 0, to: rows.count, by: perColumn).map { start -> UIView in
            let stack = UIStackView()
            stack.axis = .vertical
            stack.alignment = .fill
            for genre in rows[start..<min(rows.count, start + perColumn)] {
                let row = RankedRowView(metrics: metrics)
                row.configure(title: genre.title, valueText: genre.valueText, fraction: genre.fraction, colorIndex: genre.colorIndex, thumbPath: nil)
                stack.addArrangedSubview(row)
            }
            return stack
        }
        let container = UIStackView(arrangedSubviews: columns)
        container.axis = .horizontal
        container.spacing = Theme.Space.xl
        container.alignment = .top
        container.distribution = .fillEqually
        return container
    }

    private static func pendingView(_ pending: StatsPage.GenresPending) -> UIView {
        let label = UILabel()
        label.text = pending.title
        label.font = Theme.Font.callout
        label.textColor = Theme.Color.labelSecondary
        let bar = ProgressBar()
        bar.style = .onSurface
        bar.progress = pending.barFraction
        let stack = UIStackView(arrangedSubviews: [label, bar])
        stack.axis = .vertical
        stack.spacing = Theme.Space.s
        return stack
    }

    static func wrapped(_ superlative: Superlative) -> UIView {
        let card = SuperlativeCardView(metrics: metrics)
        card.configure(superlative)
        let summary = [superlative.headline, superlative.title, superlative.caption].filter { !$0.isEmpty }.joined(separator: ". ")
        return TVStatsPanel(content: card, margins: TVStatsPanel.flushMargins, summary: summary)
    }

    static func binge(_ session: BingeSession, colorIndex: Int) -> UIView {
        let card = BingeCardView(session: session, colorIndex: colorIndex, metrics: metrics)
        let panel = TVStatsPanel(content: card, margins: TVStatsPanel.flushMargins, summary: card.accessibilityLabel)
        return panel
    }
}

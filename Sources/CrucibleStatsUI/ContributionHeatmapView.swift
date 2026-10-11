import CrucibleDesign
import CrucibleStats
import UIKit

private struct HeatmapGeometry {
    static let rows = 7

    let metrics: StatsMetrics.Heatmap

    var cellEdge: CGFloat { metrics.cellEdge }
    var corner: CGFloat { metrics.corner }
    var monthLabelHeight: CGFloat { metrics.monthLabelHeight }
    var step: CGFloat { metrics.cellEdge + metrics.gap }
    var gridHeight: CGFloat { metrics.monthLabelHeight + CGFloat(Self.rows) * step }
}

/// GitHub-style year contribution calendar: 7 rows (row 0 = Sunday) by `model.columns`
/// week-columns, hosted in a horizontally scrolling canvas that reveals to the most recent week.
package final class ContributionHeatmapView: UIView {
    /// Invoked with the derived `dayEpoch` when a rendered day cell is tapped.
    package var onSelectDay: ((Int) -> Void)?

    private let scrollView = UIScrollView()
    private let content: GridContentView
    private let geometry: HeatmapGeometry
    private var model = HeatmapModel()
    private var pendingReveal = false

    package init(metrics: StatsMetrics = .platform) {
        geometry = HeatmapGeometry(metrics: metrics.heatmap)
        content = GridContentView(geometry: geometry)
        super.init(frame: .zero)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delaysContentTouches = false
        scrollView.backgroundColor = .clear
        addSubview(scrollView)
        isAccessibilityElement = true
        accessibilityTraits = .image

        content.backgroundColor = .clear
        content.onTap = { [weak self] point in
            self?.handleTap(at: point)
        }
        scrollView.addSubview(content)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    package override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: geometry.gridHeight)
    }

    /// Replaces the rendered calendar and queues a reveal that pans to the most recent week.
    package func setModel(_ model: HeatmapModel) {
        self.model = model
        accessibilityLabel = Self.summary(for: model)
        content.model = model
        content.setNeedsDisplay()
        pendingReveal = true
        setNeedsLayout()
    }

    package override func layoutSubviews() {
        super.layoutSubviews()
        let width = CGFloat(model.columns) * geometry.step
        let height = geometry.gridHeight
        content.frame = CGRect(x: 0, y: 0, width: width, height: height)
        scrollView.contentSize = CGSize(width: width, height: height)

        if pendingReveal, scrollView.bounds.width > 0 {
            pendingReveal = false
            performReveal(width: width)
        }
    }

    private static func summary(for model: HeatmapModel) -> String {
        let active = model.cells.count
        guard active > 0 else { return "Activity heatmap. No watched days." }
        let busiest = model.cells.map(\.count).max() ?? 0
        return "Activity heatmap. \(active) active days, busiest day with \(busiest) plays."
    }

    private func performReveal(width: CGFloat) {
        guard width > 0 else {
            content.alpha = 1
            return
        }
        let target = CGPoint(x: max(0, width - scrollView.bounds.width), y: 0)
        if UIAccessibility.isReduceMotionEnabled {
            content.alpha = 1
            scrollView.contentOffset = target
            return
        }
        content.alpha = 0
        scrollView.contentOffset = .zero
        UIView.animate(withDuration: 0.6, delay: 0.05, options: [.curveEaseInOut]) {
            self.content.alpha = 1
            self.scrollView.contentOffset = target
        }
    }

    private func handleTap(at point: CGPoint) {
        guard model.columns > 0, point.y >= geometry.monthLabelHeight else { return }
        let column = Int(point.x / geometry.step)
        let row = Int((point.y - geometry.monthLabelHeight) / geometry.step)
        guard column >= 0, column < model.columns, row >= 0, row < HeatmapGeometry.rows else { return }
        let dayEpoch = model.firstDayEpoch + column * HeatmapGeometry.rows + row
        guard dayEpoch <= model.lastDayEpoch else { return }
        onSelectDay?(dayEpoch)
    }
}

private final class GridContentView: UIView {
    var model = HeatmapModel()
    var onTap: ((CGPoint) -> Void)?

    private var touchOrigin: CGPoint?
    private let geometry: HeatmapGeometry

    init(geometry: HeatmapGeometry) {
        self.geometry = geometry
        super.init(frame: .zero)
        isOpaque = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: GridContentView, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        let m = model
        guard m.columns > 0 else { return }

        var occupied = Set<Int>()
        occupied.reserveCapacity(m.cells.count)
        for cell in m.cells {
            occupied.insert(cell.column * HeatmapGeometry.rows + cell.row)
        }

        let baseColor = StatsStyle.heatColor(level: 0)
        for column in 0..<m.columns {
            for row in 0..<HeatmapGeometry.rows {
                let dayEpoch = m.firstDayEpoch + column * HeatmapGeometry.rows + row
                if dayEpoch > m.lastDayEpoch { continue }
                if occupied.contains(column * HeatmapGeometry.rows + row) { continue }
                fillCell(column: column, row: row, color: baseColor)
            }
        }

        for cell in m.cells {
            guard cell.column >= 0, cell.column < m.columns,
                  cell.row >= 0, cell.row < HeatmapGeometry.rows else { continue }
            let dayEpoch = m.firstDayEpoch + cell.column * HeatmapGeometry.rows + cell.row
            if dayEpoch > m.lastDayEpoch { continue }
            fillCell(column: cell.column, row: cell.row, color: StatsStyle.heatColor(level: cell.level))
        }

        drawMonthLabels(m)
    }

    private func fillCell(column: Int, row: Int, color: UIColor) {
        let origin = CGPoint(
            x: CGFloat(column) * geometry.step,
            y: geometry.monthLabelHeight + CGFloat(row) * geometry.step
        )
        let rect = CGRect(origin: origin, size: CGSize(width: geometry.cellEdge, height: geometry.cellEdge))
        let path = UIBezierPath(roundedRect: rect, cornerRadius: geometry.corner)
        color.setFill()
        path.fill()
    }

    private func drawMonthLabels(_ m: HeatmapModel) {
        guard !m.monthLabels.isEmpty else { return }
        let font = geometry.metrics.monthFont.uiFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Theme.Color.labelTertiary,
        ]
        let y = max(0, (geometry.monthLabelHeight - font.lineHeight) / 2)
        for (column, label) in m.monthLabels where column >= 0 && column < m.columns {
            let labelWidth = (label as NSString).size(withAttributes: attributes).width
            let x = min(CGFloat(column) * geometry.step, max(0, bounds.width - labelWidth))
            (label as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchOrigin = touches.first?.location(in: self)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let origin = touchOrigin, let point = touches.first?.location(in: self) else { return }
        if abs(point.x - origin.x) > 12 || abs(point.y - origin.y) > 12 {
            touchOrigin = nil
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { touchOrigin = nil }
        guard touchOrigin != nil, let point = touches.first?.location(in: self) else { return }
        onTap?(point)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchOrigin = nil
    }
}

import UIKit

private enum HeatmapMetrics {
    static let cellEdge: CGFloat = 13
    static let gap: CGFloat = 3
    static let corner: CGFloat = 3
    static let rows = 7
    static let monthLabelHeight: CGFloat = 16
    static var step: CGFloat { cellEdge + gap }
    static var gridHeight: CGFloat { monthLabelHeight + CGFloat(rows) * step }
}

/// GitHub-style year contribution calendar: 7 rows (row 0 = Sunday) by `model.columns`
/// week-columns, hosted in a horizontally scrolling canvas that reveals to the most recent week.
final class ContributionHeatmapView: UIView {
    /// Invoked with the derived `dayEpoch` when a rendered day cell is tapped.
    var onSelectDay: ((Int) -> Void)?

    private let scrollView = UIScrollView()
    private let content = GridContentView()
    private var model = HeatmapModel()
    private var pendingReveal = false

    override init(frame: CGRect) {
        super.init(frame: frame)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delaysContentTouches = false
        scrollView.backgroundColor = .clear
        addSubview(scrollView)

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

    convenience init() { self.init(frame: .zero) }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: HeatmapMetrics.gridHeight)
    }

    /// Replaces the rendered calendar and queues a reveal that pans to the most recent week.
    func setModel(_ model: HeatmapModel) {
        self.model = model
        content.model = model
        content.setNeedsDisplay()
        pendingReveal = true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = CGFloat(model.columns) * HeatmapMetrics.step
        let height = HeatmapMetrics.gridHeight
        content.frame = CGRect(x: 0, y: 0, width: width, height: height)
        scrollView.contentSize = CGSize(width: width, height: height)

        if pendingReveal, scrollView.bounds.width > 0 {
            pendingReveal = false
            performReveal(width: width)
        }
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
        guard model.columns > 0, point.y >= HeatmapMetrics.monthLabelHeight else { return }
        let column = Int(point.x / HeatmapMetrics.step)
        let row = Int((point.y - HeatmapMetrics.monthLabelHeight) / HeatmapMetrics.step)
        guard column >= 0, column < model.columns, row >= 0, row < HeatmapMetrics.rows else { return }
        let dayEpoch = model.firstDayEpoch + column * HeatmapMetrics.rows + row
        guard dayEpoch <= model.lastDayEpoch else { return }
        onSelectDay?(dayEpoch)
    }
}

private final class GridContentView: UIView {
    var model = HeatmapModel()
    var onTap: ((CGPoint) -> Void)?

    private var touchOrigin: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
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
            occupied.insert(cell.column * HeatmapMetrics.rows + cell.row)
        }

        let baseColor = StatsStyle.heatColor(level: 0)
        for column in 0..<m.columns {
            for row in 0..<HeatmapMetrics.rows {
                let dayEpoch = m.firstDayEpoch + column * HeatmapMetrics.rows + row
                if dayEpoch > m.lastDayEpoch { continue }
                if occupied.contains(column * HeatmapMetrics.rows + row) { continue }
                fillCell(column: column, row: row, color: baseColor)
            }
        }

        for cell in m.cells {
            guard cell.column >= 0, cell.column < m.columns,
                  cell.row >= 0, cell.row < HeatmapMetrics.rows else { continue }
            let dayEpoch = m.firstDayEpoch + cell.column * HeatmapMetrics.rows + cell.row
            if dayEpoch > m.lastDayEpoch { continue }
            fillCell(column: cell.column, row: cell.row, color: StatsStyle.heatColor(level: cell.level))
        }

        drawMonthLabels(m)
    }

    private func fillCell(column: Int, row: Int, color: UIColor) {
        let origin = CGPoint(
            x: CGFloat(column) * HeatmapMetrics.step,
            y: HeatmapMetrics.monthLabelHeight + CGFloat(row) * HeatmapMetrics.step
        )
        let rect = CGRect(origin: origin, size: CGSize(width: HeatmapMetrics.cellEdge, height: HeatmapMetrics.cellEdge))
        let path = UIBezierPath(roundedRect: rect, cornerRadius: HeatmapMetrics.corner)
        color.setFill()
        path.fill()
    }

    private func drawMonthLabels(_ m: HeatmapModel) {
        guard !m.monthLabels.isEmpty else { return }
        let font = UIFont.systemFont(ofSize: 10, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.secondaryLabel,
        ]
        let y = max(0, (HeatmapMetrics.monthLabelHeight - font.lineHeight) / 2)
        for (column, label) in m.monthLabels where column >= 0 && column < m.columns {
            let point = CGPoint(x: CGFloat(column) * HeatmapMetrics.step, y: y)
            (label as NSString).draw(at: point, withAttributes: attributes)
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

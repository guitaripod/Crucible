import CrucibleCore
import UIKit

/// The week of Library Research's hours as a grid: a row per day in the order the device's calendar starts its week, a
/// column per hour, the chosen hours filled and now outlined on the server's clock. On iPhone and iPad a tap chooses an
/// hour, a sideways drag paints many, and a tap on a day or an hour's heading chooses all of it; on Apple TV it only shows.
package final class SportsWeekGridView: UIView {
    package private(set) var schedule = SportsSchedule.always
    /// The server's day (Monday 0) and hour now, outlined on the grid.
    package var now: (day: Int, hour: Int)? {
        didSet { setNeedsDisplay() }
    }
    /// Called for every hour the owner changes, and once when a tap or drag ends.
    package var onChange: ((SportsSchedule) -> Void)?
    package var onCommit: ((SportsSchedule) -> Void)?

    private let order = SportsCopy.weekOrder
    private var painting: Bool?
    private var lastCell: (row: Int, column: Int)?

    package init(editable: Bool) {
        super.init(frame: .zero)
        backgroundColor = .clear
        contentMode = .redraw
        isOpaque = false
        #if os(iOS)
        if editable { installGestures() }
        #endif
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: SportsWeekGridView, _: UITraitCollection) in
            view.invalidateIntrinsicContentSize()
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `schedule` unless the owner is painting, so a refresh never pulls the grid out from under a finger.
    package func show(_ schedule: SportsSchedule) {
        guard painting == nil, schedule != self.schedule else { return }
        self.schedule = schedule
        setNeedsDisplay()
        refreshAccessibility()
    }

    // MARK: Geometry

    private var labelFont: UIFont { Theme.Font.caption2Regular }
    private var dayColumnWidth: CGFloat {
        let widest = order.map { (SportsCopy.weekday($0, short: true) as NSString).size(withAttributes: [.font: labelFont]).width }.max() ?? 30
        return ceil(widest) + Theme.Space.xs
    }
    private var headerHeight: CGFloat { ceil(labelFont.lineHeight) + Theme.Space.xxs }
    private var rowHeight: CGFloat { max(ceil(labelFont.lineHeight * 1.9), traitCollection.userInterfaceIdiom == .tv ? 44 : 28) }
    private var gap: CGFloat { traitCollection.userInterfaceIdiom == .tv ? 3 : 2 }

    override package var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: headerHeight + 7 * rowHeight)
    }

    private var cellWidth: CGFloat { (bounds.width - dayColumnWidth) / 24 }

    private func cellRect(row: Int, column: Int) -> CGRect {
        CGRect(x: dayColumnWidth + CGFloat(column) * cellWidth, y: headerHeight + CGFloat(row) * rowHeight, width: cellWidth, height: rowHeight)
            .insetBy(dx: gap / 2, dy: gap / 2)
    }

    private enum Spot: Equatable {
        case cell(row: Int, column: Int)
        case day(row: Int)
        case hour(column: Int)
    }

    private func spot(at point: CGPoint) -> Spot? {
        let row = Int(floor((point.y - headerHeight) / rowHeight))
        let column = Int(floor((point.x - dayColumnWidth) / cellWidth))
        switch (point.x < dayColumnWidth, point.y < headerHeight) {
        case (true, true): return nil
        case (true, false): return (0..<7).contains(row) ? .day(row: row) : nil
        case (false, true): return (0..<24).contains(column) ? .hour(column: column) : nil
        case (false, false): return (0..<7).contains(row) && (0..<24).contains(column) ? .cell(row: row, column: column) : nil
        }
    }

    // MARK: Drawing

    override package func draw(_ rect: CGRect) {
        let secondary: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: Theme.Color.labelSecondary]
        for hour in stride(from: 0, to: 24, by: 6) {
            let text = SportsCopy.hour(hour, short: true) as NSString
            let origin = CGPoint(x: dayColumnWidth + CGFloat(hour) * cellWidth + gap / 2, y: 0)
            text.draw(at: origin, withAttributes: secondary)
        }
        let corner = min(cellWidth, rowHeight) * 0.22
        for (row, day) in order.enumerated() {
            let name = SportsCopy.weekday(day, short: true) as NSString
            let size = name.size(withAttributes: secondary)
            let rowTop = headerHeight + CGFloat(row) * rowHeight
            name.draw(at: CGPoint(x: 0, y: rowTop + (rowHeight - size.height) / 2), withAttributes: secondary)
            for hour in 0..<24 {
                let path = UIBezierPath(roundedRect: cellRect(row: row, column: hour), cornerRadius: corner)
                (schedule.allows(day: day, hour: hour) ? Theme.Color.accent : Theme.Color.surfaceHigh).setFill()
                path.fill()
            }
        }
        if let now, let row = order.firstIndex(of: now.day), (0..<24).contains(now.hour) {
            let path = UIBezierPath(roundedRect: cellRect(row: row, column: now.hour).insetBy(dx: -1, dy: -1), cornerRadius: corner + 1)
            path.lineWidth = 2
            Theme.Color.label.setStroke()
            path.stroke()
        }
    }

    // MARK: Accessibility

    override package func layoutSubviews() {
        super.layoutSubviews()
        refreshAccessibility()
    }

    /// One element per day, its hours as the value, with actions to choose a whole day, none of it, or any one hour.
    private func refreshAccessibility() {
        accessibilityElements = order.enumerated().map { row, day in
            let element = UIAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = SportsCopy.weekday(day)
            element.accessibilityValue = SportsCopy.dayHours(schedule, day: day)
            element.accessibilityFrameInContainerSpace = CGRect(x: 0, y: headerHeight + CGFloat(row) * rowHeight, width: bounds.width, height: rowHeight)
            element.accessibilityIdentifier = "sports.schedule.day.\(day)"
            guard onChange != nil else { return element }
            var actions = [
                UIAccessibilityCustomAction(name: SportsCopy.allDay) { [weak self] _ in self?.change { $0.set(day: day, to: SportsSchedule.wholeDay) } ?? false },
                UIAccessibilityCustomAction(name: SportsCopy.noHours) { [weak self] _ in self?.change { $0.set(day: day, to: 0) } ?? false },
            ]
            actions += (0..<24).map { hour in
                let on = schedule.allows(day: day, hour: hour)
                let name = on ? SportsCopy.leaveOut(SportsCopy.hour(hour)) : SportsCopy.choose(SportsCopy.hour(hour))
                return UIAccessibilityCustomAction(name: name) { [weak self] _ in self?.change { $0.set(day: day, hour: hour, to: !on) } ?? false }
            }
            element.accessibilityCustomActions = actions
            return element
        }
    }

    /// One whole change: shown, reported and committed at once.
    @discardableResult
    private func change(_ edit: (inout SportsSchedule) -> Void) -> Bool {
        var changed = schedule
        edit(&changed)
        guard changed != schedule else { return true }
        schedule = changed
        setNeedsDisplay()
        refreshAccessibility()
        onChange?(changed)
        onCommit?(changed)
        return true
    }
}

#if os(iOS)
extension SportsWeekGridView: UIGestureRecognizerDelegate {
    private func installGestures() {
        let tap = UITapGestureRecognizer(target: nil, action: nil)
        tap.addTarget(self, action: #selector(tapped(_:)))
        addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: nil, action: nil)
        pan.addTarget(self, action: #selector(panned(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    /// A drag paints only when it starts sideways, so an upward or downward one still scrolls the screen.
    override package func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        guard abs(velocity.x) > abs(velocity.y) else { return false }
        if case .cell? = spot(at: pan.location(in: self)) { return true }
        return false
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        switch spot(at: gesture.location(in: self)) {
        case .cell(let row, let column)?:
            let day = order[row]
            Haptics.selection()
            change { $0.set(day: day, hour: column, to: !$0.allows(day: day, hour: column)) }
        case .day(let row)?:
            let day = order[row]
            Haptics.light()
            change { $0.set(day: day, to: $0.ranges(day: day) == [0..<24] ? 0 : SportsSchedule.wholeDay) }
        case .hour(let column)?:
            Haptics.light()
            change { $0.set(hour: column, to: !$0.allDays(hour: column)) }
        case nil:
            break
        }
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            guard case .cell(let row, let column)? = spot(at: point) else { return }
            let target = !schedule.allows(day: order[row], hour: column)
            painting = target
            lastCell = nil
            paint(row: row, column: column, to: target)
        case .changed:
            guard let target = painting else { return }
            let row = min(6, max(0, Int(floor((point.y - headerHeight) / rowHeight))))
            let column = min(23, max(0, Int(floor((point.x - dayColumnWidth) / cellWidth))))
            paint(row: row, column: column, to: target)
        default:
            guard painting != nil else { return }
            painting = nil
            lastCell = nil
            refreshAccessibility()
            onCommit?(schedule)
        }
    }

    /// Paints every cell from the last one painted to this one, so a quick drag leaves no gaps.
    private func paint(row: Int, column: Int, to target: Bool) {
        let start = lastCell ?? (row, column)
        let steps = max(abs(row - start.row), abs(column - start.column), 1)
        var changed = false
        for step in 0...steps {
            let fraction = Double(step) / Double(steps)
            let cellRow = start.row + Int((Double(row - start.row) * fraction).rounded())
            let cellColumn = start.column + Int((Double(column - start.column) * fraction).rounded())
            let day = order[cellRow]
            if schedule.allows(day: day, hour: cellColumn) != target {
                schedule.set(day: day, hour: cellColumn, to: target)
                changed = true
            }
        }
        lastCell = (row, column)
        guard changed else { return }
        Haptics.selection()
        setNeedsDisplay()
        onChange?(schedule)
    }
}
#endif

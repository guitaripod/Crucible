import Foundation
import Kiln

/// A channel's row in the TV guide.
public struct GuideRow: Equatable, Sendable {
    public var id: String
    public var number: String?
    public var title: String
    public var logo: ArtworkSource?
    public var isFavorite: Bool
    /// The airings on the row, in time order; nil while they load.
    public var cells: [GuideCell]?

    public init(id: String, number: String?, title: String, logo: ArtworkSource?, isFavorite: Bool, cells: [GuideCell]?) {
        self.id = id
        self.number = number
        self.title = title
        self.logo = logo
        self.isFavorite = isFavorite
        self.cells = cells
    }
}

/// One airing in a guide row.
public struct GuideCell: Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String?
    public var start: Date
    public var end: Date
    public var isNew: Bool
    public var isRecording: Bool

    public init(id: String, title: String, detail: String?, start: Date, end: Date, isNew: Bool = false, isRecording: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.start = start
        self.end = end
        self.isNew = isNew
        self.isRecording = isRecording
    }
}

/// The TV guide: channels down the leading edge, their airings across a timeline that starts at `origin`, a line at the
/// present moment, and one focus that moves airing by airing with the arrows or the d-pad (Up and Down keep the time),
/// Page Up and Page Down by a screenful, Home back to now. Only the rows on screen are drawn, so a guide of hundreds of
/// channels scrolls as lightly as a short one. Select opens the focused airing, Play plays its channel, the Menu key or a
/// right click opens its menu; the wheel scrolls (with Shift, through time).
@MainActor
public final class GuideGridView: View {
    public var rows: [GuideRow] = [] {
        didSet {
            layoutCache.removeAll()
            if rows.map(\.id) != oldValue.map(\.id) {
                logos = logos.filter { id, _ in rows.contains { $0.id == id } }
                cursorRow = min(cursorRow, max(rows.count - 1, 0))
            }
            clampScroll(animated: false)
            reportVisibleRows()
            setNeedsDisplay()
        }
    }

    /// Where the timeline begins: nothing before it is shown.
    public var origin = Date() {
        didSet {
            layoutCache.removeAll()
            if cursorTime < origin { cursorTime = origin }
            setNeedsDisplay()
        }
    }

    /// The present moment, where the line is drawn and airings count as on.
    public var now = Date() { didSet { setNeedsDisplay() } }

    public var onActivate: ((GuideRow, GuideCell?) -> Void)?
    public var onPlay: ((GuideRow) -> Void)?
    public var onContextMenu: ((GuideRow, GuideCell?, Point?) -> Void)?
    /// The ids of the rows on screen, whenever they change, so their airings can load.
    public var onVisibleRows: (([String]) -> Void)?
    public var onFocusMove: ((GuideRow, GuideCell?) -> Void)?
    /// The labels the guide draws: the time format, and the words for a row still loading and one without listings.
    public var timeLabel: (Date) -> String = { date in
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    public var loadingText = "…"
    public var emptyText = ""

    private var cursorRow = 0
    private var cursorTime = Date()
    private var scrollY = Animated(0)
    private var scrollX = Animated(0)
    private var lift = Animated(0)
    private var hovered: (row: Int, cell: Int?)?
    private var logos: [String: ArtworkSlot] = [:]
    private var lastVisible: [String] = []
    private var layoutCache: [String: TextLayout] = [:]

    public override init(frame: Rect = .zero) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    public override var canBecomeFocused: Bool { !rows.isEmpty }
    public override var accessibilityRole: AccessibilityRole { .list }
    public override var accessibilityLabel: String? {
        guard rows.indices.contains(cursorRow) else { return nil }
        let row = rows[cursorRow]
        let cell = focusedCell.map { row.cells?[$0] } ?? nil
        return [row.number, row.title, cell?.title, cell.map { "\(timeLabel($0.start)) – \(timeLabel($0.end))" }].compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: Geometry

    private var metrics: Metrics { Theme.current.metrics }
    private var channelWidth: Float { metrics.tv(Theme.current.density == .desk ? 380 : 430) }
    private var headerHeight: Float { metrics.tv(64) }
    private var rowHeight: Float { metrics.tv(Theme.current.density == .desk ? 96 : 116) }
    private var rowGap: Float { metrics.tv(8) }
    private var pointsPerHour: Float { metrics.tv(Theme.current.density == .desk ? 640 : 760) }
    private var gridLeft: Float { channelWidth + metrics.tv(12) }
    private var gridWidth: Float { max(bounds.width - gridLeft, 1) }
    private var rowPitch: Float { rowHeight + rowGap }

    private func x(of date: Date) -> Float {
        gridLeft + Float(date.timeIntervalSince(origin) / 3600) * pointsPerHour - scrollX.value
    }

    private func date(atX x: Float) -> Date {
        origin.addingTimeInterval(TimeInterval((x - gridLeft + scrollX.value) / pointsPerHour * 3600))
    }

    private func y(ofRow index: Int) -> Float {
        headerHeight + Float(index) * rowPitch - scrollY.value
    }

    private var visibleRange: Range<Int> {
        guard !rows.isEmpty else { return 0..<0 }
        let first = max(Int((scrollY.value / rowPitch).rounded(.down)) - 1, 0)
        let count = Int(((bounds.height - headerHeight) / rowPitch).rounded(.up)) + 3
        return first..<min(first + count, rows.count)
    }

    /// The index of the focused row's airing at the cursor's time.
    private var focusedCell: Int? {
        guard rows.indices.contains(cursorRow), let cells = rows[cursorRow].cells else { return nil }
        return cells.firstIndex { $0.start <= cursorTime && cursorTime < $0.end }
    }

    // MARK: Public moves

    /// Scrolls back to the present and puts the focus on what is on now in the focused row.
    public func jumpToNow(animated: Bool = true) {
        cursorTime = max(now, origin)
        scrollX.set(0, animation: animated ? .scroll : nil)
        reveal(animated: animated)
        focusMoved()
    }

    /// Moves the focus to the row with `id`, at the present.
    public func focusRow(_ id: String, animated: Bool = false) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        cursorRow = index
        cursorTime = max(now, origin)
        reveal(animated: animated)
        focusMoved()
    }

    /// The focused row and airing.
    public var focused: (row: GuideRow, cell: GuideCell?)? {
        guard rows.indices.contains(cursorRow) else { return nil }
        let row = rows[cursorRow]
        return (row, focusedCell.flatMap { row.cells?[$0] })
    }

    // MARK: Input

    public override func keyPressed(_ event: KeyEvent) -> Bool {
        guard !rows.isEmpty, event.modifiers.subtracting(.shift).isEmpty else { return false }
        switch event.key {
        case .up:
            guard cursorRow > 0 else { return false }
            moveRow(by: -1)
        case .down:
            guard cursorRow < rows.count - 1 else { return false }
            moveRow(by: 1)
        case .left:
            return moveAcross(forward: false)
        case .right:
            return moveAcross(forward: true)
        case .pageUp:
            moveRow(by: -max(visibleRange.count - 3, 1))
        case .pageDown:
            moveRow(by: max(visibleRange.count - 3, 1))
        case .home:
            jumpToNow()
        case .end:
            cursorRow = rows.count - 1
            reveal(animated: true)
            focusMoved()
        case .mediaPlay, Key.character("p"):
            onPlay?(rows[cursorRow])
        default:
            return false
        }
        return true
    }

    public override func activate() {
        guard let focused else { return }
        onActivate?(focused.row, focused.cell)
    }

    public override func showContextMenu(at point: Point?) -> Bool {
        guard let focused else { return false }
        let anchor = point ?? transformToWindow.apply(focusedRect ?? bounds).origin
        onContextMenu?(focused.row, focused.cell, anchor)
        return true
    }

    private func moveRow(by delta: Int) {
        let target = min(max(cursorRow + delta, 0), rows.count - 1)
        guard target != cursorRow else { return }
        cursorRow = target
        reveal(animated: true)
        focusMoved()
    }

    /// Moves to the airing before or after the focused one; past the listings, half an hour at a time. Left from the
    /// first half hour leaves the guide, as a list's leading edge does.
    private func moveAcross(forward: Bool) -> Bool {
        let cells = rows[cursorRow].cells ?? []
        if let index = focusedCell {
            let next = index + (forward ? 1 : -1)
            if cells.indices.contains(next) {
                cursorTime = max(cells[next].start, origin).addingTimeInterval(1)
            } else {
                let edge = forward ? cells[index].end : cells[index].start.addingTimeInterval(-1)
                guard edge > origin else { return false }
                cursorTime = forward ? edge.addingTimeInterval(1) : max(edge.addingTimeInterval(-1799), origin)
            }
        } else {
            let step: TimeInterval = forward ? 1800 : -1800
            let moved = cursorTime.addingTimeInterval(step)
            guard moved >= origin else { return false }
            if forward, let following = cells.first(where: { $0.start > cursorTime }), following.start < moved {
                cursorTime = following.start.addingTimeInterval(1)
            } else if !forward, let before = cells.last(where: { $0.end <= cursorTime }), before.end > moved {
                cursorTime = max(before.start, origin).addingTimeInterval(1)
            } else {
                cursorTime = moved
            }
        }
        reveal(animated: true)
        focusMoved()
        return true
    }

    private func focusMoved() {
        lift.reset(0.6)
        lift.set(1, animation: .focus)
        startAnimating()
        setNeedsDisplay()
        if let focused { onFocusMove?(focused.row, focused.cell) }
    }

    /// Scrolls so the focused row and the start of its airing are on screen.
    private func reveal(animated: Bool) {
        let top = Float(cursorRow) * rowPitch
        let visibleHeight = bounds.height - headerHeight
        var targetY = scrollY.target
        if top < targetY + rowPitch * 0.5 { targetY = top - rowPitch * 0.5 }
        if top + rowPitch > targetY + visibleHeight - rowPitch * 0.5 { targetY = top + rowPitch * 1.5 - visibleHeight }
        let cellStart: Date = focusedCell.flatMap { rows[cursorRow].cells?[$0].start } ?? cursorTime
        let startX = Float(max(cellStart, origin).timeIntervalSince(origin) / 3600) * pointsPerHour
        let cursorX = Float(cursorTime.timeIntervalSince(origin) / 3600) * pointsPerHour
        var targetX = scrollX.target
        if cursorX < targetX + metrics.tv(40) { targetX = max(startX - metrics.tv(40), 0) }
        if cursorX > targetX + gridWidth - metrics.tv(200) { targetX = max(cursorX - gridWidth * 0.4, 0) }
        scrollY.set(clampY(targetY), animation: animated ? .scroll : nil)
        scrollX.set(max(targetX, 0), animation: animated ? .scroll : nil)
        startAnimating()
        reportVisibleRows()
    }

    private func clampY(_ value: Float) -> Float {
        let content = Float(rows.count) * rowPitch
        let room = bounds.height - headerHeight
        return min(max(value, 0), max(content - room + rowGap, 0))
    }

    private func clampScroll(animated: Bool) {
        scrollY.set(clampY(scrollY.target), animation: animated ? .scroll : nil)
    }

    public override func scrolled(_ event: ScrollEvent) -> Bool {
        let horizontal = event.modifiers.contains(.shift) || abs(event.dx) > abs(event.dy)
        let amount = horizontal ? (event.modifiers.contains(.shift) ? event.dy : event.dx) : event.dy
        let step = event.source == .wheel ? (event.notchesY != 0 || event.notchesX != 0 ? (horizontal ? (event.notchesX != 0 ? event.notchesX : event.notchesY) : event.notchesY) * rowPitch : amount) : amount
        if horizontal {
            scrollX.reset(max(scrollX.value + step, 0))
        } else {
            scrollY.reset(clampY(scrollY.value + step))
        }
        hovered = nil
        reportVisibleRows()
        setNeedsDisplay()
        return true
    }

    public override func pointerMoved(to point: Point) {
        let hit = self.hit(point)
        if hit?.row != hovered?.row || hit?.cell != hovered?.cell {
            hovered = hit
            setNeedsDisplay()
        }
    }

    public override func pointerExited() {
        hovered = nil
        setNeedsDisplay()
    }

    public override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard let hit = hit(point) else { return false }
        let wasFocused = isFocused && hit.row == cursorRow && (hit.cell == focusedCell || hit.cell == nil && point.x < gridLeft)
        cursorRow = hit.row
        if point.x >= gridLeft {
            let time = date(atX: point.x)
            if let index = hit.cell, let cell = rows[hit.row].cells?[index] {
                cursorTime = max(cell.start, origin).addingTimeInterval(1)
            } else {
                cursorTime = max(time, origin)
            }
        } else {
            cursorTime = max(now, origin)
        }
        window?.focus.focus(self, animated: true, reveal: false)
        focusMoved()
        switch button {
        case .primary:
            if point.x < gridLeft {
                onPlay?(rows[hit.row])
            } else if wasFocused {
                activate()
            }
        case .secondary:
            onContextMenu?(rows[hit.row], focused?.cell, transformToWindow.apply(point))
        case .middle:
            onPlay?(rows[hit.row])
        default:
            return false
        }
        return true
    }

    /// The row and airing under `point`.
    private func hit(_ point: Point) -> (row: Int, cell: Int?)? {
        guard point.y >= headerHeight else { return nil }
        let index = Int(((point.y - headerHeight + scrollY.value) / rowPitch).rounded(.down))
        guard rows.indices.contains(index) else { return nil }
        guard point.x >= gridLeft else { return (index, nil) }
        let time = date(atX: point.x)
        let cell = rows[index].cells?.firstIndex { $0.start <= time && time < $0.end }
        return (index, cell)
    }

    public override func focusDidChange(focused: Bool, animated: Bool) {
        if focused { focusMoved() } else { setNeedsDisplay() }
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        var moving = scrollY.advance(dt)
        moving = scrollX.advance(dt) || moving
        moving = lift.advance(dt) || moving
        for slot in logos.values { moving = slot.advance(dt) || moving }
        if moving { reportVisibleRows() }
        setNeedsDisplay()
        return moving
    }

    public override func layoutSubviews() {
        layoutCache.removeAll()
        clampScroll(animated: false)
        reportVisibleRows()
    }

    private func reportVisibleRows() {
        let ids = visibleRange.map { rows[$0].id }
        guard ids != lastVisible else { return }
        lastVisible = ids
        onVisibleRows?(ids)
    }

    // MARK: Drawing

    private var focusedRect: Rect? {
        guard rows.indices.contains(cursorRow) else { return nil }
        let y = y(ofRow: cursorRow)
        if let index = focusedCell, let cell = rows[cursorRow].cells?[index] {
            let left = max(x(of: cell.start), gridLeft)
            return Rect(x: left, y: y, width: max(x(of: cell.end) - left - metrics.tv(6), metrics.tv(40)), height: rowHeight)
        }
        return Rect(x: gridLeft, y: y, width: gridWidth, height: rowHeight)
    }

    private func layout(_ key: String, _ text: String, font: Font, width: Float) -> TextLayout? {
        guard width > metrics.tv(24), let scale = window?.scale else { return nil }
        let cacheKey = "\(key)|\(Int(width))|\(font.size)|\(font.weight.rawValue)"
        if let cached = layoutCache[cacheKey] { return cached }
        let made = TextLayout(text, font: font, maxWidth: width, maxLines: 1, scale: scale)
        layoutCache[cacheKey] = made
        return made
    }

    public override func draw(_ context: inout DrawContext) {
        let theme = Theme.current
        let palette = theme.palette
        let range = visibleRange
        let showsFocus = isFocused
        context.clipped(to: Rect(x: 0, y: headerHeight, width: bounds.width, height: bounds.height - headerHeight)) { inner in
            for index in range { drawRow(index, in: &inner, showsFocus: showsFocus) }
        }
        drawHeader(&context)
        let nowX = x(of: now)
        if nowX >= gridLeft, nowX <= bounds.width {
            let lineWidth = metrics.tv(3)
            context.fill(Rect(x: nowX - lineWidth / 2, y: headerHeight - metrics.tv(10), width: lineWidth, height: bounds.height - headerHeight + metrics.tv(10)),
                         radius: lineWidth / 2, color: palette.accent.withSRGBAlpha(0.85))
            let dot = metrics.tv(14)
            context.fill(Rect(x: nowX - dot / 2, y: headerHeight - metrics.tv(10) - dot / 2, width: dot, height: dot), radius: dot / 2, color: palette.accent)
        }
    }

    private func drawHeader(_ context: inout DrawContext) {
        let theme = Theme.current
        let palette = theme.palette
        let slot: TimeInterval = 1800
        let first = Date(timeIntervalSince1970: (date(atX: gridLeft).timeIntervalSince1970 / slot).rounded(.down) * slot)
        var mark = first
        context.clipped(to: Rect(x: gridLeft, y: 0, width: gridWidth, height: headerHeight)) { inner in
            while x(of: mark) < bounds.width {
                let left = x(of: mark)
                let text = timeLabel(mark)
                if let label = layout("t\(mark.timeIntervalSince1970)", text, font: theme.type.caption1, width: metrics.tv(240)) {
                    inner.text(label, at: Point(x: (left + metrics.tv(12)).rounded(), y: ((headerHeight - label.size.height) / 2).rounded()),
                               color: palette.labelSecondary)
                }
                inner.fill(Rect(x: left, y: headerHeight * 0.3, width: metrics.tv(2), height: headerHeight * 0.4), color: palette.separator)
                mark = mark.addingTimeInterval(slot)
            }
        }
    }

    private func drawRow(_ index: Int, in context: inout DrawContext, showsFocus: Bool) {
        let theme = Theme.current
        let palette = theme.palette
        let row = rows[index]
        let y = y(ofRow: index)
        let isCursorRow = index == cursorRow
        let radius = metrics.radiusS
        let channelRect = Rect(x: 0, y: y, width: channelWidth, height: rowHeight)
        let rowFocused = showsFocus && isCursorRow
        context.fill(channelRect, radius: radius, color: rowFocused ? palette.surfaceHigh : palette.surface)
        let well = rowHeight - metrics.tv(24)
        let logoRect = Rect(x: metrics.tv(14), y: y + (rowHeight - well) / 2, width: well * 1.5, height: well)
        context.fill(logoRect, radius: metrics.radiusXS, color: palette.surfaceRaised)
        if let logo = row.logo, let scale = window?.scale {
            let slot = logos[row.id] ?? ArtworkSlot(owner: self)
            logos[row.id] = slot
            slot.show(logo, pixelWidth: Int(logoRect.width * scale), pixelHeight: Int(logoRect.height * scale), redraw: false)
            if let texture = slot.texture {
                context.image(texture, in: logoRect.insetBy(metrics.tv(6), metrics.tv(6)), radius: 0, opacity: slot.opacity, fit: true)
            }
        }
        let textLeft = logoRect.maxX + metrics.tv(16)
        let textWidth = channelWidth - textLeft - metrics.tv(14)
        var textY = y + metrics.tv(14)
        if let number = row.number, let label = layout("n\(row.id)", number, font: theme.type.caption2, width: textWidth) {
            context.text(label, at: Point(x: textLeft, y: textY.rounded()), color: palette.accentText)
            textY += label.size.height + metrics.tv(2)
        }
        if let name = layout("c\(row.id)", row.title, font: theme.type.cardTitle, width: textWidth - (row.isFavorite ? metrics.tv(34) : 0)) {
            let centered = row.number == nil ? y + (rowHeight - name.size.height) / 2 : textY
            context.text(name, at: Point(x: textLeft, y: centered.rounded()), color: palette.label)
            if row.isFavorite {
                let side = metrics.tv(24)
                context.symbol("star.fill", in: Rect(x: textLeft + name.size.width + metrics.tv(8), y: centered + (name.size.height - side) / 2, width: side, height: side),
                               color: palette.accent)
            }
        }
        context.clipped(to: Rect(x: gridLeft, y: y - metrics.tv(8), width: gridWidth, height: rowHeight + metrics.tv(16))) { inner in
            guard let cells = row.cells else {
                drawPlaceholder(loadingText, y: y, in: &inner, focused: rowFocused)
                return
            }
            let firstVisible = date(atX: gridLeft)
            let lastVisible = date(atX: bounds.width)
            var drewAny = false
            for (cellIndex, cell) in cells.enumerated() where cell.end > firstVisible && cell.start < lastVisible {
                drewAny = true
                let focusedHere = rowFocused && focusedCell == cellIndex
                let hoveredHere = hovered?.row == index && hovered?.cell == cellIndex
                drawCell(cell, rowID: row.id, y: y, in: &inner, focused: focusedHere, hovered: hoveredHere)
            }
            if !drewAny { drawPlaceholder(emptyText, y: y, in: &inner, focused: rowFocused) }
            if rowFocused, focusedCell == nil, drewAny {
                let rect = Rect(x: max(x(of: cursorTime) - metrics.tv(4), gridLeft), y: y, width: metrics.tv(8), height: rowHeight)
                inner.fill(rect, radius: metrics.tv(4), color: palette.focusFill)
            }
        }
    }

    private func drawPlaceholder(_ text: String, y: Float, in context: inout DrawContext, focused: Bool) {
        let palette = Theme.current.palette
        let rect = Rect(x: gridLeft, y: y, width: gridWidth - metrics.tv(6), height: rowHeight)
        context.fill(rect, radius: metrics.radiusS, color: focused ? palette.focusFill : palette.surface.withSRGBAlpha(0.6))
        if let label = layout("p\(text)", text, font: Theme.current.type.cardSubtitle, width: rect.width - metrics.tv(40)) {
            context.text(label, at: Point(x: rect.minX + metrics.tv(20), y: (y + (rowHeight - label.size.height) / 2).rounded()),
                         color: focused ? palette.onFocusFillSecondary : palette.labelTertiary)
        }
    }

    private func drawCell(_ cell: GuideCell, rowID: String, y: Float, in context: inout DrawContext, focused: Bool, hovered: Bool) {
        let theme = Theme.current
        let palette = theme.palette
        let left = x(of: cell.start)
        let right = x(of: cell.end) - metrics.tv(6)
        guard right > left + metrics.tv(4) else { return }
        var rect = Rect(x: left, y: y, width: right - left, height: rowHeight)
        let isOn = cell.start <= now && now < cell.end
        let isPast = cell.end <= now
        if focused {
            let grow = metrics.tv(6) * lift.value
            rect = rect.insetBy(-grow, -grow)
            context.shadow(rect, radius: metrics.radiusS, blur: metrics.tv(18), offsetY: metrics.tv(8), opacity: 0.4 * lift.value)
        }
        let fill: Color = focused ? palette.focusFill : (hovered ? palette.surfaceHigh : (isOn ? palette.surfaceRaised : palette.surface))
        context.fill(rect, radius: metrics.radiusS, color: isPast && !focused ? fill.withSRGBAlpha(0.55) : fill)
        if isOn {
            let progress = Float(now.timeIntervalSince(cell.start) / cell.end.timeIntervalSince(cell.start))
            let bar = Rect(x: rect.minX + metrics.tv(12), y: rect.maxY - metrics.tv(12), width: max((rect.width - metrics.tv(24)) * progress, 0), height: metrics.tv(5))
            context.fill(Rect(x: bar.minX, y: bar.minY, width: rect.width - metrics.tv(24), height: bar.height), radius: bar.height / 2,
                         color: (focused ? palette.onFocusFill : palette.label).withSRGBAlpha(0.18))
            context.fill(bar, radius: bar.height / 2, color: focused ? palette.onFocusFill : palette.accent)
        }
        let textLeft = max(rect.minX, gridLeft) + metrics.tv(16)
        let textWidth = rect.maxX - textLeft - metrics.tv(12)
        var badges: [String] = []
        if cell.isRecording { badges.append("●") }
        let title = badges.isEmpty ? cell.title : "\(badges.joined()) \(cell.title)"
        let ink = focused ? palette.onFocusFill : palette.label
        let inkSecondary = focused ? palette.onFocusFillSecondary : palette.labelSecondary
        if let label = layout("a\(rowID)\(cell.id)\(cell.isRecording)", title, font: theme.type.cardTitle, width: textWidth) {
            context.text(label, at: Point(x: textLeft.rounded(), y: (y + metrics.tv(14)).rounded()), color: cell.isRecording && !focused ? palette.destructive : ink)
        }
        let detail = cell.detail ?? "\(timeLabel(cell.start)) – \(timeLabel(cell.end))"
        if let label = layout("d\(rowID)\(cell.id)", detail, font: theme.type.cardSubtitle, width: textWidth) {
            context.text(label, at: Point(x: textLeft.rounded(), y: (y + rowHeight - metrics.tv(22) - label.size.height).rounded()), color: inkSecondary)
        }
    }
}

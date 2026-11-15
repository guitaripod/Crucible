import Foundation
import Kiln

/// Cells of many tints drawn as one mask per colour: each cell's alpha becomes its coverage, so a heat map of hundreds of
/// squares costs a handful of draws and rasterises only when it changes.
@MainActor
enum TintedCells {
    static func draw(_ cells: [(rect: Rect, color: Color)], radius: Float, in box: Rect, context: inout DrawContext) {
        var groups: [Color: Path] = [:]
        var order: [Color] = []
        for cell in cells {
            let base = cell.color.withAlpha(1)
            if groups[base] == nil {
                groups[base] = Path()
                order.append(base)
            }
            groups[base]?.roundedRect(cell.rect, radius: radius)
            groups[base]?.fill(coverage: cell.color.alpha)
        }
        for base in order {
            guard let path = groups[base] else { continue }
            context.shape(path, in: box, color: base)
        }
    }
}

/// A KPI tile (`StatTileView`), the content of a flush `StatsPanelView`: a symbol-led caption on top, the bold value at the
/// bottom left with an inline suffix ("days · best 31"), and an ember sparkline at the bottom right that draws itself in.
@MainActor
public final class StatTileView: View {
    private var title = ""
    private var value = ""
    private var symbol: Symbol = "chart.bar"
    private var caption: String?
    private var sparkline: [Int] = []
    private var drawIn = Animated(1)

    public func configure(title: String, value: String, symbol: Symbol, caption: String?, sparkline: [Int], animate: Bool) {
        self.title = title
        self.value = value
        self.symbol = symbol
        self.caption = caption
        self.sparkline = sparkline
        if animate && hasSparkline {
            drawIn.reset(0)
            drawIn.set(1, animation: .timed(duration: 0.8, curve: .easeInOut))
            startAnimating()
        } else {
            drawIn.reset(1)
        }
        setNeedsDisplay()
    }

    private var metrics: Metrics { Theme.current.metrics }
    private var hasSparkline: Bool { sparkline.count >= 2 && sparkline.contains { $0 != 0 } }
    private var sparkSize: Size { Size(width: metrics.tv(140), height: metrics.tv(56)) }

    private func titleLayout(width: Float) -> TextLayout {
        var font = Theme.current.type.caption2
        font.letterSpacing = 0.9
        return TextLayout(title.uppercased(), font: font, maxWidth: width, maxLines: 2, scale: window?.scale ?? 1)
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        let inner = size.width - metrics.tv(32) * 2 - metrics.tv(26) - metrics.tv(12)
        let height = metrics.tv(28) * 2 + titleLayout(width: inner).size.height + metrics.tv(24) + metrics.tv(86)
        return Size(width: size.width, height: max(metrics.tv(190), height))
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = drawIn.advance(dt)
        setNeedsDisplay()
        return moving
    }

    public override func draw(_ context: inout DrawContext) {
        let palette = Theme.current.palette
        let scale = window?.scale ?? 1
        let insetX = metrics.tv(32)
        let insetY = metrics.tv(28)
        let glyph = metrics.tv(26)
        let titleWidth = frame.width - insetX * 2 - glyph - metrics.tv(12)
        let titleText = titleLayout(width: titleWidth)
        let captionHeight = max(glyph, titleText.size.height)
        context.symbol(symbol, in: Rect(x: insetX, y: insetY + ((captionHeight - glyph) / 2).rounded(), width: glyph, height: glyph), color: palette.labelTertiary)
        context.text(titleText, at: Point(x: insetX + glyph + metrics.tv(12), y: insetY + ((captionHeight - titleText.size.height) / 2).rounded()), color: palette.labelTertiary)

        let sparkWidth = hasSparkline ? sparkSize.width + metrics.tv(12) : 0
        let room = frame.width - insetX * 2 - sparkWidth
        var valueFont = Font(size: metrics.tv(72), weight: .bold)
        var valueText = TextLayout(value, font: valueFont, scale: scale)
        if valueText.size.width > room * 0.75 {
            valueFont.size = max(valueFont.size * 0.6, valueFont.size * room * 0.75 / max(valueText.size.width, 1))
            valueText = TextLayout(value, font: valueFont, scale: scale)
        }
        let bottom = frame.height - insetY
        let baseline = bottom - (valueText.size.height - valueText.baseline)
        context.text(valueText, at: Point(x: insetX, y: baseline - valueText.baseline), color: palette.label)
        if let caption, !caption.isEmpty {
            let x = insetX + valueText.size.width + metrics.tv(12)
            let suffix = TextLayout(caption, font: Theme.current.type.subheadline, maxWidth: max(room - (x - insetX), 1), scale: scale)
            context.text(suffix, at: Point(x: x, y: baseline - suffix.baseline), color: palette.labelSecondary)
        }
        if hasSparkline {
            let box = Rect(x: frame.width - insetX - sparkSize.width, y: bottom - sparkSize.height, width: sparkSize.width, height: sparkSize.height)
            let reveal = Rect(x: box.minX - metrics.tv(4), y: box.minY - metrics.tv(4), width: (box.width + metrics.tv(8)) * drawIn.value, height: box.height + metrics.tv(8))
            context.clipped(to: reveal) { inner in
                inner.shape(sparklinePath(in: box.size), in: box, color: StatsStyle.accent)
            }
        }
    }

    private func sparklinePath(in size: Size) -> Path {
        let lineWidth = metrics.tv(4)
        let rect = Rect(x: lineWidth / 2, y: lineWidth / 2, width: size.width - lineWidth, height: size.height - lineWidth)
        let low = sparkline.min() ?? 0
        let span = Float((sparkline.max() ?? 0) - low)
        var path = Path()
        for (index, value) in sparkline.enumerated() {
            let normalized = span == 0 ? 0.5 : Float(value - low) / span
            let point = Point(x: rect.minX + rect.width * Float(index) / Float(sparkline.count - 1), y: rect.maxY - rect.height * normalized)
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.stroke(width: lineWidth)
        return path
    }
}

/// The year's contribution calendar (`ContributionHeatmapView`): seven rows (Sunday on top) by one column per week, month
/// names above, the most recent week at the right edge; older weeks fall off the left when the card is narrower.
@MainActor
public final class ContributionHeatmapView: View {
    public struct Cell: Sendable {
        public var column: Int
        public var row: Int
        public var level: Int

        public init(column: Int, row: Int, level: Int) {
            self.column = column
            self.row = row
            self.level = level
        }
    }

    private var columns = 0
    private var lastDayIndex = 0
    private var cells: [Cell] = []
    private var monthLabels: [(column: Int, text: String)] = []
    private var reveal = Animated(1)

    /// `lastDayIndex` is the last drawn day counted from the first column's Sunday; days after it stay empty.
    public func configure(columns: Int, lastDayIndex: Int, cells: [Cell], monthLabels: [(column: Int, text: String)], animate: Bool) {
        self.columns = columns
        self.lastDayIndex = lastDayIndex
        self.cells = cells
        self.monthLabels = monthLabels
        if animate {
            reveal.reset(0)
            reveal.set(1, animation: .timed(duration: 0.6, curve: .easeInOut))
            startAnimating()
        }
        setNeedsDisplay()
    }

    private var metrics: Metrics { Theme.current.metrics }
    private var labelHeight: Float { metrics.tv(36) }

    /// The distance from one cell to the next across `width`: the Apple TV's 30 points, grown to fill a wider card (up to
    /// twice as big) and never shrunk; a narrower card shows the latest weeks.
    private func step(for width: Float) -> Float {
        let natural = metrics.tv(30)
        guard columns > 0 else { return natural }
        let fitted = (width + natural * 0.2) / Float(columns)
        return fitted > natural ? min(fitted, natural * 2) : natural
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: labelHeight + 7 * step(for: size.width))
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = reveal.advance(dt)
        setNeedsDisplay()
        return moving
    }

    public override func draw(_ context: inout DrawContext) {
        guard columns > 0 else { return }
        let step = step(for: frame.width)
        let gap = step * 0.2
        let contentWidth = Float(columns) * step - gap
        let overflow = max(0, contentWidth - frame.width)
        let offset = -overflow * reveal.value
        let box = Rect(x: offset, y: 0, width: contentWidth, height: frame.height)
        var occupied = Set<Int>()
        var tinted: [(rect: Rect, color: Color)] = []
        for cell in cells where cell.column >= 0 && cell.column < columns && cell.row >= 0 && cell.row < 7 {
            guard cell.column * 7 + cell.row <= lastDayIndex else { continue }
            occupied.insert(cell.column * 7 + cell.row)
            tinted.append((rect(column: cell.column, row: cell.row, step: step), StatsStyle.heat(cell.level)))
        }
        var empty: [(rect: Rect, color: Color)] = []
        for column in 0..<columns {
            for row in 0..<7 where column * 7 + row <= lastDayIndex && !occupied.contains(column * 7 + row) {
                empty.append((rect(column: column, row: row, step: step), StatsStyle.heat(0)))
            }
        }
        context.clipped(to: bounds) { inner in
            inner.faded(0.25 + 0.75 * reveal.value) { faded in
                TintedCells.draw(empty + tinted, radius: step * 5 / 30, in: box, context: &faded)
                let font = Font(size: metrics.tv(23), weight: .regular)
                let scale = window?.scale ?? 1
                for (column, text) in monthLabels where column >= 0 && column < columns {
                    let layout = TextLayout(text, font: font, scale: scale)
                    let x = min(Float(column) * step, contentWidth - layout.size.width) + offset
                    faded.text(layout, at: Point(x: x, y: ((labelHeight - layout.size.height) / 2).rounded()), color: Theme.current.palette.labelTertiary)
                }
            }
        }
    }

    private func rect(column: Int, row: Int, step: Float) -> Rect {
        Rect(x: Float(column) * step, y: labelHeight + Float(row) * step, width: step * 0.8, height: step * 0.8)
    }
}

/// A 24-spoke clock of when plays start (`RadialClockView`): midnight at the top, hours running clockwise, each hour a
/// tapered bar from the hub scaled to the busiest hour, which glows. The bars grow out when it first shows.
@MainActor
public final class RadialClockView: View {
    private var counts = [Int](repeating: 0, count: 24)
    private var grow = Animated(1)

    public func configure(hours: [Int], animate: Bool) {
        counts = (0..<24).map { $0 < hours.count ? max(0, hours[$0]) : 0 }
        if animate && (counts.max() ?? 0) > 0 {
            grow.reset(0)
            grow.set(1, animation: .timed(duration: 0.55, curve: .linear))
            startAnimating()
        } else {
            grow.reset(1)
        }
        setNeedsDisplay()
    }

    public static var side: Float { Theme.current.metrics.tv(440) }

    public override func sizeThatFits(_ size: Size) -> Size { Size(width: Self.side, height: Self.side) }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = grow.advance(dt)
        setNeedsDisplay()
        return moving
    }

    public override func draw(_ context: inout DrawContext) {
        let metrics = Theme.current.metrics
        let palette = Theme.current.palette
        let center = Point(x: frame.width / 2, y: frame.height / 2)
        let radius = min(frame.width, frame.height) / 2 - metrics.tv(12)
        guard radius > 0 else { return }
        let inner = radius * 0.32
        let outer = radius * 0.95
        let hairline = metrics.tv(2)
        let step = 2 * Float.pi / 24
        let isDark = palette.appearance == .dark

        context.fill(Rect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2), radius: inner, color: palette.surfaceRaised)
        var rings = Path()
        rings.ellipse(in: Rect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
        rings.stroke(width: hairline, coverage: StatsStyle.coverage(isDark ? 0.16 : 0.14, of: palette.label))
        rings.ellipse(in: Rect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
        rings.stroke(width: hairline, coverage: StatsStyle.coverage(isDark ? 0.06 : 0.05, of: palette.label))
        var ticks = Path()
        var cardinals = Path()
        for hour in 0..<24 {
            let angle = Float(hour) * step
            let cardinal = hour % 6 == 0
            let length = radius * (cardinal ? 0.055 : 0.03)
            let start = point(center, radius: inner - radius * 0.015, angle: angle)
            let end = point(center, radius: inner - radius * 0.015 - length, angle: angle)
            if cardinal {
                cardinals.move(to: start)
                cardinals.line(to: end)
            } else {
                ticks.move(to: start)
                ticks.line(to: end)
            }
        }
        ticks.stroke(width: hairline, coverage: StatsStyle.coverage(0.22, of: palette.label))
        for part in [rings, ticks] { context.shape(part, in: bounds, color: palette.label) }
        cardinals.stroke(width: hairline * 1.5, coverage: StatsStyle.coverage(0.55, of: StatsStyle.accent))
        let dot = max(1.5, radius * 0.012)
        cardinals.ellipse(in: Rect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2))
        cardinals.fill(coverage: StatsStyle.coverage(0.7, of: StatsStyle.accent))
        context.shape(cardinals, in: bounds, color: StatsStyle.accent)

        let busiest = counts.max() ?? 0
        guard busiest > 0 else { return }
        let progress = StatsStyle.easeOut(grow.value)
        let span = outer - inner
        let base = max(1.5, radius * 0.026)
        let tip = max(1, radius * 0.015)
        var bars = Path()
        var peak = Path()
        var peakTip: Point?
        for hour in 0..<24 where counts[hour] > 0 {
            let fraction = Float(counts[hour]) / Float(busiest)
            let length = max(radius * 0.03, span * fraction) * progress
            guard length > 0 else { continue }
            let angle = Float(hour) * step
            if counts[hour] == busiest {
                addBar(to: &peak, center: center, angle: angle, from: inner, to: inner + length, base: base, tip: tip)
                peak.fill()
                peakTip = point(center, radius: inner + length * 0.6, angle: angle)
            } else {
                addBar(to: &bars, center: center, angle: angle, from: inner, to: inner + length, base: base, tip: tip)
                bars.fill(coverage: StatsStyle.coverage(0.35 + 0.45 * fraction, of: StatsStyle.accent))
            }
        }
        if let peakTip {
            context.glow(in: bounds, radius: 0, center: peakTip, glowRadius: radius * 0.22, color: StatsStyle.accentBright.withSRGBAlpha(0.35 * progress))
        }
        context.shape(bars, in: bounds, color: StatsStyle.accent)
        context.shape(peak, in: bounds, color: StatsStyle.accentBright)
    }

    /// A tapered bar along `angle` from `start` to `end` from the centre, round at both ends.
    private func addBar(to path: inout Path, center: Point, angle: Float, from start: Float, to end: Float, base: Float, tip: Float) {
        let direction = Point(x: sin(angle), y: -cos(angle))
        let normal = Point(x: cos(angle), y: sin(angle))
        func at(_ distance: Float, _ offset: Float) -> Point {
            Point(x: center.x + direction.x * distance + normal.x * offset, y: center.y + direction.y * distance + normal.y * offset)
        }
        let heading = angle - .pi / 2
        path.move(to: at(start, base))
        path.line(to: at(end, tip))
        path.arc(center: at(end, 0), radius: tip, from: heading + .pi / 2, to: heading - .pi / 2, clockwise: false)
        path.line(to: at(start, -base))
        path.arc(center: at(start, 0), radius: base, from: heading - .pi / 2, to: heading - 3 * .pi / 2, clockwise: false)
        path.close()
    }

    private func point(_ center: Point, radius: Float, angle: Float) -> Point {
        Point(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle))
    }
}

/// Plays by weekday (`WeekdayColumnChartView`): seven bars from Sunday with faint backing columns, the weekend in the
/// bright accent, a count above each bar and the day's initial below; the bars grow up one after another.
@MainActor
public final class WeekdayChartView: View {
    private var values: [Int] = []
    private var initials: [String] = []
    private var counts: [String] = []
    private var grow = Animated(1)

    /// `values`, `initials` and `counts` (the label above each bar) run Sunday to Saturday.
    public func configure(values: [Int], initials: [String], counts: [String], animate: Bool) {
        guard values.count == 7, initials.count == 7, counts.count == 7 else {
            self.values = []
            setNeedsDisplay()
            return
        }
        self.values = values
        self.initials = initials
        self.counts = counts
        if animate {
            grow.reset(0)
            grow.set(1, animation: .timed(duration: 0.55 + 6 * 0.045 + 0.15, curve: .linear))
            startAnimating()
        } else {
            grow.reset(1)
        }
        setNeedsDisplay()
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: Theme.current.metrics.tv(340))
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = grow.advance(dt)
        setNeedsDisplay()
        return moving
    }

    public override func draw(_ context: inout DrawContext) {
        guard values.count == 7 else { return }
        let metrics = Theme.current.metrics
        let palette = Theme.current.palette
        let scale = window?.scale ?? 1
        let labelRow = metrics.tv(40)
        let valueRow = metrics.tv(32)
        let baseline = frame.height - labelRow
        let plot = max(0, baseline - valueRow)
        let slot = frame.width / 7
        let barWidth = min(metrics.tv(72), max(metrics.tv(12), slot * 0.58))
        let corner = min(metrics.tv(12), barWidth / 2)
        let busiest = values.max() ?? 0
        let total = 0.55 + 6 * 0.045 + 0.15
        let elapsed = grow.value * Float(total)
        let dayFont = Font(size: metrics.tv(25), weight: .medium)
        let countFont = Font(size: metrics.tv(23), weight: .semibold)
        for day in 0..<7 {
            let centerX = slot * Float(day) + slot / 2
            let x = (centerX - barWidth / 2).rounded()
            topRounded(Rect(x: x, y: baseline - plot, width: barWidth, height: plot), corner: corner, color: palette.surfaceRaised, in: &context)
            let local = StatsStyle.easeOut((elapsed - Float(day) * 0.045) / 0.55)
            var height: Float = 0
            if busiest > 0 {
                height = plot * Float(values[day]) / Float(busiest)
                if values[day] > 0 { height = max(height, metrics.tv(4)) }
            }
            height *= local
            if height > 0 {
                let color = day == 0 || day == 6 ? StatsStyle.accentBright : StatsStyle.accent.withSRGBAlpha(0.7)
                topRounded(Rect(x: x, y: baseline - height, width: barWidth, height: height), corner: min(corner, height / 2), color: color, in: &context)
            }
            let initial = TextLayout(initials[day], font: dayFont, scale: scale)
            context.text(initial, at: Point(x: (centerX - initial.size.width / 2).rounded(), y: baseline + metrics.tv(6) + ((labelRow - metrics.tv(6) - initial.size.height) / 2).rounded()),
                         color: palette.labelSecondary)
            if values[day] > 0 {
                let count = TextLayout(counts[day], font: countFont, scale: scale)
                let fade = min(1, max(0, (elapsed - Float(day) * 0.045 - 0.15) / 0.4))
                if count.size.width + 2 <= slot, fade > 0 {
                    context.faded(fade) { faded in
                        faded.text(count, at: Point(x: (centerX - count.size.width / 2).rounded(), y: max(0, baseline - height - valueRow - 1 + ((valueRow - count.size.height) / 2).rounded())),
                                   color: palette.labelSecondary)
                    }
                }
            }
        }
        context.fill(Rect(x: 0, y: baseline.rounded(), width: frame.width, height: metrics.tv(2)), color: palette.separator.withSRGBAlpha(0.6))
    }

    /// A bar rounded at the top only: the rounded rectangle's top band, then a plain rectangle below it, meeting on a whole
    /// pixel so a translucent colour never covers any pixel twice.
    private func topRounded(_ rect: Rect, corner: Float, color: Color, in context: inout DrawContext) {
        guard rect.height > 0 else { return }
        let seam = min(rect.maxY, (rect.minY + corner).rounded(.up))
        context.clipped(to: Rect(x: rect.x - 1, y: rect.minY - 1, width: rect.width + 2, height: seam - rect.minY + 1)) { top in
            top.fill(Rect(x: rect.x, y: rect.minY, width: rect.width, height: max(rect.height, corner * 2)), radius: corner, color: color)
        }
        if rect.maxY > seam {
            context.fill(Rect(x: rect.x, y: seam, width: rect.width, height: rect.maxY - seam), color: color)
        }
    }
}

/// Plays over the range as a smoothed line over a wash (`TrendAreaView` with axes): the peak marked with a dot and its
/// annotation. The line draws in from the left, the wash fades in and the dot pops once the line reaches past half way.
@MainActor
public final class TrendAreaView: View {
    private var values: [Double] = []
    private var peakText: String?
    private var drawIn = Animated(1)

    public func configure(values: [Double], peakText: String?, animate: Bool) {
        self.values = values
        self.peakText = peakText
        if animate {
            drawIn.reset(0)
            drawIn.set(1, animation: .timed(duration: 1.25, curve: .linear))
            startAnimating()
        } else {
            drawIn.reset(1)
        }
        setNeedsDisplay()
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: Theme.current.metrics.tv(360))
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = drawIn.advance(dt)
        setNeedsDisplay()
        return moving
    }

    public override func draw(_ context: inout DrawContext) {
        guard !values.isEmpty else { return }
        let metrics = Theme.current.metrics
        let palette = Theme.current.palette
        let lineWidth = metrics.tv(5)
        let plot = Rect(x: metrics.tv(12), y: metrics.tv(44), width: max(0, frame.width - metrics.tv(24)), height: max(0, frame.height - metrics.tv(60)))
        guard plot.width > 0, plot.height > 0 else { return }
        let points = self.points(in: plot)
        let peak = points.peak
        let elapsed = drawIn.value * 1.25
        let line = curve(through: points.line, clamp: plot.minY...plot.maxY)
        var wash = line
        wash.line(to: Point(x: points.line[points.line.count - 1].x, y: plot.maxY))
        wash.line(to: Point(x: points.line[0].x, y: plot.maxY))
        wash.close()
        wash.fillRamp(fromY: plot.minY, coverage: StatsStyle.coverage(0.35, of: StatsStyle.accent), toY: plot.maxY, toCoverage: 0)
        context.faded(min(1, elapsed / 0.9)) { faded in
            faded.shape(wash, in: bounds, color: StatsStyle.accent)
        }
        var stroke = line
        stroke.stroke(width: lineWidth)
        let reveal = easeInOut(min(1, elapsed / 0.9))
        context.clipped(to: Rect(x: 0, y: 0, width: plot.minX + (plot.width + lineWidth) * reveal, height: frame.height)) { inner in
            inner.shape(stroke, in: bounds, color: StatsStyle.accent)
        }
        let pop = min(1, max(0, (elapsed - 0.5) / 0.35))
        guard pop > 0 else { return }
        let dot = metrics.tv(9) * (0.3 + 0.7 * StatsStyle.easeOut(pop))
        let dotRect = Rect(x: peak.x - dot, y: peak.y - dot, width: dot * 2, height: dot * 2)
        context.faded(pop) { faded in
            faded.shadow(dotRect, radius: dot, blur: metrics.tv(6), offsetY: 1, opacity: 0.5, color: StatsStyle.accent)
            faded.fill(dotRect, radius: dot, color: StatsStyle.accent)
            faded.stroke(dotRect, radius: dot, width: metrics.tv(3), color: palette.surface)
            guard let peakText, !peakText.isEmpty else { return }
            let label = TextLayout(peakText, font: Font(size: metrics.tv(25), weight: .semibold), scale: window?.scale ?? 1)
            let margin = metrics.tv(4)
            let half = label.size.width / 2
            let centerX = min(max(half + margin, peak.x), max(half + margin, frame.width - half - margin))
            var top = peak.y - metrics.tv(9) - metrics.tv(8) - label.size.height
            if top < 0 { top = peak.y + metrics.tv(9) + metrics.tv(8) }
            faded.text(label, at: Point(x: (centerX - half).rounded(), y: top.rounded()), color: palette.label)
        }
    }

    private func points(in rect: Rect) -> (line: [Point], peak: Point) {
        let highest = values.max() ?? 0
        func y(_ value: Double) -> Float {
            guard highest > 0 else { return rect.maxY }
            return rect.maxY - rect.height * Float(min(1, max(0, value / highest)))
        }
        if values.count == 1 {
            let level = y(values[0])
            return ([Point(x: rect.minX, y: level), Point(x: rect.maxX, y: level)], Point(x: rect.midX, y: level))
        }
        let step = rect.width / Float(values.count - 1)
        let line = values.enumerated().map { Point(x: rect.minX + step * Float($0.offset), y: y($0.element)) }
        let peakIndex = values.enumerated().max { $0.element < $1.element }?.offset ?? 0
        return (line, line[peakIndex])
    }

    /// A Catmull-Rom curve through `points` with its control points kept inside the plot.
    private func curve(through points: [Point], clamp: ClosedRange<Float>) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count >= 3 else {
            points.dropFirst().forEach { path.line(to: $0) }
            return path
        }
        for index in 0..<(points.count - 1) {
            let p0 = points[max(index - 1, 0)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(index + 2, points.count - 1)]
            let c1 = Point(x: p1.x + (p2.x - p0.x) / 6, y: min(clamp.upperBound, max(clamp.lowerBound, p1.y + (p2.y - p0.y) / 6)))
            let c2 = Point(x: p2.x - (p3.x - p1.x) / 6, y: min(clamp.upperBound, max(clamp.lowerBound, p2.y - (p3.y - p1.y) / 6)))
            path.curve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    private func easeInOut(_ t: Float) -> Float {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}

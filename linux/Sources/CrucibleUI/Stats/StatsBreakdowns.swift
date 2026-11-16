import Foundation
import Kiln

/// Plays by library (`DonutChartView` with its legend): a ring of slices in the orange family with a gap between them, the
/// figure and its caption in the hole, and beside it a row per library with its colour, title, value and share. The slices
/// sweep in one after another and the centre fades in half way.
@MainActor
public final class LibrariesBreakdownView: View {
    public struct Slice: Sendable {
        public var title: String
        public var value: Int
        public var valueText: String
        public var colorIndex: Int
        /// Whether the slice has a row beside the ring; past the first few libraries it is only an arc, so the ring and the
        /// shares still add up to the total in the hole.
        public var isListed: Bool

        public init(title: String, value: Int, valueText: String, colorIndex: Int, isListed: Bool = true) {
            self.title = title
            self.value = value
            self.valueText = valueText
            self.colorIndex = colorIndex
            self.isListed = isListed
        }
    }

    private var slices: [Slice] = []
    private var listed: [Slice] { slices.filter(\.isListed) }
    private var centerTitle = ""
    private var centerSubtitle = ""
    private var sweep = Animated(1)

    public func configure(slices: [Slice], centerTitle: String, centerSubtitle: String, animate: Bool) {
        self.slices = slices
        self.centerTitle = centerTitle
        self.centerSubtitle = centerSubtitle
        if animate && slices.contains(where: { $0.value > 0 }) {
            sweep.reset(0)
            sweep.set(1, animation: .timed(duration: 0.9, curve: .linear))
            startAnimating()
        } else {
            sweep.reset(1)
        }
        setNeedsLayout()
        setNeedsDisplay()
    }

    private var metrics: Metrics { Theme.current.metrics }
    private var side: Float { metrics.tv(440) }
    private var rowHeight: Float { max(metrics.tv(48), TextLayout("Ag", font: Theme.current.type.callout, scale: window?.scale ?? 1).size.height) }

    private var stacked: Bool { frame.width < side + metrics.tv(64) + metrics.tv(500) }

    public override func sizeThatFits(_ size: Size) -> Size {
        let rows = listed.count
        let legend = Float(rows) * rowHeight + Float(max(0, rows - 1)) * metrics.tv(24)
        let isStacked = size.width < side + metrics.tv(64) + metrics.tv(500)
        return Size(width: size.width, height: isStacked ? side + metrics.tv(40) + legend : max(side, legend))
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = sweep.advance(dt)
        setNeedsDisplay()
        return moving
    }

    public override func draw(_ context: inout DrawContext) {
        let palette = Theme.current.palette
        let ring = Rect(x: 0, y: stacked ? 0 : ((frame.height - side) / 2).rounded(), width: side, height: side)
        drawRing(in: ring, context: &context)
        let legendX = stacked ? Float(0) : side + metrics.tv(64)
        let legendWidth = min(frame.width - legendX, metrics.tv(880))
        let rows = listed
        let legendHeight = Float(rows.count) * rowHeight + Float(max(0, rows.count - 1)) * metrics.tv(24)
        var y = stacked ? side + metrics.tv(40) : ((frame.height - legendHeight) / 2).rounded()
        let total = max(1, slices.reduce(0) { $0 + $1.value })
        let scale = window?.scale ?? 1
        let type = Theme.current.type
        for slice in rows {
            let dot = metrics.tv(24)
            context.fill(Rect(x: legendX, y: y + ((rowHeight - dot) / 2).rounded(), width: dot, height: dot), radius: dot / 2, color: StatsStyle.categorical(slice.colorIndex))
            let share = Int((Double(slice.value) / Double(total) * 100).rounded())
            let percent = TextLayout(share == 0 ? "<1%" : "\(share)%", font: type.callout, scale: scale)
            let percentX = legendX + legendWidth - percent.size.width
            context.text(percent, at: Point(x: percentX, y: y + ((rowHeight - percent.size.height) / 2).rounded()), color: palette.labelTertiary)
            let value = TextLayout(slice.valueText, font: Font(size: metrics.tv(31), weight: .semibold), scale: scale)
            let valueX = legendX + legendWidth - metrics.tv(96) - metrics.tv(24) - value.size.width
            context.text(value, at: Point(x: valueX, y: y + ((rowHeight - value.size.height) / 2).rounded()), color: palette.labelSecondary)
            let titleX = legendX + dot + metrics.tv(24)
            let title = TextLayout(slice.title, font: type.callout, maxWidth: max(1, valueX - metrics.tv(24) - titleX), scale: scale)
            context.text(title, at: Point(x: titleX, y: y + ((rowHeight - title.size.height) / 2).rounded()), color: palette.label)
            y += rowHeight + metrics.tv(24)
        }
    }

    private func drawRing(in rect: Rect, context: inout DrawContext) {
        let palette = Theme.current.palette
        let outer = rect.width / 2 - metrics.tv(6)
        guard outer > 0 else { return }
        let radius = outer / (1 + 0.22 / 2)
        let lineWidth = 0.22 * radius
        let center = Point(x: rect.width / 2, y: rect.height / 2)
        var track = Path()
        track.arc(center: center, radius: radius, from: 0, to: 2 * .pi)
        track.stroke(width: lineWidth, round: false)
        context.shape(track, in: rect, color: StatsStyle.heat(0))
        let drawn = slices.filter { $0.value > 0 }
        let total = Float(drawn.reduce(0) { $0 + $1.value })
        if total > 0 {
            let gap: Float = drawn.count > 1 ? 2.2 * .pi / 180 : 0
            let start = -Float.pi / 2
            var cumulative: Float = 0
            for slice in drawn {
                let fraction = Float(slice.value) / total
                let local = min(1, max(0, (sweep.value - cumulative) / max(fraction, 0.06 / 0.9)))
                defer { cumulative += fraction }
                guard local > 0 else { continue }
                let from = start + 2 * .pi * cumulative + gap / 2
                let to = max(from, start + 2 * .pi * (cumulative + fraction) - gap / 2)
                var arc = Path()
                arc.arc(center: center, radius: radius, from: from, to: from + (to - from) * easeInOut(local))
                arc.stroke(width: lineWidth, round: false)
                context.shape(arc, in: rect, color: StatsStyle.categorical(slice.colorIndex))
            }
        }
        let fade = min(1, max(0, (sweep.value - 0.5) / 0.44))
        guard fade > 0 else { return }
        let scale = window?.scale ?? 1
        let hole = max(0, radius - lineWidth / 2) * 2 * 0.82
        var titleFont = Font(size: metrics.tv(62), weight: .bold)
        var title = TextLayout(centerTitle, font: titleFont, scale: scale)
        if title.size.width > hole {
            titleFont.size = max(titleFont.size * 0.5, titleFont.size * hole / max(title.size.width, 1))
            title = TextLayout(centerTitle, font: titleFont, scale: scale)
        }
        let subtitle = TextLayout(centerSubtitle, font: Font(size: metrics.tv(25), weight: .medium), maxWidth: hole, maxLines: 2, alignment: .center, scale: scale)
        let height = title.size.height + metrics.tv(4) + subtitle.size.height
        let top = rect.y + center.y - height / 2
        context.faded(fade) { faded in
            faded.text(title, at: Point(x: rect.x + center.x - title.size.width / 2, y: top.rounded()), color: palette.label)
            faded.text(subtitle, at: Point(x: rect.x + center.x - subtitle.size.width / 2, y: (top + title.size.height + metrics.tv(4)).rounded()),
                       color: palette.labelSecondary)
        }
    }

    private func easeInOut(_ t: Float) -> Float {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}

/// Top genres in two columns (`RankedRowView` rows): each a title with its play count and a bar measured against the
/// leader in the genre's colour; while the analysis runs, its line and progress bar instead.
@MainActor
public final class TasteView: View {
    public struct Row: Sendable {
        public var title: String
        public var valueText: String
        public var fraction: Double
        public var colorIndex: Int

        public init(title: String, valueText: String, fraction: Double, colorIndex: Int) {
            self.title = title
            self.valueText = valueText
            self.fraction = fraction
            self.colorIndex = colorIndex
        }
    }

    private var rows: [Row] = []
    private var pending: (title: String, fraction: Double)?

    public func show(rows: [Row]) {
        self.rows = rows
        pending = nil
        superview?.setNeedsLayout()
        setNeedsDisplay()
    }

    public func showPending(title: String, fraction: Double) {
        rows = []
        pending = (title, fraction)
        superview?.setNeedsLayout()
        setNeedsDisplay()
    }

    private var metrics: Metrics { Theme.current.metrics }
    private var columnGap: Float { metrics.tv(64) }

    private func columns() -> [[Row]] {
        guard !rows.isEmpty else { return [] }
        let perColumn = max(1, (rows.count + 1) / 2)
        return stride(from: 0, to: rows.count, by: perColumn).map { Array(rows[$0..<min(rows.count, $0 + perColumn)]) }
    }

    private func rowHeight(_ row: Row, width: Float) -> Float {
        let layouts = texts(row, width: width)
        return metrics.tv(14) * 2 + max(layouts.title.size.height, layouts.value.size.height) + metrics.tv(14) + metrics.tv(8)
    }

    private func texts(_ row: Row, width: Float) -> (title: TextLayout, value: TextLayout) {
        let scale = window?.scale ?? 1
        let value = TextLayout(row.valueText, font: Font(size: metrics.tv(35), weight: .medium), scale: scale)
        let title = TextLayout(row.title, font: Font(size: Theme.current.type.subheadline.size, weight: .semibold),
                               maxWidth: max(1, width - value.size.width - metrics.tv(16)), maxLines: 2, scale: scale)
        return (title, value)
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        if let pending {
            let label = TextLayout(pending.title, font: Theme.current.type.callout, maxWidth: size.width, maxLines: 2, scale: window?.scale ?? 1)
            return Size(width: size.width, height: label.size.height + metrics.tv(24) + metrics.tv(8))
        }
        let width = (size.width - columnGap) / 2
        let heights = columns().map { $0.reduce(Float(0)) { $0 + rowHeight($1, width: width) } }
        return Size(width: size.width, height: heights.max() ?? 0)
    }

    public override func draw(_ context: inout DrawContext) {
        let palette = Theme.current.palette
        if let pending {
            let label = TextLayout(pending.title, font: Theme.current.type.callout, maxWidth: frame.width, maxLines: 2, scale: window?.scale ?? 1)
            context.text(label, at: .zero, color: palette.labelSecondary)
            let bar = Rect(x: 0, y: label.size.height + metrics.tv(24), width: frame.width, height: metrics.tv(8))
            context.fill(bar, radius: bar.height / 2, color: palette.surfaceHigh)
            context.fill(Rect(x: 0, y: bar.y, width: bar.width * Float(max(0.02, min(1, pending.fraction))), height: bar.height), radius: bar.height / 2,
                         color: StatsStyle.accent)
            return
        }
        let width = (frame.width - columnGap) / 2
        for (index, column) in columns().enumerated() {
            let x = Float(index) * (width + columnGap)
            var y: Float = 0
            for row in column {
                let layouts = texts(row, width: width)
                let top = y + metrics.tv(14)
                let line = max(layouts.title.size.height, layouts.value.size.height)
                context.text(layouts.title, at: Point(x: x, y: top), color: palette.label)
                let valueY = top + layouts.title.baseline - layouts.value.baseline
                context.text(layouts.value, at: Point(x: x + width - layouts.value.size.width, y: valueY), color: palette.labelSecondary)
                let track = Rect(x: x, y: top + line + metrics.tv(14), width: width, height: metrics.tv(8))
                context.fill(track, radius: metrics.tv(4), color: palette.surfaceHigh)
                let fill = Float(max(0.02, min(1, row.fraction)))
                context.fill(Rect(x: x, y: track.y, width: track.width * fill, height: track.height), radius: metrics.tv(4), color: StatsStyle.categorical(row.colorIndex))
                y += rowHeight(row, width: width)
            }
        }
    }
}

/// A Wrapped moment (`SuperlativeCardView`): a symbol, a huge headline, the title it is about and a caption, on a diagonal
/// wash from the bright accent to a deep ember.
@MainActor
public final class SuperlativeCardView: View {
    private let symbol: Symbol
    private let headline: String
    private let title: String
    private let caption: String

    public init(symbol: Symbol, headline: String, title: String, caption: String) {
        self.symbol = symbol
        self.headline = headline
        self.title = title
        self.caption = caption
        super.init()
    }

    public static var width: Float { Theme.current.metrics.tv(620) }

    public override func sizeThatFits(_ size: Size) -> Size {
        Size(width: Self.width, height: Theme.current.metrics.tv(380))
    }

    public override func draw(_ context: inout DrawContext) {
        let metrics = Theme.current.metrics
        let palette = Theme.current.palette
        let scale = window?.scale ?? 1
        let deep = palette.appearance == .dark ? Color(srgbRed: 0.18, green: 0.07, blue: 0) : Color(srgbRed: 0.62, green: 0.24, blue: 0.05)
        context.gradient(bounds, axis: .diagonal, stops: [(0, StatsStyle.accentBright), (1, deep)], radius: metrics.radiusM)
        let padding = metrics.tv(40)
        let column = frame.width - padding * 2
        var y = padding
        let glyph = metrics.tv(60)
        context.symbol(symbol, in: Rect(x: padding, y: y, width: glyph, height: glyph), color: palette.onArt)
        y += glyph + metrics.tv(20)
        var headlineFont = Font(size: metrics.tv(88), weight: .heavy)
        var headlineText = TextLayout(headline, font: headlineFont, scale: scale)
        if headlineText.size.width > column {
            headlineFont.size = max(headlineFont.size * 0.5, headlineFont.size * column / max(headlineText.size.width, 1))
            headlineText = TextLayout(headline, font: headlineFont, maxWidth: column, scale: scale)
        }
        context.text(headlineText, at: Point(x: padding, y: y), color: palette.onArt)
        y += headlineText.size.height + metrics.tv(4)
        if !title.isEmpty {
            let titleText = TextLayout(title, font: Font(size: metrics.tv(35), weight: .semibold), maxWidth: column, scale: scale)
            context.text(titleText, at: Point(x: padding, y: y), color: palette.onArt)
        }
        if !caption.isEmpty {
            let captionText = TextLayout(caption, font: Font(size: metrics.tv(27), weight: .regular), maxWidth: column, maxLines: 2, scale: scale)
            context.text(captionText, at: Point(x: padding, y: frame.height - padding - captionText.size.height), color: palette.onArtSecondary)
        }
    }
}

/// One binge (`BingeCardView`): the show, how many episodes in one go and when it ended, on a card in the binge's colour that
/// is wider the longer the binge was.
@MainActor
public final class BingeCardView: View {
    private let title: String
    private let episodes: Int
    private let countText: String
    private let caption: String
    private let colorIndex: Int

    /// `countText` is the episode count as shown ("6 eps"); `episodes` sets the card's width.
    public init(title: String, episodes: Int, countText: String, caption: String, colorIndex: Int) {
        self.title = title
        self.episodes = episodes
        self.countText = countText
        self.caption = caption
        self.colorIndex = colorIndex
        super.init()
    }

    public static var height: Float { Theme.current.metrics.tv(250) }

    public override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        let width = min(metrics.tv(560), max(metrics.tv(340), Float(max(0, episodes)) * metrics.tv(26)))
        return Size(width: width, height: Self.height)
    }

    public override func draw(_ context: inout DrawContext) {
        let metrics = Theme.current.metrics
        let palette = Theme.current.palette
        let scale = window?.scale ?? 1
        context.fill(bounds, radius: metrics.radiusM, color: StatsStyle.categorical(colorIndex).withSRGBAlpha(0.9))
        let insetX = metrics.tv(28)
        let insetY = metrics.tv(24)
        let column = frame.width - insetX * 2
        let shadow = Color.black.withSRGBAlpha(0.55)
        func label(_ layout: TextLayout, at point: Point, color: Color) {
            context.text(layout, at: Point(x: point.x, y: point.y + 1), color: shadow)
            context.text(layout, at: point, color: color)
        }
        let titleText = TextLayout(title, font: Font(size: metrics.tv(31), weight: .semibold), maxWidth: column, maxLines: 2, scale: scale)
        label(titleText, at: Point(x: insetX, y: insetY), color: palette.onArt)
        let countLayout = TextLayout(countText, font: Font(size: metrics.tv(52), weight: .bold), maxWidth: column, scale: scale)
        var bottom = frame.height - insetY
        if !caption.isEmpty {
            let captionText = TextLayout(caption, font: Font(size: metrics.tv(25), weight: .medium), maxWidth: column, scale: scale)
            bottom -= captionText.size.height
            label(captionText, at: Point(x: insetX, y: bottom), color: palette.onArtSecondary)
            bottom -= metrics.tv(4)
        }
        label(countLayout, at: Point(x: insetX, y: bottom - countLayout.size.height), color: palette.onArt)
    }
}

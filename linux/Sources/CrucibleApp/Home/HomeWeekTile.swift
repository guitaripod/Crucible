import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// The This Week tile in its place among Home's rows (`TVHomeWeekSurface`): the watch time so far this week, the change
/// against the same days of last week and a bar for each day with today's in the accent. Select opens Statistics.
@MainActor
final class HomeWeekSection: View {
    var onSelect: (() -> Void)? {
        get { panel.onSelect }
        set { panel.onSelect = newValue }
    }

    private let content = HomeWeekContent()
    private let panel: StatsPanelView

    init() {
        panel = StatsPanelView(content: content)
        super.init()
        addSubview(panel)
    }

    func configure(_ model: HomeWeekCardModel) {
        content.model = model
        content.setNeedsDisplay()
    }

    private var topGap: Float { Theme.current.metrics.tv(36) }
    private var tileSize: Size {
        let metrics = Theme.current.metrics
        return Size(width: metrics.tv(960), height: metrics.tv(260))
    }

    override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: topGap + tileSize.height + Theme.current.metrics.tv(12))
    }

    override func layoutSubviews() {
        let margin = Theme.current.metrics.sideMargin
        panel.frame = Rect(x: margin, y: topGap, width: min(tileSize.width, bounds.width - margin * 2), height: tileSize.height)
    }
}

/// What the tile draws: THIS WEEK, the total and the change on the left, the seven days' bars with their initials on the
/// right, then a chevron.
@MainActor
private final class HomeWeekContent: View {
    var model: HomeWeekCardModel?

    private static let barAreaHeight: Float = 120
    private static let barWidth: Float = 26
    private static let minimumBarHeight: Float = 8

    override func draw(_ context: inout DrawContext) {
        guard let model, let scale = window?.scale else { return }
        let theme = Theme.current
        let metrics = theme.metrics
        let palette = theme.palette
        let chevronSide = metrics.tv(28)
        let barsWidth = Float(HomeWeekCardModel.barCount) * metrics.tv(Self.barWidth) + Float(HomeWeekCardModel.barCount - 1) * metrics.tv(12)
        let barsX = bounds.width - chevronSide - metrics.tv(32) - barsWidth
        drawText(model, maxWidth: barsX - metrics.tv(32), scale: scale, context: &context)
        drawBars(model, x: barsX, scale: scale, context: &context)
        let chevron = Rect(x: bounds.width - chevronSide, y: (bounds.height - chevronSide) / 2, width: chevronSide, height: chevronSide)
        context.symbol("chevron.right", in: chevron, color: palette.labelTertiary)
    }

    private func drawText(_ model: HomeWeekCardModel, maxWidth: Float, scale: Float, context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        let eyebrow = TextLayout(String(localized: "THIS WEEK"), font: theme.type.caption1, maxWidth: maxWidth, scale: scale)
        let total = TextLayout(model.total, font: theme.type.title2, maxWidth: maxWidth, maxLines: 1, scale: scale)
        let delta = model.delta.map { TextLayout($0, font: theme.type.callout, maxWidth: maxWidth, maxLines: 2, scale: scale) }
        let gap = metrics.tv(6)
        let height = eyebrow.size.height + gap + total.size.height + (delta.map { gap + $0.size.height } ?? 0)
        var y = ((bounds.height - height) / 2).rounded()
        context.text(eyebrow, at: Point(x: 0, y: y), color: theme.palette.accentText)
        y += eyebrow.size.height + gap
        context.text(total, at: Point(x: 0, y: y), color: theme.palette.label)
        y += total.size.height + gap
        if let delta { context.text(delta, at: Point(x: 0, y: y), color: theme.palette.labelSecondary) }
    }

    private func drawBars(_ model: HomeWeekCardModel, x: Float, scale: Float, context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        let width = metrics.tv(Self.barWidth)
        let area = metrics.tv(Self.barAreaHeight)
        let labelHeight = TextLayout("M", font: theme.type.caption2, scale: scale).size.height
        let top = ((bounds.height - area - metrics.tv(6) - labelHeight) / 2).rounded()
        for (index, bar) in model.bars.enumerated() {
            let left = x + Float(index) * (width + metrics.tv(12))
            let height = max(metrics.tv(Self.minimumBarHeight), (area * Float(bar.ratio)).rounded())
            let color = bar.isToday ? theme.palette.accent : theme.palette.labelTertiary.withAlpha(0.45)
            context.fill(Rect(x: left, y: top + area - height, width: width, height: height), radius: metrics.tv(6), color: color)
            let initial = TextLayout(bar.initial, font: theme.type.caption2, scale: scale)
            context.text(initial, at: Point(x: (left + (width - initial.size.width) / 2).rounded(), y: top + area + metrics.tv(6)),
                         color: theme.palette.labelTertiary)
        }
    }
}

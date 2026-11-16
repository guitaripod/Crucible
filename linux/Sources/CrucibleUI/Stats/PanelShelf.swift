import Foundation
import Kiln

/// A shelf of panels each as wide as it asks to be (`TVStatsSection.binges` and `.superlatives`): a headline over a
/// sideways row that scrolls like a card shelf, with the edge arrows on hover, and keeps the focused panel in view.
@MainActor
public final class PanelShelfView: View {
    /// The headline over the row.
    public var title: String {
        didSet {
            headerLabel.text = title
            setNeedsLayout()
        }
    }
    private let height: Float
    private let scroller = ScrollView(axis: .horizontal)
    private let headerLabel = Label(font: Theme.current.type.headline, color: Theme.current.palette.label)
    private let leadingArrow = ShelfArrow(direction: .left)
    private let trailingArrow = ShelfArrow(direction: .right)
    private var panels: [View] = []
    private var hovering = false

    /// `height` is the panels' height; each panel's width is what it asks for at that height.
    public init(title: String, height: Float) {
        self.title = title
        self.height = height
        super.init()
        scroller.showsIndicator = false
        headerLabel.isHeading = true
        headerLabel.text = title
        [scroller, headerLabel, leadingArrow, trailingArrow].forEach(addSubview)
        leadingArrow.onPress = { [weak self] in self?.page(-1) }
        trailingArrow.onPress = { [weak self] in self?.page(1) }
        scroller.onScroll = { [weak self] _ in self?.updateArrows() }
    }

    public override var remembersFocus: Bool { true }
    public override var preferredFocusView: View? { panels.first }

    public func setPanels(_ views: [View]) {
        panels.forEach { $0.removeFromSuperview() }
        panels = views
        views.forEach(scroller.addSubview)
        setNeedsLayout()
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        return Size(width: size.width, height: metrics.shelfHeaderHeight + metrics.shelfTopInset + height + metrics.shelfBottomInset)
    }

    public override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let margin = metrics.sideMargin
        let titleSize = headerLabel.sizeThatFits(Size(width: frame.width - margin * 2, height: 100))
        headerLabel.frame = Rect(x: margin, y: metrics.shelfHeaderHeight - metrics.sectionSpacing - titleSize.height, width: titleSize.width, height: titleSize.height)
        scroller.frame = Rect(x: 0, y: metrics.shelfHeaderHeight, width: frame.width, height: metrics.shelfTopInset + height + metrics.shelfBottomInset)
        scroller.revealInsets = EdgeInsets(leading: margin, trailing: margin)
        var x = margin
        for panel in panels {
            let width = panel.sizeThatFits(Size(width: frame.width, height: height)).width
            panel.frame = Rect(x: x, y: metrics.shelfTopInset, width: width, height: height)
            x += width + metrics.gutter
        }
        scroller.contentLength = x - metrics.gutter + margin
        let arrow = metrics.tv(72)
        let arrowY = metrics.shelfHeaderHeight + metrics.shelfTopInset + (height - arrow) / 2
        leadingArrow.frame = Rect(x: margin * 0.25, y: arrowY, width: arrow, height: arrow)
        trailingArrow.frame = Rect(x: frame.width - margin * 0.25 - arrow, y: arrowY, width: arrow, height: arrow)
        updateArrows()
    }

    /// Scrolls about a screen's width sideways (the edge arrows).
    private func page(_ direction: Float) {
        let visible = frame.width - Theme.current.metrics.sideMargin * 2
        scroller.setOffset(scroller.offset + direction * visible * 0.8, animated: true)
    }

    private func updateArrows() {
        leadingArrow.setShown(hovering && scroller.offset > 1)
        trailingArrow.setShown(hovering && scroller.offset < scroller.maximumOffset - 1)
    }

    public override var isPointerInteractive: Bool { true }
    public override var cursor: Cursor { .default }

    public override func hitTest(_ point: Point) -> View? {
        let hit = super.hitTest(point)
        let inside = bounds.contains(point)
        if inside != hovering {
            hovering = inside
            updateArrows()
        }
        return hit
    }

    public override func pointerExited() {
        hovering = false
        updateArrows()
    }
}

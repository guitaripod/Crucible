import CrucibleUI
import Kiln

/// Long text in full (`TVSynopsisViewController`): a comment with its formatting or a recap, in the settings column's
/// width, scrolling with the arrows, Page Up and Page Down or the wheel.
@MainActor
final class ReaderScreen: ScreenView {
    private let page = PageView()
    private let heading: ScreenTitleView
    private let body: ReaderText

    init(title: String, markup: String) {
        heading = ScreenTitleView(title: title)
        body = ReaderText(markup: markup)
        super.init()
        addSubview(page)
        page.setSections([heading, body])
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        body.onScroll = { [weak self] step in
            guard let self else { return }
            self.page.setOffset(min(max(0, self.page.offset + step), self.page.maximumOffset), animated: true)
        }
    }

    override var preferredFocusView: View? { body }

    override func layoutSubviews() {
        heading.columnWidth = Theme.current.metrics.wideColumn
        page.topInset = Theme.current.metrics.tabBarClearance
        page.frame = bounds
        page.setNeedsLayout()
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

/// The reader's text: focusable so the keyboard can scroll it, handing each step to the page.
@MainActor
private final class ReaderText: View {
    var onScroll: ((Float) -> Void)?
    private let markup: String

    init(markup: String) {
        self.markup = markup
        super.init()
    }

    override var canBecomeFocused: Bool { true }

    /// The text's column: the settings column the title is set in, inset as that title is, so both start at one edge.
    private func column(in width: Float) -> (x: Float, width: Float) {
        let metrics = Theme.current.metrics
        let column = min(metrics.wideColumn, width - metrics.sideMargin * 2)
        return (((width - column) / 2).rounded() + metrics.rowInset, column - metrics.rowInset * 2)
    }

    private var laidOut: (width: Float, scale: Float, layout: TextLayout)?

    /// The whole text laid out once per width and scale: it can run to pages, and draw runs every frame of a scroll.
    private func layout(width: Float) -> TextLayout {
        let scale = window?.scale ?? 1
        if let laidOut, laidOut.width == width, laidOut.scale == scale { return laidOut.layout }
        let layout = TextLayout(markup, font: Theme.current.type.callout, maxWidth: width, maxLines: 0, scale: scale, markup: true, inColor: true)
        laidOut = (width, scale, layout)
        return layout
    }

    override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: layout(width: column(in: size.width).width).size.height + Theme.current.metrics.tv(80))
    }

    override func keyPressed(_ event: KeyEvent) -> Bool {
        let step = Theme.current.metrics.tv(120)
        switch event.key {
        case .down: onScroll?(step)
        case .up: onScroll?(-step)
        case .pageDown, .space: onScroll?(step * 5)
        case .pageUp: onScroll?(-step * 5)
        default: return false
        }
        return true
    }

    override func draw(_ context: inout DrawContext) {
        let (x, width) = column(in: frame.width)
        context.text(layout(width: width), at: Point(x: x, y: 0), color: Theme.current.palette.label)
    }
}

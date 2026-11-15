import CrucibleUI
import Kiln

/// Long text in full (`TVSynopsisViewController`): a comment with its formatting or a recap, in the settings column's
/// width, scrolling with the arrows, Page Up and Page Down or the wheel.
@MainActor
final class ReaderScreen: ScreenView {
    private let page = PageView()
    private let body: ReaderText

    init(title: String, markup: String) {
        body = ReaderText(markup: markup)
        super.init()
        addSubview(page)
        page.setSections([ScreenTitleView(title: title), body])
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        body.onScroll = { [weak self] step in
            guard let self else { return }
            self.page.setOffset(min(max(0, self.page.offset + step), self.page.maximumOffset), animated: true)
        }
    }

    override var preferredFocusView: View? { body }

    override func layoutSubviews() {
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

    private var column: (x: Float, width: Float) {
        let metrics = Theme.current.metrics
        let width = min(metrics.wideColumn, frame.width - metrics.sideMargin * 2)
        return (((frame.width - width) / 2).rounded(), width)
    }

    private func layout(width: Float) -> TextLayout {
        TextLayout(markup, font: Theme.current.type.callout, maxWidth: width, maxLines: 0, scale: window?.scale ?? 1, markup: true, inColor: true)
    }

    override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        let width = min(metrics.wideColumn, size.width - metrics.sideMargin * 2)
        return Size(width: size.width, height: layout(width: width).size.height + metrics.tv(80))
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
        let (x, width) = column
        context.text(layout(width: width), at: Point(x: x, y: 0), color: Theme.current.palette.label)
    }
}

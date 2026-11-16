import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// A settings screen in the Apple TV's two columns (`TVSettingsScaffold`): a panel about the subject on the left and its
/// rows on the right; in a window too narrow for both, the panel sits above the rows.
@MainActor
class SettingsScaffold: ScreenView {
    let heading: ScreenTitleView
    let rows = RowListView()
    private let page = PageView()
    private let body = SplitSection()
    private let state = StateView()

    init(title: String, detail: String? = nil) {
        heading = ScreenTitleView(title: title, detail: detail)
        super.init()
        body.rows = rows
        body.state = state
        body.addSubview(rows)
        body.addSubview(state)
        state.isHidden = true
        addSubview(page)
        page.setSections([heading, body])
        page.onScroll = { [weak self] offset in
            self?.rootView?.contentScrolled(offset: offset)
            self?.body.follow(offset)
        }
        rows.onSelect = { [weak self] item in self?.rowSelected(item.id) }
        rows.onFocus = { [weak self] item in self?.rowFocused(item.id) }
        rows.onContextMenu = { [weak self] item, anchor in self?.rowMenu(item.id, at: anchor) ?? false }
    }

    override var preferredFocusView: View? { state.isHidden ? rows : state }
    override var remembersFocus: Bool { true }

    /// Keeps the context panel in view while the rows scroll past it, as the Apple TV's column stays put; for a panel that
    /// shows the focused row (Sports Research's stage).
    var pinsContext: Bool {
        get { body.pinsContext }
        set { body.pinsContext = newValue }
    }

    /// Puts `view` in the left column; it sizes itself through `sizeThatFits`.
    func installContext(_ view: View) {
        body.context?.removeFromSuperview()
        body.context = view
        body.addSubview(view)
        setNeedsLayout()
    }

    func setRows(_ items: [RowItem]) {
        rows.setItems(items)
        body.setNeedsLayout()
        page.setNeedsLayout()
    }

    /// Shows `newState` (loading, empty or failed) where the rows go, or the rows again for nil
    /// (`TVSettingsScaffold.presentState`); the focus follows when it was on the side that goes away, and nil while the
    /// rows already show leaves the focus where it is.
    func presentState(_ newState: StateView.State?) {
        guard newState != nil || !state.isHidden else { return }
        let hadFocus = containsFocus
        if let newState {
            state.show(newState)
            state.isHidden = false
            rows.isHidden = true
        } else {
            state.isHidden = true
            rows.isHidden = false
        }
        body.setNeedsLayout()
        page.setNeedsLayout()
        if hadFocus { window?.focus.focus(state.isHidden ? rows : state, animated: false) }
    }

    /// A row was chosen; subclasses act on it.
    func rowSelected(_ id: String) {}

    /// A row took the focus; subclasses that show more about the focused row act on it.
    func rowFocused(_ id: String) {}

    /// The menu for a row (right-click or the Menu key) at `anchor` in the window; subclasses that offer one present it
    /// and return true.
    func rowMenu(_ id: String, at anchor: Rect) -> Bool { false }

    override func layoutSubviews() {
        page.topInset = Theme.current.metrics.tabBarClearance
        page.frame = bounds
        page.setNeedsLayout()
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

/// The scaffold's body: the context panel and the rows side by side, or stacked when the window is narrow.
@MainActor
private final class SplitSection: View {
    var context: View?
    weak var rows: RowListView?
    weak var state: StateView?
    var pinsContext = false
    private var scrolled: Float = 0

    /// Moves a pinned panel down with the page, never past the end of the rows.
    func follow(_ offset: Float) {
        scrolled = offset
        guard pinsContext, let context else { return }
        guard !isStacked(frame.width) else {
            context.translation = .zero
            return
        }
        let shift = min(max(0, offset + Theme.current.metrics.tv(40) - frame.y), max(0, frame.height - context.frame.height - Theme.current.metrics.tv(60)))
        context.translation = Point(x: 0, y: shift.rounded())
    }

    private var contextWidth: Float { Theme.current.metrics.tv(620) }
    private var gap: Float { Theme.current.metrics.tv(60) }

    /// Without a panel the rows take the middle column; with one, both columns unless the window is too narrow.
    private func isStacked(_ width: Float) -> Bool {
        context == nil || width - Theme.current.metrics.sideMargin * 2 < contextWidth + gap + Theme.current.metrics.tv(800)
    }

    private func rowsWidth(_ width: Float) -> Float {
        let metrics = Theme.current.metrics
        return isStacked(width) ? min(width - metrics.sideMargin * 2, metrics.wideColumn) : width - metrics.sideMargin * 2 - contextWidth - gap
    }

    /// The rows' height, or the state's room in their place while it shows.
    private func listHeight(_ width: Float) -> Float {
        if state?.isHidden == false { return Theme.current.metrics.tv(480) }
        return rows?.sizeThatFits(Size(width: width, height: 0)).height ?? 0
    }

    override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        rows?.columnWidth = rowsWidth(size.width)
        let rowsHeight = listHeight(size.width)
        let contextHeight = context?.sizeThatFits(Size(width: contextWidth, height: 0)).height ?? 0
        let height = isStacked(size.width) ? contextHeight + (contextHeight > 0 ? metrics.tv(40) : 0) + rowsHeight : max(contextHeight, rowsHeight)
        return Size(width: size.width, height: height + metrics.tv(60))
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let width = rowsWidth(frame.width)
        rows?.columnWidth = width
        let contextHeight = context?.sizeThatFits(Size(width: contextWidth, height: 0)).height ?? 0
        let rowsHeight = listHeight(frame.width)
        rows?.isLeadingAligned = isStacked(frame.width)
        if isStacked(frame.width) {
            context?.frame = Rect(x: metrics.sideMargin, y: 0, width: width, height: contextHeight)
            let top = contextHeight > 0 ? contextHeight + metrics.tv(40) : 0
            rows?.frame = Rect(x: 0, y: top, width: frame.width, height: rowsHeight)
            state?.frame = Rect(x: metrics.sideMargin, y: top, width: width, height: rowsHeight)
        } else {
            context?.frame = Rect(x: metrics.sideMargin, y: 0, width: contextWidth, height: contextHeight)
            let left = metrics.sideMargin + contextWidth + gap
            rows?.frame = Rect(x: left - metrics.sideMargin, y: 0, width: width + metrics.sideMargin * 2, height: rowsHeight)
            state?.frame = Rect(x: left, y: 0, width: width, height: rowsHeight)
        }
        follow(scrolled)
    }
}

/// A raised read-only panel for the scaffold's left column: an icon well, a title, lines under it and a footnote
/// (`TVReadOnlyPanel` with `TVServerCardView`'s or About's content).
@MainActor
final class ContextPanel: ReadOnlyPanelView {
    struct Content {
        var symbol: Symbol
        /// Initials drawn in a circle in place of the symbol's well (an account).
        var monogram: String?
        var title: String
        var subtitle: String?
        var status: String?
        var statusColor: Color?
        var body: String?
    }

    var content: Content { didSet { superview?.setNeedsLayout(); setNeedsDisplay() } }
    /// A view drawn in the icon well in place of the symbol (About's crystal).
    var wellView: View? {
        didSet {
            oldValue?.removeFromSuperview()
            if let wellView { addSubview(wellView) }
            setNeedsLayout()
            setNeedsDisplay()
        }
    }

    init(content: Content) {
        self.content = content
        super.init()
    }

    override var accessibilityLabel: String? {
        [content.title, content.subtitle, content.status, content.body].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var inset: Float { Theme.current.metrics.tv(36) }
    private var well: Float { Theme.current.metrics.tv(120) }

    private struct Line {
        let layout: TextLayout
        let color: Color
        let after: Float
        var isStatus = false
    }

    private func layouts(width: Float, scale: Float) -> [Line] {
        let theme = Theme.current
        let palette = theme.palette
        let textWidth = width - inset * 2
        var result = [Line(layout: TextLayout(content.title, font: theme.type.title3, maxWidth: textWidth, maxLines: 2, scale: scale),
                           color: palette.label, after: theme.metrics.tv(6))]
        if let subtitle = content.subtitle {
            result.append(Line(layout: TextLayout(subtitle, font: theme.type.callout, maxWidth: textWidth, maxLines: 2, scale: scale),
                               color: palette.labelSecondary, after: theme.metrics.tv(16)))
        }
        if let status = content.status {
            let dot = content.statusColor == nil ? 0 : theme.metrics.tv(26)
            result.append(Line(layout: TextLayout(status, font: theme.type.callout, maxWidth: textWidth - dot, maxLines: 3, scale: scale),
                               color: palette.label, after: theme.metrics.tv(20), isStatus: true))
        }
        if let body = content.body {
            result.append(Line(layout: TextLayout(body, font: theme.type.footnote, maxWidth: textWidth, maxLines: 24, scale: scale),
                               color: palette.labelSecondary, after: 0))
        }
        return result
    }

    override func sizeThatFits(_ size: Size) -> Size {
        let scale = window?.scale ?? 1
        let text = layouts(width: size.width, scale: scale).reduce(Float(0)) { $0 + $1.layout.size.height + $1.after }
        return Size(width: size.width, height: (inset * 2 + well + Theme.current.metrics.tv(24) + text).rounded(.up))
    }

    override func layoutSubviews() {
        wellView?.frame = Rect(x: inset, y: inset, width: well, height: well)
    }

    /// The icon well: the monogram on the ember gradient for an account, the symbol on the accent tint otherwise.
    private func drawWell(in wellRect: Rect, scale: Float, context: inout DrawContext) {
        let theme = Theme.current
        let palette = theme.palette
        if let monogram = content.monogram {
            context.gradient(wellRect, vertical: true, stops: [(0, palette.emberMid), (1, palette.emberBottom)], radius: well / 2)
            let initials = TextLayout(monogram, font: theme.type.title2, scale: scale)
            context.text(initials, at: Point(x: (wellRect.midX - initials.size.width / 2).rounded(), y: (wellRect.midY - initials.size.height / 2).rounded()),
                         color: palette.onArt)
        } else {
            context.fill(wellRect, radius: theme.metrics.radiusL, color: palette.accentTint)
            let glyph = well * 0.5
            context.symbol(content.symbol, in: Rect(x: wellRect.midX - glyph / 2, y: wellRect.midY - glyph / 2, width: glyph, height: glyph),
                           color: palette.accentText)
        }
    }

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let theme = Theme.current
        let metrics = theme.metrics
        let palette = theme.palette
        context.fill(bounds, radius: metrics.radiusL, color: palette.surface)
        let wellRect = Rect(x: inset, y: inset, width: well, height: well)
        if wellView == nil { drawWell(in: wellRect, scale: scale, context: &context) }
        var y = wellRect.maxY + metrics.tv(24)
        for line in layouts(width: bounds.width, scale: scale) {
            var x = inset
            if line.isStatus, let dotColor = content.statusColor {
                let dot = metrics.tv(14)
                context.fill(Rect(x: x, y: y + (line.layout.size.height - dot) / 2, width: dot, height: dot), radius: dot / 2, color: dotColor)
                x += metrics.tv(26)
            }
            context.text(line.layout, at: Point(x: x, y: y), color: line.color)
            y += line.layout.size.height + line.after
        }
    }
}

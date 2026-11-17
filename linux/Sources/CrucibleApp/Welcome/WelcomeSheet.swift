import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// The welcome a first library opens with on this computer (`WelcomePlan`): a new install, or the first since Crucible's
/// settings were cleared. Over the onboarding backdrop, the crystal, Welcome to Crucible and the server, where the viewer
/// stands (on Linux every feature is open), what the app does, and what Trakt adds with Connect Trakt, which closes the
/// welcome on Trakt's settings. Its parts rise into place one after another, all at once under Reduce Motion; the keyboard
/// stays inside it, starting on Start Watching, and Escape closes it.
@MainActor
final class WelcomeSheetView: View {
    /// What closing the welcome leads to.
    enum Exit {
        case start
        case connectTrakt
    }

    private let serverName: String
    private let onExit: (Exit) -> Void
    private let scroll = WelcomeColumnsView()
    private let glyph = CrystalGlyphView()
    private let heading = WelcomeTextBlock(font: { $0.largeTitle }, color: { $0.label }, maxLines: 2)
    private let server = WelcomeTextBlock(font: { $0.callout }, color: { $0.labelSecondary }, maxLines: 2)
    private let standing = WelcomeItemView(style: .panel)
    private var highlights: [WelcomeItemView] = []
    private let trakt = WelcomeItemView(style: .panel)
    private let traktButton = ButtonView(style: .glass, title: TraktCopy.connect, symbol: "link")
    private let start = ButtonView(style: .primary, title: WelcomeCopy.start, symbol: "play.fill")
    private var appear = Animated(0)
    private var elapsed: Float = 0
    private var isDismissing = false
    private var traktObserver: UUID?
    private weak var returnFocus: View?

    private static let stagger: Float = 0.07
    private static let rise: Float = 0.55

    init(serverName: String, onExit: @escaping (Exit) -> Void) {
        self.serverName = serverName
        self.onExit = onExit
        super.init()
        addSubview(scroll)
        heading.text = WelcomeCopy.title
        heading.keepsNextClose = true
        server.text = WelcomeCopy.connected(to: serverName)
        trakt.button = traktButton
        traktButton.onPress = { [weak self] in self?.close(.connectTrakt) }
        start.onPress = { [weak self] in self?.close(.start) }
        render()
    }

    /// Lays the plan out again for the account and the store as they are now.
    private func render() {
        let access = ProAccess.shared
        let plan = WelcomePlan(status: access.status, isStoreBacked: access.isStoreBacked, proWeek: access.proWeekPhase, trakt: TraktAccount.shared.status)
        standing.apply(symbol: Symbol(plan.standingSymbol), brand: nil, title: plan.standingTitle, detail: plan.standingMessage)
        if highlights.isEmpty {
            highlights = WelcomeCopy.freeHighlights(includingDownloads: false).map { highlight in
                let row = WelcomeItemView(style: .row)
                row.apply(symbol: Symbol(highlight.symbol), brand: nil, title: highlight.title, detail: highlight.detail)
                return row
            }
        }
        if let step = plan.trakt {
            trakt.isHidden = false
            trakt.apply(symbol: nil, brand: "trakt", title: WelcomeCopy.title(of: step), detail: WelcomeCopy.message(of: step))
            let action = WelcomeCopy.action(of: step)
            traktButton.title = action
            traktButton.isHidden = action == nil
            if action == nil, traktButton.isFocused { window?.focus.focus(start, animated: false) }
        } else {
            trakt.isHidden = true
        }
        scroll.leading = [glyph, heading, server, standing, start]
        scroll.trailing = highlights + [trakt]
        scroll.setNeedsLayout()
    }

    /// Shows the welcome over everything in `window`, the focus on Start Watching. The focus moves before the parts start
    /// their rise, since a part that has not appeared yet cannot take it.
    func present(in window: Window) {
        window.contentView.addSubview(self)
        frame = window.contentView.bounds
        returnFocus = window.focusedView
        glyph.startBreathing()
        window.focus.setVisible(true)
        window.focus.focus(start, animated: false)
        elapsed = 0
        applyEntrance()
        appear.set(1, animation: .fade)
        if traktObserver == nil { traktObserver = TraktAccount.shared.observe { [weak self] in self?.render() } }
        startAnimating()
    }

    private func close(_ exit: Exit) {
        guard superview != nil, !isDismissing else { return }
        isDismissing = true
        if let traktObserver { TraktAccount.shared.stopObserving(traktObserver) }
        traktObserver = nil
        glyph.stopBreathing()
        if let window {
            if let focus = returnFocus, focus.window != nil, !focus.isDescendant(of: self) {
                window.focus.focus(focus, animated: false)
            } else {
                window.focus.focus(window.contentView, animated: false)
            }
        }
        appear.set(0, animation: .fade)
        if !appear.isAnimating { removeFromSuperview() }
        startAnimating()
        onExit(exit)
    }

    override var preferredFocusView: View? { start }
    override var isFocusScope: Bool { true }
    override var isPointerInteractive: Bool { true }
    override var cursor: Cursor { .default }
    override var accessibilityRole: AccessibilityRole { .dialog }
    override var accessibilityLabel: String? { WelcomeCopy.title }

    override func keyPressed(_ event: KeyEvent) -> Bool {
        guard event.key == .escape || event.key == .back || event.key == .menu else { return false }
        close(.start)
        return true
    }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool { true }

    /// Every part in order, the order they rise in.
    private var parts: [View] { [glyph, heading, server, standing] + highlights + [trakt, start] }

    /// Each part fades in and rises a little, `stagger` after the one before it; under Reduce Motion they are all in place.
    private func applyEntrance() {
        let distance = Theme.current.metrics.tv(36)
        for (index, part) in parts.enumerated() {
            let begin = Self.stagger * Float(index + 1)
            let linear = Animation.reduceMotion ? 1 : min(max((elapsed - begin) / Self.rise, 0), 1)
            let eased = 1 - pow(1 - linear, 3)
            part.alpha = eased
            part.translation = Point(x: 0, y: ((1 - eased) * distance).rounded())
        }
    }

    private var entranceLength: Float { Self.stagger * Float(parts.count + 1) + Self.rise }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let fading = appear.advance(dt)
        alpha = appear.value
        let rising = !Animation.reduceMotion && elapsed < entranceLength
        if rising { elapsed += dt }
        applyEntrance()
        if !fading, isDismissing { removeFromSuperview() }
        return fading || rising
    }

    override func layoutSubviews() {
        scroll.frame = bounds
    }

    override func draw(_ context: inout DrawContext) {
        let palette = Theme.current.palette
        context.fill(bounds, color: palette.canvas)
        context.glow(in: bounds, radius: 0, center: Point(x: bounds.midX, y: bounds.height * 0.4), glowRadius: bounds.width * 0.55,
                     color: palette.welcomeGlow)
    }
}

/// The welcome's two columns, side by side in a wide window and one under the other in a narrow one, centred when they
/// fit and scrolling when they do not.
@MainActor
private final class WelcomeColumnsView: ScrollView {
    var leading: [View] = [] { didSet { adopt(oldValue, leading) } }
    var trailing: [View] = [] { didSet { adopt(oldValue, trailing) } }

    init() {
        super.init(axis: .vertical)
        showsIndicator = true
    }

    private func adopt(_ old: [View], _ new: [View]) {
        for view in old where !new.contains(where: { $0 === view }) { view.removeFromSuperview() }
        for view in new where view.superview !== self { addSubview(view) }
        setNeedsLayout()
    }

    private var metrics: Metrics { Theme.current.metrics }
    private var gap: Float { metrics.tv(120) }
    private var room: Float { frame.width - metrics.sideMargin * 2 }
    private var isSideBySide: Bool { room >= metrics.tv(1400) }
    private var columnWidth: Float { isSideBySide ? min(metrics.tv(760), (room - gap) / 2) : min(metrics.tv(900), room) }

    /// The space after each part, by what it is.
    private func spacing(after view: View, in column: [View]) -> Float {
        if view is CrystalGlyphView { return metrics.tv(36) }
        if let text = view as? WelcomeTextBlock { return text.keepsNextClose ? metrics.tv(10) : metrics.tv(44) }
        if let item = view as? WelcomeItemView { return item.style == .row ? metrics.tv(28) : metrics.tv(44) }
        return metrics.tv(28)
    }

    private func size(of view: View, width: Float) -> Size {
        if view is CrystalGlyphView { return Size(width: metrics.tv(156), height: metrics.tv(156)) }
        if let button = view as? ButtonView {
            return Size(width: min(max(button.sizeThatFits(Size(width: width, height: 0)).width, metrics.tv(480)), width), height: metrics.primaryControlHeight)
        }
        return Size(width: width, height: view.sizeThatFits(Size(width: width, height: 0)).height)
    }

    private func height(of column: [View], width: Float) -> Float {
        let shown = column.filter { !$0.isHidden }
        return shown.enumerated().reduce(0) { total, entry in
            total + size(of: entry.element, width: width).height + (entry.offset < shown.count - 1 ? spacing(after: entry.element, in: shown) : 0)
        }
    }

    private func place(_ column: [View], x: Float, top: Float, width: Float) {
        let shown = column.filter { !$0.isHidden }
        var y = top
        for (index, view) in shown.enumerated() {
            let size = size(of: view, width: width)
            view.frame = Rect(x: x, y: y, width: size.width, height: size.height)
            y += size.height + (index < shown.count - 1 ? spacing(after: view, in: shown) : 0)
        }
    }

    override func layoutSubviews() {
        let width = columnWidth
        let margin = metrics.tv(72)
        revealInsets = EdgeInsets(top: margin, bottom: margin)
        wheelStep = metrics.tv(200)
        if isSideBySide {
            let left = height(of: leading, width: width)
            let right = height(of: trailing, width: width)
            let tallest = max(left, right)
            let top = max(margin, ((frame.height - tallest) / 2).rounded())
            let x = ((frame.width - width * 2 - gap) / 2).rounded()
            place(leading, x: x, top: top + ((tallest - left) / 2).rounded(), width: width)
            place(trailing, x: x + width + gap, top: top + ((tallest - right) / 2).rounded(), width: width)
            contentLength = top + tallest + margin
        } else {
            let stacked = Array(leading.dropLast()) + trailing + Array(leading.suffix(1))
            let total = height(of: stacked, width: width)
            let top = max(margin, ((frame.height - total) / 2).rounded())
            place(stacked, x: ((frame.width - width) / 2).rounded(), top: top, width: width)
            contentLength = top + total + margin
        }
        super.layoutSubviews()
    }
}

/// One line or block of the welcome's text, at a recipe of the type scale.
@MainActor
private final class WelcomeTextBlock: View {
    var text = "" { didSet { if text != oldValue { superview?.setNeedsLayout(); setNeedsDisplay() } } }
    /// The next part belongs with this one (the server under the title), so it follows closely.
    var keepsNextClose = false
    private let font: (TypeScale) -> Font
    private let color: (Palette) -> Color
    private let maxLines: Int

    init(font: @escaping (TypeScale) -> Font, color: @escaping (Palette) -> Color, maxLines: Int) {
        self.font = font
        self.color = color
        self.maxLines = maxLines
        super.init()
    }

    override var accessibilityRole: AccessibilityRole { .label }
    override var accessibilityLabel: String? { text }

    private func layout(width: Float) -> TextLayout {
        TextLayout(text, font: font(Theme.current.type), maxWidth: width, maxLines: maxLines, scale: window?.scale ?? 1)
    }

    override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: layout(width: size.width).size.height)
    }

    override func draw(_ context: inout DrawContext) {
        context.text(layout(width: frame.width), at: .zero, color: color(Theme.current.palette))
    }
}

/// A symbol (or a brand's mark) beside a name and what it means: a line of what the app does, or a raised panel (where the
/// viewer stands, Trakt) that can carry a button under its text.
@MainActor
private final class WelcomeItemView: View {
    enum Style {
        case row
        case panel
    }

    let style: Style
    var button: ButtonView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let button { addSubview(button) }
            setNeedsLayout()
        }
    }

    private var symbol: Symbol?
    private var brand: String?
    private var title = ""
    private var detail = ""
    private var mark: BrandMarkView?

    init(style: Style) {
        self.style = style
        super.init()
    }

    func apply(symbol newSymbol: Symbol?, brand newBrand: String?, title newTitle: String, detail newDetail: String) {
        symbol = newSymbol
        title = newTitle
        detail = newDetail
        if newBrand != brand {
            brand = newBrand
            mark?.removeFromSuperview()
            mark = newBrand.map(BrandMarkView.init)
            if let mark { addSubview(mark) }
        }
        superview?.setNeedsLayout()
        setNeedsLayout()
        setNeedsDisplay()
    }

    override var accessibilityRole: AccessibilityRole { .group }
    override var accessibilityLabel: String? { "\(title). \(detail)" }

    private var metrics: Metrics { Theme.current.metrics }
    private var inset: Float { style == .panel ? metrics.tv(36) : 0 }
    private var well: Float { style == .panel ? metrics.tv(72) : metrics.rowIconWell }
    private var gap: Float { metrics.tv(24) }
    private var titleFont: Font { style == .panel ? Theme.current.type.headline : Theme.current.type.cardTitle }
    private var detailFont: Font { style == .panel ? Theme.current.type.body : Theme.current.type.cardSubtitle }
    private var hasButton: Bool { button.map { !$0.isHidden } ?? false }

    private func layouts(width: Float) -> (title: TextLayout, detail: TextLayout) {
        let scale = window?.scale ?? 1
        let column = max(width - inset * 2 - well - gap, 1)
        return (TextLayout(title, font: titleFont, maxWidth: column, maxLines: 2, scale: scale),
                TextLayout(detail, font: detailFont, maxWidth: column, maxLines: 6, scale: scale))
    }

    private func textHeight(_ text: (title: TextLayout, detail: TextLayout)) -> Float {
        text.title.size.height + metrics.tv(8) + text.detail.size.height
    }

    override func sizeThatFits(_ size: Size) -> Size {
        let text = layouts(width: size.width)
        var height = max(well, textHeight(text))
        if hasButton { height += metrics.tv(28) + metrics.primaryControlHeight }
        return Size(width: size.width, height: height + inset * 2)
    }

    override func layoutSubviews() {
        mark?.frame = Rect(x: inset, y: inset, width: well, height: well)
        guard let button, hasButton else { return }
        let text = layouts(width: frame.width)
        let x = inset + well + gap
        let width = min(max(button.sizeThatFits(Size(width: frame.width, height: 0)).width, metrics.tv(360)), frame.width - x - inset)
        button.frame = Rect(x: x, y: inset + max(well, textHeight(text)) + metrics.tv(28), width: width, height: metrics.primaryControlHeight)
    }

    override func draw(_ context: inout DrawContext) {
        let palette = Theme.current.palette
        if style == .panel {
            context.fill(bounds, radius: metrics.radiusM, color: palette.surface)
            context.stroke(bounds, radius: metrics.radiusM, width: 1, color: palette.separator)
        }
        if mark == nil, let symbol {
            let wellRect = Rect(x: inset, y: inset, width: well, height: well)
            context.fill(wellRect, radius: metrics.radiusS, color: palette.accentTint)
            let side = style == .panel ? metrics.tv(38) : metrics.symbolRow
            context.symbol(symbol, in: Rect(x: wellRect.midX - side / 2, y: wellRect.midY - side / 2, width: side, height: side), color: palette.accentText)
        }
        let text = layouts(width: frame.width)
        let x = inset + well + gap
        let top = inset + max(0, ((well - textHeight(text)) / 2).rounded())
        context.text(text.title, at: Point(x: x, y: top), color: palette.label)
        context.text(text.detail, at: Point(x: x, y: top + text.title.size.height + metrics.tv(8)), color: palette.labelSecondary)
    }
}

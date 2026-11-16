import Foundation
import Kiln

/// The Desktop layout's navigation (the tab bar's place on a desk): a column down the window's leading edge with Back
/// and Forward at its head, sections of destinations (Home and Search, the libraries, the viewer's own pages) and a
/// footer (Settings, the app's menu). One row is selected; the pointer lights the row under it; rows name their key in a
/// tooltip. Collapsed, it is a rail of symbols whose names show in tooltips.
@MainActor
public final class SidebarView: View {
    public struct Item: Equatable {
        public var id: String
        public var title: String
        public var symbol: Symbol
        public var shortcut: String?

        public init(id: String, title: String, symbol: Symbol, shortcut: String? = nil) {
            self.id = id
            self.title = title
            self.symbol = symbol
            self.shortcut = shortcut
        }
    }

    public struct Section: Equatable {
        public var title: String?
        public var items: [Item]

        public init(title: String? = nil, items: [Item]) {
            self.title = title
            self.items = items
        }
    }

    public var sections: [Section] = [] { didSet { if sections != oldValue { rebuild() } } }
    public var footer: [Item] = [] { didSet { if footer != oldValue { rebuild() } } }
    public private(set) var selectedID: String?
    public var onSelect: ((Item, Rect) -> Void)?
    public var onBack: (() -> Void)?
    public var onForward: (() -> Void)?
    public var canGoBack = false { didSet { if canGoBack != oldValue { back.isEnabled = canGoBack } } }
    public var canGoForward = false { didSet { if canGoForward != oldValue { forward.isEnabled = canGoForward } } }
    /// Whether Back and Forward head the column (the window's sidebar) or not (a list of categories beside a page).
    public var showsNavigation = true {
        didSet {
            back.isHidden = !showsNavigation
            forward.isHidden = !showsNavigation
            setNeedsLayout()
        }
    }
    /// A width of its own in place of the window sidebar's.
    public var preferredWidth: Float?
    /// A rail of symbols instead of the full column.
    public var isCollapsed = false {
        didSet {
            guard isCollapsed != oldValue else { return }
            rows.forEach { $0.isCollapsed = isCollapsed }
            superview?.setNeedsLayout()
            setNeedsLayout()
            setNeedsDisplay()
        }
    }

    private let back = SidebarNavButton(symbol: "chevron.left")
    private let forward = SidebarNavButton(symbol: "chevron.right")
    private let scroller = ScrollView(axis: .vertical)
    private var rows: [SidebarRow] = []
    private var headings: [(title: String, y: Float)] = []

    public override init(frame: Rect = .zero) {
        super.init(frame: frame)
        back.spokenTitle = Strings.text("Back")
        back.shortcut = "Alt+←"
        forward.spokenTitle = Strings.text("Forward")
        forward.shortcut = "Alt+→"
        back.isEnabled = false
        forward.isEnabled = false
        back.onPress = { [weak self] in self?.onBack?() }
        forward.onPress = { [weak self] in self?.onForward?() }
        scroller.showsIndicator = false
        addSubview(scroller)
        addSubview(back)
        addSubview(forward)
    }

    /// How wide the column is: full, or the rail.
    public var width: Float { isCollapsed ? Theme.current.metrics.tv(128) : preferredWidth ?? Theme.current.metrics.tv(430) }

    public override var isPointerInteractive: Bool { true }
    public override var cursor: Cursor { .default }
    public override var remembersFocus: Bool { true }
    public override var preferredFocusView: View? { rows.first { $0.item.id == selectedID } ?? rows.first }
    public override var accessibilityRole: AccessibilityRole { .tabList }

    /// Marks `id`'s row selected (nil for none).
    public func select(_ id: String?) {
        selectedID = id
        rows.forEach { $0.isSelected = $0.item.id == id }
    }

    /// Where `id`'s row sits in window points, for a menu it opens.
    public func frameOfRow(_ id: String) -> Rect? {
        rows.first { $0.item.id == id }?.frameInWindow
    }

    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }
        rows = (sections.flatMap(\.items) + footer).map { item in
            let row = SidebarRow(item: item)
            row.isCollapsed = isCollapsed
            row.isSelected = item.id == selectedID
            row.onPress = { [weak self, weak row] in
                guard let self, let row else { return }
                self.onSelect?(row.item, row.frameInWindow)
            }
            return row
        }
        for row in rows {
            if footer.contains(where: { $0.id == row.item.id }) { addSubview(row) } else { scroller.addSubview(row) }
        }
        setNeedsLayout()
    }

    public override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let pad = metrics.tv(20)
        let rowHeight = metrics.tv(74)
        let navSide = metrics.tv(64)
        back.frame = Rect(x: pad, y: metrics.tv(28), width: navSide, height: navSide)
        forward.frame = isCollapsed
            ? Rect(x: pad, y: back.frame.maxY + metrics.tv(8), width: navSide, height: navSide)
            : Rect(x: back.frame.maxX + metrics.tv(10), y: back.frame.y, width: navSide, height: navSide)
        let top = showsNavigation ? forward.frame.maxY + metrics.tv(28) : metrics.tabBarClearance - metrics.tv(20)
        let footerHeight = Float(footer.count) * rowHeight + metrics.tv(24)
        scroller.frame = Rect(x: 0, y: top, width: bounds.width, height: max(bounds.height - top - footerHeight, 0))
        var y: Float = 0
        headings = []
        var rowIndex = 0
        for (index, section) in sections.enumerated() {
            if index > 0 { y += metrics.tv(isCollapsed ? 20 : 26) }
            if let title = section.title, !isCollapsed {
                headings.append((title, top + y))
                y += metrics.tv(52)
            }
            for _ in section.items {
                rows[rowIndex].frame = Rect(x: pad, y: y, width: bounds.width - pad * 2, height: rowHeight)
                y += rowHeight
                rowIndex += 1
            }
        }
        scroller.contentLength = y + metrics.tv(12)
        var footerY = bounds.height - footerHeight + metrics.tv(12)
        while rowIndex < rows.count {
            rows[rowIndex].frame = Rect(x: pad, y: footerY, width: bounds.width - pad * 2, height: rowHeight)
            footerY += rowHeight
            rowIndex += 1
        }
    }

    public override func draw(_ context: inout DrawContext) {
        let theme = Theme.current
        let palette = theme.palette
        context.fill(bounds, color: palette.appearance == .dark ? Color(hex: 0x141210) : Color(hex: 0xECE7E1))
        context.fill(Rect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height), color: palette.label.withAlpha(0.08))
        guard let scale = window?.scale else { return }
        let offset = scroller.offset
        context.clipped(to: scroller.frame) { inner in
            for heading in headings {
                let layout = TextLayout(heading.title.uppercased(), font: theme.type.caption2, maxWidth: bounds.width - theme.metrics.tv(64), maxLines: 1,
                                        scale: scale)
                inner.text(layout, at: Point(x: theme.metrics.tv(36), y: heading.y - offset + theme.metrics.tv(18)), color: palette.labelSecondary)
            }
        }
    }
}

/// One destination of the sidebar: its symbol and title, a filled pill when selected, a lighter one under the pointer.
@MainActor
final class SidebarRow: View {
    let item: SidebarView.Item
    var onPress: (() -> Void)?
    var isSelected = false { didSet { if isSelected != oldValue { setNeedsDisplay() } } }
    var isCollapsed = false { didSet { if isCollapsed != oldValue { setNeedsDisplay() } } }
    private var hover = Animated(0)
    private var pressed = false

    init(item: SidebarView.Item) {
        self.item = item
        super.init()
    }

    override var canBecomeFocused: Bool { true }
    override var accessibilityLabel: String? { item.title }
    override var accessibilityRole: AccessibilityRole { .tab }
    override var accessibilityIsSelected: Bool? { isSelected }

    override func tooltip(at point: Point) -> String? {
        if isCollapsed { return item.shortcut.map { "\(item.title) (\($0))" } ?? item.title }
        return item.shortcut.map { "\(item.title) (\($0))" }
    }

    override func pointerEntered() { animateHover() }
    override func pointerExited() {
        pressed = false
        animateHover()
    }

    private func animateHover() {
        hover.set(isHovered ? 1 : 0, animation: .timed(duration: 0.1, curve: .easeOut))
        startAnimating()
    }

    override func focusDidChange(focused: Bool, animated: Bool) { setNeedsDisplay() }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard button == .primary else { return false }
        pressed = true
        setNeedsDisplay()
        return true
    }

    override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        guard pressed else { return }
        pressed = false
        setNeedsDisplay()
        if inside { onPress?() }
    }

    override func activate() { onPress?() }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = hover.advance(dt)
        setNeedsDisplay()
        return moving
    }

    override func draw(_ context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        let palette = theme.palette
        guard let scale = window?.scale else { return }
        let radius = metrics.radiusS
        let focusShown = isFocused && (window?.isFocusVisible ?? false)
        if isSelected {
            context.fill(bounds, radius: radius, color: palette.accent.withAlpha(0.22))
        } else if hover.value > 0.01 || pressed {
            context.fill(bounds, radius: radius, color: palette.label.withAlpha((pressed ? 0.14 : 0.08) * max(hover.value, pressed ? 1 : 0)))
        }
        if focusShown {
            context.stroke(bounds, radius: radius, width: max(metrics.tv(3), 1.5), color: palette.accent)
        }
        let side = metrics.tv(34)
        let symbolX = isCollapsed ? (bounds.width - side) / 2 : metrics.tv(18)
        let tint = isSelected ? palette.accentText : palette.label
        context.symbol(item.symbol, in: Rect(x: symbolX, y: bounds.midY - side / 2, width: side, height: side), color: tint)
        guard !isCollapsed else { return }
        let x = symbolX + side + metrics.tv(20)
        let title = TextLayout(item.title, font: isSelected ? theme.type.cardTitle : theme.type.body, maxWidth: bounds.width - x - metrics.tv(12), maxLines: 1,
                               scale: scale)
        context.text(title, at: Point(x: x, y: ((bounds.height - title.size.height) / 2 * scale).rounded() / scale), color: isSelected ? palette.label : palette.label)
    }
}

/// Back or Forward at the sidebar's head: a round symbol button, dimmed while there is nowhere to go.
@MainActor
final class SidebarNavButton: View {
    let symbol: Symbol
    var onPress: (() -> Void)?
    var spokenTitle: String?
    var shortcut: String?
    var isEnabled = true { didSet { if isEnabled != oldValue { setNeedsDisplay() } } }
    private var pressed = false

    init(symbol: Symbol) {
        self.symbol = symbol
        super.init()
    }

    override var canBecomeFocused: Bool { false }
    override var isPointerInteractive: Bool { true }
    override var cursor: Cursor { isEnabled ? .pointer : .default }
    override var accessibilityLabel: String? { spokenTitle }

    override func tooltip(at point: Point) -> String? {
        guard let spokenTitle else { return nil }
        return shortcut.map { "\(spokenTitle) (\($0))" } ?? spokenTitle
    }

    override func pointerEntered() { setNeedsDisplay() }
    override func pointerExited() {
        pressed = false
        setNeedsDisplay()
    }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard button == .primary, isEnabled else { return false }
        pressed = true
        setNeedsDisplay()
        return true
    }

    override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        guard pressed else { return }
        pressed = false
        setNeedsDisplay()
        if inside { onPress?() }
    }

    override func draw(_ context: inout DrawContext) {
        let palette = Theme.current.palette
        if isEnabled && (isHovered || pressed) {
            context.fill(bounds, radius: bounds.height / 2, color: palette.label.withAlpha(pressed ? 0.16 : 0.09))
        }
        let inset = bounds.width * 0.3
        context.symbol(symbol, in: bounds.insetBy(inset, inset), color: isEnabled ? palette.label : palette.label.withAlpha(0.28))
    }
}

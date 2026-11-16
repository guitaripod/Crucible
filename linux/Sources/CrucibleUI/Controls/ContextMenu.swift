import Foundation
import Kiln

/// A desktop context menu (the player's right click, a card's): actions with a checkmark when chosen, steppers that change
/// a value in place with − and +, separators and section labels, and submenus that open beside their row, each panel a
/// frosted sheet drawn by the app so it works the same in a window and in full screen.
///
/// It behaves as desktop menus do. Exactly one row of a panel is highlighted: the one under the pointer or the keyboard,
/// or the row whose submenu is open while the pointer is in that submenu. A submenu opens after the pointer rests on its
/// row, and a pointer crossing other rows on its way into an open submenu does not close it (menu aim). The keyboard:
/// Up and Down move and wrap, Home, End, Page Up and Page Down jump, typing a title's first letters moves to it, Right or
/// Return opens a submenu and Left closes it, Left and Right on a stepper change its value, Return or Space chooses,
/// Escape closes the innermost panel. A panel taller than the window scrolls. A choice closes the menu unless its entry
/// keeps it open, and an entry that keeps it open rebuilds its panel so values and checkmarks stay current.
@MainActor
public final class ContextMenuView: View {
    public struct Action {
        public var title: String
        public var detail: String?
        public var symbol: Symbol?
        public var shortcut: String?
        public var isChecked: Bool
        public var isEnabled: Bool
        public var isDestructive: Bool
        /// The menu stays open after it runs (toggles and choices worth trying in turn).
        public var keepsOpen: Bool
        public var run: @MainActor () -> Void

        public init(_ title: String, detail: String? = nil, symbol: Symbol? = nil, shortcut: String? = nil, isChecked: Bool = false,
                    isEnabled: Bool = true, isDestructive: Bool = false, keepsOpen: Bool = false, run: @escaping @MainActor () -> Void) {
            self.title = title
            self.detail = detail
            self.symbol = symbol
            self.shortcut = shortcut
            self.isChecked = isChecked
            self.isEnabled = isEnabled
            self.isDestructive = isDestructive
            self.keepsOpen = keepsOpen
            self.run = run
        }
    }

    /// A value changed in place: − and + step it, and Reset (when given) puts it back.
    public struct Stepper {
        public var title: String
        public var value: String
        public var symbol: Symbol?
        public var decrease: @MainActor () -> Void
        public var increase: @MainActor () -> Void
        public var reset: (@MainActor () -> Void)?

        public init(_ title: String, value: String, symbol: Symbol? = nil, decrease: @escaping @MainActor () -> Void,
                    increase: @escaping @MainActor () -> Void, reset: (@MainActor () -> Void)? = nil) {
            self.title = title
            self.value = value
            self.symbol = symbol
            self.decrease = decrease
            self.increase = increase
            self.reset = reset
        }
    }

    public enum Entry {
        case action(Action)
        case stepper(Stepper)
        /// A row that opens `entries` beside it; built when it opens, so it shows current values.
        case submenu(String, detail: String? = nil, symbol: Symbol? = nil, isEnabled: Bool = true, entries: @MainActor () -> [Entry])
        case separator
        case section(String)
    }

    public var onDismiss: (() -> Void)?
    private let origin: Point
    /// What a dropdown opens from (a button): the menu hangs below it, at least as wide, or above it near the bottom.
    private let anchor: Rect?
    private let root: @MainActor () -> [Entry]
    private(set) var panels: [ContextMenuPanel] = []
    private weak var returnFocus: View?
    private var pendingHover: DispatchWorkItem?
    private let highlightsFirstRow: Bool
    /// The pointer's last positions in window points, newest last, which tell where it is heading (`isAiming(at:)`).
    private var trail: [Point] = []

    /// How long the pointer rests on a row before its submenu opens, or another row's closes.
    static let hoverDelay = 0.2
    /// How long a pointer heading into an open submenu may cross other rows before they take over.
    static let aimDelay = 0.3

    /// A menu of `entries` opening at `origin` (window points), its corner at the pointer as desktop menus open.
    /// `highlightingFirstRow` is for a menu opened from the keyboard; a menu the pointer opened starts with no row lit, and
    /// Down then lands on the first.
    public init(at origin: Point, highlightingFirstRow: Bool = true, entries: @escaping @MainActor () -> [Entry]) {
        self.highlightsFirstRow = highlightingFirstRow
        self.origin = origin
        anchor = nil
        root = entries
        super.init()
    }

    /// A dropdown of `entries` hanging from `anchor` (window points), the button that opens it; its checked row, or else
    /// its first when `highlightingFirstRow`, starts highlighted.
    public init(anchor: Rect, highlightingFirstRow: Bool = true, entries: @escaping @MainActor () -> [Entry]) {
        highlightsFirstRow = highlightingFirstRow
        origin = Point(x: anchor.minX, y: anchor.maxY)
        self.anchor = anchor
        root = entries
        super.init()
    }

    public override var isFocusScope: Bool { true }
    public override var isPointerInteractive: Bool { true }
    public override var cursor: Cursor { .default }
    public override var accessibilityRole: AccessibilityRole { .menu }
    public override var preferredFocusView: View? { panels.last?.firstRow }

    public func present(in window: Window) {
        returnFocus = window.focusedView
        window.contentView.addSubview(self)
        frame = window.contentView.bounds
        let panel = ContextMenuPanel(menu: self, level: 0, build: root)
        panels = [panel]
        addSubview(panel)
        place(panel, beside: nil)
        let checked = panel.rows.first { $0.isChecked }
        if let start = checked ?? panel.firstRow { window.focus.focus(start, animated: false) }
        if checked == nil && !highlightsFirstRow { panel.highlighted = nil }
    }

    public func dismiss() {
        guard superview != nil else { return }
        pendingHover?.cancel()
        if let focus = returnFocus, focus.window != nil { window?.focus.focus(focus, animated: false) }
        removeFromSuperview()
        onDismiss?()
    }

    // MARK: Panels

    /// Opens the submenu of `row` beside it, closing any deeper panel first; `focusing` moves the keyboard into it.
    func open(_ row: ContextMenuRow, focusing: Bool) {
        guard case .submenu(_, _, _, let isEnabled, let entries) = row.entry, isEnabled, let parent = row.panel else { return }
        pendingHover?.cancel()
        parent.highlighted = row
        if let open = child(of: parent), open.opener === row {
            if focusing, let first = open.firstRow { window?.focus.focus(first, animated: false) }
            return
        }
        close(below: parent.level)
        let panel = ContextMenuPanel(menu: self, level: parent.level + 1, build: entries)
        panel.opener = row
        panel.openerIndex = parent.rows.firstIndex { $0 === row }
        panel.openerTitle = row.accessibilityLabel
        panels.append(panel)
        addSubview(panel)
        place(panel, beside: row)
        if focusing, let first = panel.firstRow { window?.focus.focus(first, animated: false) }
    }

    /// The submenu open from a row of `panel`.
    func child(of panel: ContextMenuPanel) -> ContextMenuPanel? {
        panels.first { $0.level == panel.level + 1 }
    }

    /// The pointer came onto `row`. It takes the highlight at once, unless the pointer is on its way into a submenu open
    /// from another row of the same panel: then the row waits until the pointer rests on it.
    func pointerEntered(_ row: ContextMenuRow) {
        pendingHover?.cancel()
        guard let panel = row.panel else { return }
        if let open = child(of: panel), open.opener !== row, isAiming(at: open) {
            schedule(after: Self.aimDelay) { [weak self, weak row] in
                guard let self, let row, row.isHovered else { return }
                self.settle(on: row)
            }
            return
        }
        settle(on: row)
    }

    /// Highlights `row` under the pointer, gives it the keyboard, and after a rest opens its submenu or closes another's.
    private func settle(on row: ContextMenuRow) {
        guard let panel = row.panel else { return }
        guard row.canBecomeFocused else {
            if child(of: panel) == nil { panel.highlighted = nil }
            return
        }
        window?.focus.focus(row, animated: false, reveal: false)
        panel.highlighted = row
        let opened = child(of: panel)
        if opened?.opener === row || (opened == nil && !row.isSubmenu) { return }
        schedule(after: Self.hoverDelay) { [weak self, weak row] in
            guard let self, let row, row.window != nil, let panel = row.panel, panel.highlighted === row else { return }
            if row.isSubmenu { self.open(row, focusing: false) } else { self.close(below: panel.level) }
        }
    }

    private func schedule(after delay: Double, _ work: @escaping @MainActor () -> Void) {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        pendingHover = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Notes where the pointer is (window points), for `isAiming(at:)`.
    func track(_ point: Point) {
        trail.append(point)
        if trail.count > 6 { trail.removeFirst(trail.count - 6) }
    }

    /// Whether the pointer is moving into `panel`: its newest position lies in the triangle from a few moves ago to the
    /// panel's near edge (Amazon's menu aim, as macOS does it), with some slack above and below the panel.
    private func isAiming(at panel: ContextMenuPanel) -> Bool {
        guard trail.count >= 2, let now = trail.last else { return false }
        let from = trail[max(0, trail.count - 4)]
        let slack = Theme.current.metrics.tv(40)
        let edge = panel.frame.minX >= from.x ? panel.frame.minX : panel.frame.maxX
        let top = Point(x: edge, y: panel.frame.minY - slack)
        let bottom = Point(x: edge, y: panel.frame.maxY + slack)
        return Self.triangle(from, top, bottom, contains: now)
    }

    static func triangle(_ a: Point, _ b: Point, _ c: Point, contains p: Point) -> Bool {
        func side(_ p1: Point, _ p2: Point, _ p3: Point) -> Float { (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y) }
        let d1 = side(p, a, b)
        let d2 = side(p, b, c)
        let d3 = side(p, c, a)
        let negative = d1 < 0 || d2 < 0 || d3 < 0
        let positive = d1 > 0 || d2 > 0 || d3 > 0
        return !(negative && positive)
    }

    /// Closes every panel deeper than `level`.
    func close(below level: Int) {
        for panel in panels where panel.level > level { panel.removeFromSuperview() }
        panels.removeAll { $0.level > level }
        if let parent = panels.first(where: { $0.level == level }), let focused = window?.focusedView as? ContextMenuRow, focused.panel === parent {
            parent.highlighted = focused
        }
        panels.forEach { $0.setNeedsDisplay() }
    }

    /// Closes the innermost panel, handing the keyboard back to the row that opened it, or the menu when it is the first.
    func closeInnermost() {
        guard let last = panels.last, last.level > 0 else {
            dismiss()
            return
        }
        let opener = last.opener
        close(below: last.level - 1)
        if let opener {
            window?.focus.focus(opener, animated: false)
            opener.panel?.highlighted = opener
        }
    }

    /// Runs `action`, then closes the menu or, when it keeps the menu open, rebuilds every panel so it shows what changed.
    func perform(_ action: Action) {
        guard action.isEnabled else { return }
        if action.keepsOpen {
            action.run()
            reloadAll()
        } else {
            dismiss()
            action.run()
        }
    }

    /// Rebuilds every panel, outermost first, and ties each submenu back to the rebuilt row it opened from.
    func reloadAll() {
        for panel in panels {
            panel.reload()
            guard let parent = panels.first(where: { $0.level == panel.level - 1 }) else { continue }
            let byTitle = parent.rows.firstIndex { $0.accessibilityLabel == panel.openerTitle && $0.isSubmenu }
            if let index = byTitle ?? panel.openerIndex, index < parent.rows.count {
                panel.opener = parent.rows[index]
                panel.openerIndex = index
                parent.highlighted = parent.rows[index]
            }
        }
        for panel in panels { place(panel, beside: panel.opener) }
    }

    /// Whether a panel deeper than `panel` is open from `row`.
    func isOpen(from row: ContextMenuRow) -> Bool {
        panels.contains { $0.opener === row }
    }

    /// Puts `panel` at the pointer (the first) or beside the row it opens from, with its first row level with that row,
    /// flipping to the other side where it would leave the window and keeping inside it; a panel taller than the window
    /// gets the window's height and scrolls.
    private func place(_ panel: ContextMenuPanel, beside row: ContextMenuRow?) {
        let metrics = Theme.current.metrics
        let content = panel.preferredSize(scale: window?.scale ?? 1)
        let margin = metrics.tv(16)
        var size = Size(width: content.width, height: min(content.height, max(bounds.height - margin * 2, metrics.tv(120))))
        var x: Float
        var y: Float
        if let row, let parent = row.panel {
            let rowFrame = row.frameInWindow
            let overlap = metrics.tv(4)
            x = parent.frame.maxX - overlap
            if x + size.width > bounds.width - margin { x = parent.frame.minX - size.width + overlap }
            y = rowFrame.minY - ContextMenuPanel.padding
        } else if let anchor {
            let gap = metrics.tv(8)
            size.width = max(size.width, anchor.width)
            x = anchor.minX
            y = anchor.maxY + gap
            if y + size.height > bounds.height - margin, anchor.minY - gap - size.height >= margin { y = anchor.minY - gap - size.height }
        } else {
            x = origin.x
            y = origin.y
            if x + size.width > bounds.width - margin { x = origin.x - size.width }
            if y + size.height > bounds.height - margin { y = max(origin.y - size.height, bounds.height - margin - size.height) }
        }
        x = min(max(x, margin), max(bounds.width - size.width - margin, margin))
        y = min(max(y, margin), max(bounds.height - size.height - margin, margin))
        panel.frame = Rect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// Follows the window: the menu covers it and its panels stay inside it.
    public override func layoutSubviews() {
        if let parent = superview, frame.size != parent.bounds.size { frame = parent.bounds }
        for panel in panels { place(panel, beside: panel.opener) }
    }

    // MARK: Input

    public override func keyPressed(_ event: KeyEvent) -> Bool {
        switch event.key {
        case .escape, .back:
            closeInnermost()
            return true
        case .tab, .leftTab:
            return true
        default:
            return false
        }
    }

    public override func pointerMoved(to point: Point) { track(point) }

    public override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        if !panels.contains(where: { $0.frame.contains(point) }) { dismiss() }
        return true
    }

    public override func scrolled(_ event: ScrollEvent) -> Bool { true }
}

/// One frosted sheet of a context menu: its rows from `build`, rebuilt on `reload`, in a scroll view for when the panel is
/// taller than the window.
@MainActor
final class ContextMenuPanel: View {
    static var padding: Float { Theme.current.metrics.tv(8) }

    unowned let menu: ContextMenuView
    let level: Int
    /// The submenu row this panel opened from, and where it sits among its panel's rows (rows are rebuilt on reload).
    weak var opener: ContextMenuRow?
    var openerIndex: Int?
    var openerTitle: String?
    /// The one row drawn highlighted.
    weak var highlighted: ContextMenuRow? {
        didSet {
            guard highlighted !== oldValue else { return }
            oldValue?.setNeedsDisplay()
            highlighted?.setNeedsDisplay()
        }
    }
    private let build: @MainActor () -> [ContextMenuView.Entry]
    private(set) var rows: [ContextMenuRow] = []
    private let scroller = ScrollView(axis: .vertical)
    private var appear = Animated(0)

    init(menu: ContextMenuView, level: Int, build: @escaping @MainActor () -> [ContextMenuView.Entry]) {
        self.menu = menu
        self.level = level
        self.build = build
        super.init()
        scroller.wheelStep = Theme.current.metrics.tv(54) * 3
        addSubview(scroller)
        reload()
        appear.set(1, animation: .timed(duration: 0.1, curve: .easeOut))
        startAnimating()
    }

    var firstRow: ContextMenuRow? { rows.first { $0.canBecomeFocused } }

    /// The rows the keyboard can land on, in order.
    var focusableRows: [ContextMenuRow] { rows.filter(\.canBecomeFocused) }

    override var isFocusScope: Bool { false }
    override var isPointerInteractive: Bool { true }

    /// Rebuilds the rows from the entries, keeping the keyboard on the row at the same place.
    func reload() {
        let focusedIndex = rows.firstIndex { $0.isFocused }
        let highlightedIndex = rows.firstIndex { $0 === highlighted }
        rows.forEach { $0.removeFromSuperview() }
        rows = build().map { ContextMenuRow(entry: $0, panel: self) }
        rows.forEach(scroller.addSubview)
        setNeedsLayout()
        if let index = highlightedIndex, index < rows.count, rows[index].canBecomeFocused { highlighted = rows[index] }
        if let focusedIndex, focusedIndex < rows.count, rows[focusedIndex].canBecomeFocused {
            window?.focus.focus(rows[focusedIndex], animated: false)
        }
    }

    /// The width of the value between a stepper's − and +, the same for every stepper of the panel so they line up.
    private(set) var stepperValueWidth: Float = 0

    func preferredSize(scale: Float) -> Size {
        let metrics = Theme.current.metrics
        stepperValueWidth = rows.map { $0.stepperValueWidth(scale: scale) }.max() ?? 0
        let widest = rows.map { $0.preferredWidth(scale: scale, valueWidth: stepperValueWidth) }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + Self.padding * 2
        return Size(width: min(max(widest, metrics.tv(380)), metrics.tv(900)).rounded(.up), height: height)
    }

    override func layoutSubviews() {
        scroller.frame = bounds
        var y = Self.padding
        let inset = Self.padding
        for row in rows {
            row.frame = Rect(x: inset, y: y, width: bounds.width - inset * 2, height: row.height)
            y += row.height
        }
        scroller.contentLength = y + Self.padding
        scroller.revealInsets = EdgeInsets(top: Self.padding, leading: 0, bottom: Self.padding, trailing: 0)
    }

    /// Scrolls `row` into view when the panel scrolls.
    func reveal(_ row: ContextMenuRow) {
        scroller.reveal(row.frame, of: row, animated: false)
    }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool { true }

    override func pointerMoved(to point: Point) { menu.track(frameInWindow.origin + point) }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = appear.advance(dt)
        setNeedsDisplay()
        return moving
    }

    override func draw(_ context: inout DrawContext) {
        context.faded(appear.value) { faded in
            ContextMenuPanel.drawSheet(in: bounds, scale: window?.scale ?? 1, context: &faded)
        }
        for row in rows { row.alpha = appear.value }
    }

    /// The menu's sheet (`GlassStyle.frostedSheet`), in the appearance's own colour with a veil that keeps rows legible
    /// over any frame.
    static func drawSheet(in rect: Rect, scale: Float, context: inout DrawContext) {
        GlassStyle.frostedSheet(in: rect, radius: Theme.current.metrics.radiusS, scale: scale, dark: Theme.current.palette.appearance == .dark,
                                veil: 0.84, context: &context)
    }
}

/// One row of a context menu panel. Every row keeps a leading column for its symbol or checkmark, so titles line up; the
/// trailing side holds the shortcut, the current value of a submenu and its chevron, or a stepper's − value +.
@MainActor
final class ContextMenuRow: View {
    let entry: ContextMenuView.Entry
    weak var panel: ContextMenuPanel?
    private static var typed = ""
    private static var typedAt = Date.distantPast

    init(entry: ContextMenuView.Entry, panel: ContextMenuPanel) {
        self.entry = entry
        self.panel = panel
        super.init()
    }

    var height: Float {
        let metrics = Theme.current.metrics
        switch entry {
        case .separator: return metrics.tv(17)
        case .section: return metrics.tv(46)
        case .action(let action) where action.detail != nil: return metrics.tv(78)
        default: return metrics.tv(56)
        }
    }

    var isSubmenu: Bool {
        if case .submenu = entry { return true }
        return false
    }

    var isChecked: Bool {
        if case .action(let action) = entry { return action.isChecked && action.isEnabled }
        return false
    }

    private var isEnabled: Bool {
        switch entry {
        case .action(let action): action.isEnabled
        case .stepper: true
        case .submenu(_, _, _, let isEnabled, _): isEnabled
        case .separator, .section: false
        }
    }

    override var canBecomeFocused: Bool { isEnabled }

    override var isPointerInteractive: Bool {
        switch entry {
        case .separator, .section: false
        default: true
        }
    }

    override var cursor: Cursor { .default }

    override var accessibilityLabel: String? {
        switch entry {
        case .action(let action): action.title
        case .stepper(let stepper): stepper.title
        case .submenu(let title, _, _, _, _): title
        case .section(let title): title
        case .separator: nil
        }
    }

    override var accessibilityRole: AccessibilityRole { .menuItem }

    override var accessibilityValue: String? {
        switch entry {
        case .action(let action): [action.detail, action.shortcut].compactMap { $0 }.joined(separator: ", ")
        case .stepper(let stepper): stepper.value
        case .submenu(_, let detail, _, _, _): detail
        default: nil
        }
    }

    override var accessibilityIsSelected: Bool? {
        if case .action(let action) = entry, action.isChecked { return true }
        return nil
    }

    private var isHighlighted: Bool { canBecomeFocused && panel?.highlighted === self }

    private var menu: ContextMenuView? { panel?.menu }

    // MARK: Metrics

    private var leading: Float { Theme.current.metrics.tv(64) }
    private var trailingInset: Float { Theme.current.metrics.tv(22) }

    func stepperValueWidth(scale: Float) -> Float {
        guard case .stepper(let stepper) = entry else { return 0 }
        let metrics = Theme.current.metrics
        return max(metrics.tv(96), TextLayout(stepper.value, font: Theme.current.type.callout, maxLines: 1, scale: scale).size.width + metrics.tv(24)).rounded(.up)
    }

    func preferredWidth(scale: Float, valueWidth: Float) -> Float {
        let theme = Theme.current
        let metrics = theme.metrics
        func width(_ text: String?, _ font: Font) -> Float {
            text.map { TextLayout($0, font: font, maxLines: 1, scale: scale).size.width } ?? 0
        }
        let edges = leading + trailingInset + ContextMenuPanel.padding * 2
        switch entry {
        case .action(let action):
            let shortcut = action.shortcut.map { width($0, theme.type.cardSubtitle) + metrics.tv(48) } ?? 0
            return max(width(action.title, theme.type.callout), width(action.detail, theme.type.cardSubtitle)) + shortcut + edges + metrics.tv(12)
        case .stepper(let stepper):
            return width(stepper.title, theme.type.callout) + valueWidth + stepperButton * 2 + metrics.tv(40) + edges
        case .submenu(let title, let detail, _, _, _):
            let value = detail.map { width($0, theme.type.cardSubtitle) + metrics.tv(36) } ?? 0
            return width(title, theme.type.callout) + value + metrics.tv(64) + edges
        case .section(let title):
            return width(title.uppercased(), theme.type.caption2) + edges
        case .separator:
            return 0
        }
    }

    private var stepperButton: Float { Theme.current.metrics.tv(40) }

    /// The − and + targets of a stepper row and the value between them, at its trailing edge.
    private var stepperZones: (minus: Rect, plus: Rect, value: Rect) {
        let side = stepperButton
        let valueWidth = max(panel?.stepperValueWidth ?? 0, Theme.current.metrics.tv(96))
        let plus = Rect(x: bounds.width - trailingInset + Theme.current.metrics.tv(8) - side, y: bounds.midY - side / 2, width: side, height: side)
        let value = Rect(x: plus.minX - valueWidth, y: bounds.minY, width: valueWidth, height: bounds.height)
        let minus = Rect(x: value.minX - side, y: plus.minY, width: side, height: side)
        return (minus, plus, value)
    }

    // MARK: Pointer

    override func focusDidChange(focused: Bool, animated: Bool) {
        guard focused, let panel else { return }
        panel.highlighted = self
    }

    override func pointerEntered() { menu?.pointerEntered(self) }

    override func pointerMoved(to point: Point) { menu?.track(frameInWindow.origin + point) }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool { button == .primary && canBecomeFocused }

    override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        guard button == .primary, inside else { return }
        switch entry {
        case .stepper(let stepper):
            let zones = stepperZones
            if zones.minus.insetBy(-6, -6).contains(point) { step(stepper.decrease) }
            else if zones.plus.insetBy(-6, -6).contains(point) { step(stepper.increase) }
            else if let reset = stepper.reset { step(reset) }
        default:
            activate()
        }
    }

    override func activate() {
        switch entry {
        case .action(let action): menu?.perform(action)
        case .submenu: menu?.open(self, focusing: true)
        case .stepper(let stepper): if let reset = stepper.reset { step(reset) }
        case .separator, .section: break
        }
    }

    // MARK: Keyboard

    override func keyPressed(_ event: KeyEvent) -> Bool {
        guard event.modifiers.subtracting(.shift).isEmpty else { return false }
        switch (entry, event.key) {
        case (.stepper(let stepper), .left):
            step(stepper.decrease)
        case (.stepper(let stepper), .right):
            step(stepper.increase)
        case (.submenu, .right):
            menu?.open(self, focusing: true)
        case (_, .left):
            if let panel, panel.level > 0 { menu?.closeInnermost() }
        case (_, .right):
            break
        case (_, let key) where key.isActivation && panel?.highlighted !== self:
            break
        case (_, .up):
            move { rows, index in index.map { ($0 - 1 + rows.count) % rows.count } ?? rows.count - 1 }
        case (_, .down):
            move { rows, index in index.map { ($0 + 1) % rows.count } ?? 0 }
        case (_, .home), (_, .pageUp):
            move { _, _ in 0 }
        case (_, .end), (_, .pageDown):
            move { rows, _ in rows.count - 1 }
        default:
            guard let text = event.typedText, !(text == " " && Self.typed.isEmpty) else { return false }
            typeAhead(text)
        }
        return true
    }

    /// Moves the keyboard to the row `pick` chooses among the panel's focusable rows, given the highlighted row's place
    /// among them (nil when none is, as in a menu the pointer opened).
    private func move(_ pick: ([ContextMenuRow], Int?) -> Int) {
        guard let panel else { return }
        let rows = panel.focusableRows
        guard !rows.isEmpty else { return }
        land(on: rows[pick(rows, rows.firstIndex { $0 === self && panel.highlighted === self })])
    }

    /// Gives `target` the keyboard and the highlight, scrolled into view, and closes a submenu open from another row.
    private func land(on target: ContextMenuRow) {
        guard let panel, let menu else { return }
        window?.focus.focus(target, animated: false)
        panel.highlighted = target
        panel.reveal(target)
        if let open = menu.child(of: panel), open.opener !== target { menu.close(below: panel.level) }
    }

    /// Jumps to the next row whose title starts with what was typed in the last second, as a desktop menu's type-ahead.
    private func typeAhead(_ text: String) {
        let now = Date()
        Self.typed = now.timeIntervalSince(Self.typedAt) > 1 ? text : Self.typed + text
        Self.typedAt = now
        guard let rows = panel?.focusableRows, !rows.isEmpty else { return }
        let start = (rows.firstIndex { $0 === self } ?? -1) + (Self.typed.count == 1 ? 1 : 0)
        let ordered = (0..<rows.count).map { rows[(max(start, 0) + $0) % rows.count] }
        if let match = ordered.first(where: { $0.accessibilityLabel?.lowercased().hasPrefix(Self.typed.lowercased()) == true }) {
            land(on: match)
        }
    }

    private func step(_ change: @MainActor () -> Void) {
        change()
        menu?.reloadAll()
    }

    // MARK: Drawing

    override func draw(_ context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        guard let scale = window?.scale else { return }
        let dark = theme.palette.appearance == .dark
        let tone: Float = dark ? 0 : 1
        let label = GlassStyle.label(tone: tone)
        let secondary = GlassStyle.secondaryLabel(tone: tone)
        if isHighlighted {
            context.fill(bounds, radius: metrics.radiusS - ContextMenuPanel.padding / 2,
                         color: dark ? Color.white.withAlpha(0.16) : Color.black.withAlpha(0.09))
        }
        func centred(_ layout: TextLayout) -> Float { ((bounds.height - layout.size.height) / 2 * scale).rounded() / scale }
        let iconSide = metrics.tv(28)
        let iconRect = Rect(x: (leading - iconSide) / 2, y: bounds.midY - iconSide / 2, width: iconSide, height: iconSide)
        switch entry {
        case .separator:
            context.fill(Rect(x: metrics.tv(14), y: (bounds.midY * scale).rounded() / scale, width: bounds.width - metrics.tv(28), height: 1 / scale),
                         color: secondary.withAlpha(0.3))
        case .section(let title):
            let layout = TextLayout(title.uppercased(), font: theme.type.caption2, maxLines: 1, scale: scale)
            context.text(layout, at: Point(x: leading, y: bounds.height - layout.size.height - metrics.tv(8)), color: secondary)
        case .action(let action):
            var color = action.isDestructive ? GlassStyle.destructiveLabel(tone: tone) : label
            if !action.isEnabled { color = color.withAlpha(0.38) }
            if action.isChecked {
                context.symbol("checkmark", in: iconRect.insetBy(metrics.tv(2), metrics.tv(2)), color: color)
            } else if let symbol = action.symbol {
                context.symbol(symbol, in: iconRect, color: color)
            }
            var trailing = trailingInset
            if let shortcut = action.shortcut {
                let keys = TextLayout(shortcut, font: theme.type.cardSubtitle, maxLines: 1, scale: scale)
                context.text(keys, at: Point(x: bounds.width - trailing - keys.size.width, y: centred(keys)),
                             color: action.isEnabled ? secondary : secondary.withAlpha(0.4))
                trailing += keys.size.width + metrics.tv(36)
            }
            let width = bounds.width - leading - trailing
            let title = TextLayout(action.title, font: theme.type.callout, maxWidth: width, maxLines: 1, scale: scale)
            if let detail = action.detail {
                let sub = TextLayout(detail, font: theme.type.cardSubtitle, maxWidth: width, maxLines: 1, scale: scale)
                let top = ((bounds.height - title.size.height - sub.size.height) / 2 * scale).rounded() / scale
                context.text(title, at: Point(x: leading, y: top), color: color)
                context.text(sub, at: Point(x: leading, y: top + title.size.height), color: action.isEnabled ? secondary : secondary.withAlpha(0.4))
            } else {
                context.text(title, at: Point(x: leading, y: centred(title)), color: color)
            }
        case .submenu(let title, let detail, let symbol, let isEnabled, _):
            let color = isEnabled ? label : label.withAlpha(0.38)
            let chevron = metrics.tv(20)
            context.symbol("chevron.right", in: Rect(x: bounds.width - trailingInset - chevron + metrics.tv(6), y: bounds.midY - chevron / 2,
                                                     width: chevron, height: chevron), color: secondary)
            if let symbol { context.symbol(symbol, in: iconRect, color: color) }
            var trailing = trailingInset + chevron + metrics.tv(14)
            if let detail {
                let value = TextLayout(detail, font: theme.type.cardSubtitle, maxWidth: (bounds.width - leading) * 0.55, maxLines: 1, scale: scale)
                context.text(value, at: Point(x: bounds.width - trailing - value.size.width, y: centred(value)), color: secondary)
                trailing += value.size.width + metrics.tv(28)
            }
            let layout = TextLayout(title, font: theme.type.callout, maxWidth: bounds.width - leading - trailing, maxLines: 1, scale: scale)
            context.text(layout, at: Point(x: leading, y: centred(layout)), color: color)
        case .stepper(let stepper):
            let zones = stepperZones
            if let symbol = stepper.symbol { context.symbol(symbol, in: iconRect, color: label) }
            let title = TextLayout(stepper.title, font: theme.type.callout, maxWidth: zones.minus.minX - leading - metrics.tv(12), maxLines: 1, scale: scale)
            context.text(title, at: Point(x: leading, y: centred(title)), color: label)
            let value = TextLayout(stepper.value, font: theme.type.callout, maxLines: 1, scale: scale)
            context.text(value, at: Point(x: (zones.value.midX - value.size.width / 2).rounded(), y: centred(value)), color: label)
            for (zone, symbol) in [(zones.minus, Symbol("minus")), (zones.plus, Symbol("plus"))] {
                context.fill(zone, radius: zone.height / 2, color: label.withAlpha(dark ? 0.14 : 0.10))
                context.symbol(symbol, in: zone.insetBy(zone.width * 0.3, zone.height * 0.3), color: label)
            }
        }
    }
}

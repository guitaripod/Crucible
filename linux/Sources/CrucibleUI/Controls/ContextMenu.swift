import Foundation
import Kiln

/// A desktop context menu (the player's right click): actions with a checkmark when chosen, steppers that change a value
/// in place with − and +, separators and section labels, and submenus that open beside their row, each panel a glass
/// sheet drawn by the app so it works the same in a window and in full screen. It takes the keyboard while open: Up and
/// Down move, Right or Return opens a submenu, Left closes it, Left and Right on a stepper change its value, Return
/// chooses, Escape closes the innermost panel. A choice closes the menu unless its entry keeps it open, and an entry that
/// keeps it open rebuilds its panel so values and checkmarks stay current.
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
        public var decrease: @MainActor () -> Void
        public var increase: @MainActor () -> Void
        public var reset: (@MainActor () -> Void)?

        public init(_ title: String, value: String, decrease: @escaping @MainActor () -> Void, increase: @escaping @MainActor () -> Void,
                    reset: (@MainActor () -> Void)? = nil) {
            self.title = title
            self.value = value
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
    private let root: @MainActor () -> [Entry]
    private var panels: [ContextMenuPanel] = []
    private weak var returnFocus: View?
    private var pendingOpen: DispatchWorkItem?

    /// A menu of `entries` opening at `origin` (window points), its corner at the pointer as desktop menus open.
    public init(at origin: Point, entries: @escaping @MainActor () -> [Entry]) {
        self.origin = origin
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
        window.focus.setVisible(true)
        window.focus.focus(panel.firstRow, animated: false)
    }

    public func dismiss() {
        guard superview != nil else { return }
        pendingOpen?.cancel()
        if let focus = returnFocus, focus.window != nil { window?.focus.focus(focus, animated: false) }
        removeFromSuperview()
        onDismiss?()
    }

    // MARK: Panels

    /// Opens the submenu of `row` beside it, closing any deeper panel first; `focusing` moves the keyboard into it.
    func open(_ row: ContextMenuRow, focusing: Bool) {
        guard case .submenu(_, _, _, let isEnabled, let entries) = row.entry, isEnabled, let parent = row.panel else { return }
        pendingOpen?.cancel()
        if let open = panels.first(where: { $0.level == parent.level + 1 }), open.opener === row {
            if focusing { window?.focus.focus(open.firstRow, animated: false) }
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
        row.setNeedsDisplay()
        if focusing { window?.focus.focus(panel.firstRow, animated: false) }
    }

    /// Opens `row`'s submenu after a short rest of the pointer on it, as desktop menus do, so a pointer passing over rows on
    /// its way somewhere does not flicker panels open and shut.
    func hovered(_ row: ContextMenuRow) {
        pendingOpen?.cancel()
        guard let panel = row.panel else { return }
        let opened = panels.first(where: { $0.level == panel.level + 1 })
        if opened?.opener === row { return }
        let work = DispatchWorkItem { [weak self, weak row] in
            MainActor.assumeIsolated {
                guard let self, let row, row.window != nil else { return }
                if case .submenu = row.entry {
                    self.open(row, focusing: false)
                } else if let panel = row.panel {
                    self.close(below: panel.level)
                }
            }
        }
        pendingOpen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    /// Closes every panel deeper than `level`.
    func close(below level: Int) {
        for panel in panels where panel.level > level { panel.removeFromSuperview() }
        panels.removeAll { $0.level > level }
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
        window?.focus.focus(opener, animated: false)
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
            }
        }
        for panel in panels { place(panel, beside: panel.opener) }
    }

    /// Whether a panel deeper than `panel` is open from `row`.
    func isOpen(from row: ContextMenuRow) -> Bool {
        panels.contains { $0.opener === row }
    }

    private func place(_ panel: ContextMenuPanel, beside row: ContextMenuRow?) {
        let metrics = Theme.current.metrics
        let size = panel.preferredSize(scale: window?.scale ?? 1)
        let margin = metrics.tv(16)
        var x: Float
        var y: Float
        if let row, let parent = row.panel {
            let rowFrame = row.transformToWindow.apply(row.bounds)
            x = parent.frame.maxX - metrics.tv(6)
            if x + size.width > bounds.width - margin { x = parent.frame.minX - size.width + metrics.tv(6) }
            y = rowFrame.minY - ContextMenuPanel.padding
        } else {
            x = origin.x
            y = origin.y
            if x + size.width > bounds.width - margin { x = origin.x - size.width }
            if y + size.height > bounds.height - margin { y = origin.y - size.height }
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

    public override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        if !panels.contains(where: { $0.frame.contains(point) }) { dismiss() }
        return true
    }

    public override func scrolled(_ event: ScrollEvent) -> Bool { true }
}

/// One glass sheet of a context menu: its rows from `build`, rebuilt on `reload`.
@MainActor
final class ContextMenuPanel: View {
    static var padding: Float { Theme.current.metrics.tv(10) }

    unowned let menu: ContextMenuView
    let level: Int
    /// The submenu row this panel opened from, and where it sits among its panel's rows (rows are rebuilt on reload).
    weak var opener: ContextMenuRow?
    var openerIndex: Int?
    var openerTitle: String?
    private let build: @MainActor () -> [ContextMenuView.Entry]
    private(set) var rows: [ContextMenuRow] = []
    private var tone = GlassTone()
    private var appear = Animated(0)

    init(menu: ContextMenuView, level: Int, build: @escaping @MainActor () -> [ContextMenuView.Entry]) {
        self.menu = menu
        self.level = level
        self.build = build
        super.init()
        reload()
        appear.set(1, animation: .timed(duration: 0.12, curve: .easeOut))
        startAnimating()
    }

    var firstRow: ContextMenuRow? { rows.first { $0.canBecomeFocused } }

    override var isFocusScope: Bool { false }
    override var isPointerInteractive: Bool { true }

    /// Rebuilds the rows from the entries, keeping the keyboard on the row at the same place.
    func reload() {
        let focusedIndex = rows.firstIndex { $0.isFocused }
        rows.forEach { $0.removeFromSuperview() }
        rows = build().map { ContextMenuRow(entry: $0, panel: self) }
        rows.forEach(addSubview)
        setNeedsLayout()
        if let focusedIndex, focusedIndex < rows.count, rows[focusedIndex].canBecomeFocused {
            window?.focus.focus(rows[focusedIndex], animated: false)
        }
    }

    func preferredSize(scale: Float) -> Size {
        let metrics = Theme.current.metrics
        let widest = rows.map { $0.preferredWidth(scale: scale) }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + Self.padding * 2
        return Size(width: min(max(widest, metrics.tv(400)), metrics.tv(900)), height: height)
    }

    override func layoutSubviews() {
        var y = Self.padding
        let inset = Self.padding
        for row in rows {
            row.frame = Rect(x: inset, y: y, width: bounds.width - inset * 2, height: row.height)
            y += row.height
        }
    }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool { true }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [appear.advance(dt), tone.advance(dt)].contains(true)
        setNeedsDisplay()
        return moving
    }

    override func draw(_ context: inout DrawContext) {
        if tone.update(context, rect: bounds) { startAnimating() }
        let radius = Theme.current.metrics.radiusM
        context.faded(appear.value) { faded in
            GlassStyle.capsule(in: bounds, radius: radius, light: Point(x: bounds.midX, y: -bounds.height), floating: true, tone: tone.value, context: &faded)
            if !Theme.current.reduceTransparency { faded.fill(bounds, radius: radius, color: legibilityTint) }
        }
        for row in rows {
            row.alpha = appear.value
            row.panelTone = tone
        }
    }

    /// A menu sits over moving video, so its glass gets more body than a button's: a veil in the glass's own tone under the
    /// rows keeps them readable over a bright or busy frame.
    private var legibilityTint: Color {
        Color.black.mixed(with: .white, amount: tone.value).withAlpha(0.5)
    }
}

/// One row of a context menu panel.
@MainActor
final class ContextMenuRow: View {
    let entry: ContextMenuView.Entry
    weak var panel: ContextMenuPanel?
    /// The panel's tone, which the row's own follows, turning dark over glare right under the row (`GlassTone.update(on:)`).
    var panelTone = GlassTone()
    private var rowTone = GlassTone()
    private var lit = Animated(0)
    private var tone: Float { rowTone.value }

    init(entry: ContextMenuView.Entry, panel: ContextMenuPanel) {
        self.entry = entry
        self.panel = panel
        super.init()
    }

    var height: Float {
        let metrics = Theme.current.metrics
        switch entry {
        case .separator: return metrics.tv(18)
        case .section: return metrics.tv(44)
        case .action(let action) where action.detail != nil: return metrics.tv(76)
        default: return metrics.tv(54)
        }
    }

    var isSubmenu: Bool {
        if case .submenu = entry { return true }
        return false
    }

    override var canBecomeFocused: Bool {
        switch entry {
        case .action(let action): action.isEnabled
        case .stepper: true
        case .submenu(_, _, _, let isEnabled, _): isEnabled
        case .separator, .section: false
        }
    }

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

    func preferredWidth(scale: Float) -> Float {
        let theme = Theme.current
        let metrics = theme.metrics
        func width(_ text: String?, _ font: Font) -> Float {
            text.map { TextLayout($0, font: font, scale: scale).size.width } ?? 0
        }
        switch entry {
        case .action(let action):
            let shortcut = action.shortcut.map { width($0, theme.type.cardSubtitle) + metrics.tv(40) } ?? 0
            let symbol: Float = action.symbol == nil ? 0 : metrics.tv(52)
            return (max(width(action.title, theme.type.callout), width(action.detail, theme.type.cardSubtitle)) + metrics.tv(120) + shortcut + symbol).rounded(.up)
        case .stepper(let stepper):
            return (width(stepper.title, theme.type.callout) + max(width(stepper.value, theme.type.callout), metrics.tv(110)) + metrics.tv(240)).rounded(.up)
        case .submenu(let title, let detail, _, _, _):
            return (width(title, theme.type.callout) + width(detail, theme.type.cardSubtitle) + metrics.tv(170)).rounded(.up)
        case .section(let title):
            return (width(title, theme.type.caption1) + metrics.tv(80)).rounded(.up)
        case .separator:
            return 0
        }
    }

    private func update() {
        lit.set(isFocused || isHovered || (panel.map { _ in menu?.isOpen(from: self) == true } ?? false) ? 1 : 0, animation: .focus)
        startAnimating()
    }

    private var menu: ContextMenuView? { panel?.menu }

    override func focusDidChange(focused: Bool, animated: Bool) { update() }

    override func pointerEntered() {
        if canBecomeFocused { window?.focus.focus(self, animated: true, reveal: false) }
        menu?.hovered(self)
        update()
    }

    override func pointerExited() { update() }

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

    override func keyPressed(_ event: KeyEvent) -> Bool {
        guard event.modifiers.subtracting(.shift).isEmpty else { return false }
        switch (entry, event.key) {
        case (.stepper(let stepper), .left):
            step(stepper.decrease)
            return true
        case (.stepper(let stepper), .right):
            step(stepper.increase)
            return true
        case (.submenu, .right):
            menu?.open(self, focusing: true)
            return true
        case (_, .left):
            guard let panel, panel.level > 0 else { return true }
            menu?.closeInnermost()
            return true
        case (_, .right):
            return true
        default:
            return false
        }
    }

    private func step(_ change: @MainActor () -> Void) {
        change()
        menu?.reloadAll()
    }

    /// The − and + targets of a stepper row, at its trailing edge around the value, which gets the room its text needs.
    private var stepperZones: (minus: Rect, plus: Rect, value: Rect) {
        let metrics = Theme.current.metrics
        let side = metrics.tv(40)
        var valueWidth = metrics.tv(110)
        if case .stepper(let stepper) = entry, let scale = window?.scale {
            valueWidth = max(valueWidth, TextLayout(stepper.value, font: Theme.current.type.callout, maxLines: 1, scale: scale).size.width + metrics.tv(28))
        }
        let plus = Rect(x: bounds.width - metrics.tv(14) - side, y: bounds.midY - side / 2, width: side, height: side)
        let value = Rect(x: plus.minX - valueWidth, y: bounds.minY, width: valueWidth, height: bounds.height)
        let minus = Rect(x: value.minX - side, y: plus.minY, width: side, height: side)
        return (minus, plus, value)
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [lit.advance(dt), rowTone.advance(dt)].contains(true)
        setNeedsDisplay()
        return moving
    }

    override func draw(_ context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        guard let scale = window?.scale else { return }
        if rowTone.update(context, rect: bounds, on: panelTone) { startAnimating() }
        let litValue = canBecomeFocused ? max(lit.value, menu?.isOpen(from: self) == true ? 1 : 0) : 0
        if litValue > 0.01 {
            context.fill(bounds, radius: metrics.radiusS, color: theme.palette.focusFill.withAlpha(litValue))
        }
        let label = GlassStyle.label(tone: tone)
        let secondary = GlassStyle.secondaryLabel(tone: tone).mixed(with: theme.palette.onFocusFillSecondary, amount: litValue)
        let leading = metrics.tv(60)
        func centred(_ layout: TextLayout) -> Float { ((bounds.height - layout.size.height) / 2 * scale).rounded() / scale }
        switch entry {
        case .separator:
            context.fill(Rect(x: metrics.tv(20), y: (bounds.midY * scale).rounded() / scale, width: bounds.width - metrics.tv(40), height: 1 / scale),
                         color: secondary.withAlpha(0.35))
        case .section(let title):
            let layout = TextLayout(title.uppercased(), font: theme.type.caption2, maxLines: 1, scale: scale)
            context.text(layout, at: Point(x: metrics.tv(24), y: bounds.height - layout.size.height - metrics.tv(6)), color: secondary)
        case .action(let action):
            var color = action.isDestructive ? GlassStyle.destructiveLabel(tone: tone) : label
            if !action.isEnabled { color = color.withAlpha(0.4) }
            color = color.mixed(with: theme.palette.onFocusFill, amount: litValue)
            let check = metrics.tv(26)
            if action.isChecked {
                context.symbol("checkmark", in: Rect(x: metrics.tv(20), y: bounds.midY - check / 2, width: check, height: check), color: color)
            }
            var trailing = metrics.tv(20)
            if let symbol = action.symbol {
                let side = metrics.tv(28)
                context.symbol(symbol, in: Rect(x: bounds.width - metrics.tv(20) - side, y: bounds.midY - side / 2, width: side, height: side), color: color)
                trailing += metrics.tv(48)
            }
            if let shortcut = action.shortcut {
                let keys = TextLayout(shortcut, font: theme.type.cardSubtitle, maxLines: 1, scale: scale)
                context.text(keys, at: Point(x: bounds.width - trailing - keys.size.width, y: centred(keys)), color: secondary)
                trailing += keys.size.width + metrics.tv(32)
            }
            let title = TextLayout(action.title, font: theme.type.callout, maxWidth: bounds.width - leading - trailing, maxLines: 1, scale: scale)
            if let detail = action.detail {
                let sub = TextLayout(detail, font: theme.type.cardSubtitle, maxWidth: bounds.width - leading - trailing, maxLines: 1, scale: scale)
                let top = ((bounds.height - title.size.height - sub.size.height) / 2 * scale).rounded() / scale
                context.text(title, at: Point(x: leading, y: top), color: color)
                context.text(sub, at: Point(x: leading, y: top + title.size.height), color: secondary)
            } else {
                context.text(title, at: Point(x: leading, y: centred(title)), color: color)
            }
        case .submenu(let title, let detail, let symbol, let isEnabled, _):
            var color = label.mixed(with: theme.palette.onFocusFill, amount: litValue)
            if !isEnabled { color = color.withAlpha(0.4) }
            let chevron = metrics.tv(22)
            context.symbol("chevron.right", in: Rect(x: bounds.width - metrics.tv(22) - chevron, y: bounds.midY - chevron / 2, width: chevron, height: chevron),
                           color: secondary)
            if let symbol {
                let side = metrics.tv(28)
                context.symbol(symbol, in: Rect(x: metrics.tv(20), y: bounds.midY - side / 2, width: side, height: side), color: color)
            }
            var trailing = metrics.tv(60)
            if let detail {
                let value = TextLayout(detail, font: theme.type.cardSubtitle, maxLines: 1, scale: scale)
                context.text(value, at: Point(x: bounds.width - trailing - value.size.width, y: centred(value)), color: secondary)
                trailing += value.size.width + metrics.tv(24)
            }
            let layout = TextLayout(title, font: theme.type.callout, maxWidth: bounds.width - leading - trailing, maxLines: 1, scale: scale)
            context.text(layout, at: Point(x: leading, y: centred(layout)), color: color)
        case .stepper(let stepper):
            let color = label.mixed(with: theme.palette.onFocusFill, amount: litValue)
            let zones = stepperZones
            let title = TextLayout(stepper.title, font: theme.type.callout, maxWidth: zones.minus.minX - leading - metrics.tv(12), maxLines: 1, scale: scale)
            context.text(title, at: Point(x: leading, y: centred(title)), color: color)
            let value = TextLayout(stepper.value, font: theme.type.callout, maxLines: 1, scale: scale)
            context.text(value, at: Point(x: (zones.value.midX - value.size.width / 2).rounded(), y: centred(value)), color: color)
            for (zone, symbol) in [(zones.minus, Symbol("minus")), (zones.plus, Symbol("plus"))] {
                context.fill(zone, radius: zone.height / 2, color: color.withAlpha(0.14))
                context.symbol(symbol, in: zone.insetBy(zone.width * 0.28, zone.height * 0.28), color: color)
            }
        }
    }
}

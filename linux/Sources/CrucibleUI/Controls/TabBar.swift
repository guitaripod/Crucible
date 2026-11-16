import Foundation
import Kiln

/// The Apple TV's top tab bar in Liquid Glass: a floating capsule of tabs whose selection is a liquid pill that slides
/// on a spring between them. The focused tab (keyboard) turns into the light pill with dark text; the pointer lights
/// the glass where it rests. It slides up and away as content scrolls, except where a screen keeps it (Search). In a
/// window too narrow for every title, the tabs show their symbols instead.
@MainActor
public final class TabBarView: View {
    public struct Tab: Hashable, Sendable {
        public var id: String
        public var title: String
        public var symbol: Symbol?

        public init(id: String, title: String, symbol: Symbol? = nil) {
            self.id = id
            self.title = title
            self.symbol = symbol
        }
    }

    public var tabs: [Tab] = [] { didSet { rebuild() } }
    public private(set) var selectedID: String?
    /// The menu button's identity among the tab items.
    static let menuID = "tabbar.menu"
    public override var accessibilityRole: AccessibilityRole { .tabList }
    public var onSelect: ((Tab) -> Void)?
    /// When set, a menu button closes the bar's end and opens the app's menu, told where the button sits in the window.
    public var onMenu: ((Rect) -> Void)? { didSet { rebuild() } }
    /// The menu button's name, read to assistive tech.
    public var menuTitle = "Menu" { didSet { rebuild() } }

    private var items: [TabItemView] = []
    private var menuItem: TabItemView?
    private var pillX = Animated(0)
    private var pillWidth = Animated(0)
    private var hidden = Animated(0)
    private var pointer: Point?
    private(set) var tone = GlassTone()

    public override init(frame: Rect = .zero) {
        super.init(frame: frame)
    }

    public override var remembersFocus: Bool { true }
    public override var preferredFocusView: View? { items.first { $0.tab.id == selectedID } ?? items.first }
    public override var overdraw: Float { Theme.current.metrics.tv(60) }

    public func select(_ id: String, animated: Bool) {
        selectedID = id
        for item in items { item.isSelected = item.tab.id == id }
        movePill(animated: animated)
    }

    /// Slides the bar away (content scrolled down) or back.
    public func setHidden(_ isHidden: Bool, animated: Bool) {
        hidden.set(isHidden ? 1 : 0, animation: animated ? .timed(duration: 0.3, curve: .easeInOut) : nil)
        startAnimating()
    }

    /// Where the menu button sits in the window, for a menu opened from the keyboard (F10).
    public var menuAnchor: Rect? {
        menuItem.map { $0.transformToWindow.apply($0.bounds) }
    }

    private func rebuild() {
        menuItem?.removeFromSuperview()
        menuItem = nil
        for item in items { item.removeFromSuperview() }
        items = tabs.map { tab in
            let item = TabItemView(tab: tab)
            item.onPress = { [weak self] in
                guard let self else { return }
                self.select(tab.id, animated: true)
                self.onSelect?(tab)
            }
            item.isSelected = tab.id == selectedID
            addSubview(item)
            return item
        }
        if onMenu != nil {
            let item = TabItemView(tab: Tab(id: TabBarView.menuID, title: menuTitle, symbol: "line.3.horizontal"))
            item.isCompact = true
            item.onPress = { [weak self, weak item] in
                guard let self, let item else { return }
                self.onMenu?(item.transformToWindow.apply(item.bounds))
            }
            addSubview(item)
            menuItem = item
        }
        setNeedsLayout()
    }

    /// Whether every title fits in the window beside the side margins; when not, the tabs show their symbols.
    private func updateCompactness() {
        let metrics = Theme.current.metrics
        let titled = items.reduce(Float(0)) { $0 + $1.titledWidth } + (menuItem?.preferredWidth ?? 0) + metrics.tv(12) * 2
        let compact = titled > frame.width - metrics.sideMargin * 2 && items.allSatisfy { $0.tab.symbol != nil }
        for item in items where item.isCompact != compact { item.isCompact = compact }
    }

    /// The capsule's frame, centred along the top.
    private var capsule: Rect {
        let metrics = Theme.current.metrics
        let content = items.reduce(Float(0)) { $0 + $1.preferredWidth } + (menuItem?.preferredWidth ?? 0)
        let width = content + metrics.tv(12) * 2
        return Rect(x: ((frame.width - width) / 2).rounded(), y: metrics.tabBarTop, width: width, height: metrics.tabBarHeight)
    }

    public override func layoutSubviews() {
        updateCompactness()
        let bar = capsule
        var x = bar.x + Theme.current.metrics.tv(12)
        let inset = Theme.current.metrics.tv(8)
        for item in items + [menuItem].compactMap({ $0 }) {
            item.frame = Rect(x: x, y: bar.y + inset, width: item.preferredWidth, height: bar.height - inset * 2)
            x += item.preferredWidth
        }
        movePill(animated: false)
    }

    private func movePill(animated: Bool) {
        guard let selected = items.first(where: { $0.tab.id == selectedID }) else { return }
        let animation: Animation? = animated ? .spring(response: 0.38, dampingFraction: 0.78) : nil
        pillX.set(selected.frame.midX, animation: animation)
        pillWidth.set(selected.frame.width, animation: animation)
        startAnimating()
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [pillX.advance(dt), pillWidth.advance(dt), hidden.advance(dt), tone.advance(dt)].contains(true)
        for item in items { item.tone = tone.value }
        menuItem?.tone = tone.value
        translation = Point(x: 0, y: -hidden.value * (capsule.maxY + Theme.current.metrics.tv(30)))
        alpha = 1 - hidden.value
        setNeedsDisplay()
        return moving
    }

    public override func hitTest(_ point: Point) -> View? {
        let inside = capsule.contains(point)
        pointer = inside ? point : nil
        if inside { setNeedsDisplay() }
        guard inside else { return nil }
        return super.hitTest(point) ?? self
    }

    public override var isPointerInteractive: Bool { true }
    public override var cursor: Cursor { .default }

    public override func draw(_ context: inout DrawContext) {
        let bar = capsule
        let light = pointer ?? Point(x: bar.midX, y: bar.minY - bar.height * 2)
        var pill: Rect?
        if selectedID != nil, pillWidth.value > 0 {
            let inset = Theme.current.metrics.tv(8)
            pill = Rect(x: pillX.value - pillWidth.value / 2, y: bar.y + inset, width: pillWidth.value, height: bar.height - inset * 2)
        }
        if tone.update(context, rect: bar) { startAnimating() }
        for item in items { item.tone = tone.value }
        menuItem?.tone = tone.value
        GlassStyle.capsule(in: bar, light: light, pill: pill, floating: true, tone: tone.value, context: &context)
    }
}

/// One tab: its title (and symbol) on the glass, lit as the light pill while focused.
@MainActor
final class TabItemView: View {
    let tab: TabBarView.Tab
    var isSelected = false { didSet { setNeedsDisplay() } }
    /// Shows the tab's symbol instead of its title, in a window too narrow for every title.
    var isCompact = false { didSet { setNeedsDisplay() } }
    var tone: Float = 0
    var onPress: (() -> Void)?
    private var lift = Animated(0)
    private var hover = Animated(0)

    init(tab: TabBarView.Tab) {
        self.tab = tab
        super.init()
    }

    override var canBecomeFocused: Bool { true }
    override var accessibilityLabel: String? { tab.title }
    override var accessibilityRole: AccessibilityRole { tab.id == TabBarView.menuID ? .button : .tab }
    override var accessibilityIsSelected: Bool? { accessibilityRole == .tab ? isSelected : nil }

    override func tooltip(at point: Point) -> String? { isCompact ? tab.title : nil }

    private var rasterScale: Float { window?.scale ?? 1 }

    private var layout: TextLayout { TextLayout(tab.title, font: Theme.current.type.control, scale: rasterScale) }

    var titledWidth: Float { (layout.size.width + Theme.current.metrics.tabItemInset * 2).rounded(.up) }

    var preferredWidth: Float { isCompact ? (Theme.current.metrics.tabBarHeight * 1.15).rounded(.up) : titledWidth }

    private func update() {
        lift.set(isFocused && (window?.isFocusVisible ?? false) ? 1 : 0, animation: .focus)
        hover.set(isHovered ? 1 : 0, animation: .focus)
        startAnimating()
    }

    override func focusDidChange(focused: Bool, animated: Bool) { update() }
    override func focusVisibilityDidChange(_ visible: Bool) { if isFocused { update() } }
    override func pointerEntered() { update() }
    override func pointerExited() { update() }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard button == .primary else { return false }
        return true
    }

    override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        if button == .primary && inside { onPress?() }
    }

    override func activate() { onPress?() }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [lift.advance(dt), hover.advance(dt)].contains(true)
        setNeedsDisplay()
        return moving
    }

    override func draw(_ context: inout DrawContext) {
        let palette = Theme.current.palette
        let rect = bounds
        if lift.value > 0.01 {
            context.transformed(scale: 1 + 0.06 * lift.value, about: rect.center) { inner in
                inner.shadow(rect, radius: rect.height / 2, blur: Theme.current.metrics.tv(18), offsetY: Theme.current.metrics.tv(8),
                             opacity: 0.3 * lift.value)
                inner.fill(rect, radius: rect.height / 2, color: palette.focusFill.withAlpha(lift.value))
            }
        } else if hover.value > 0.01 && !isSelected {
            context.fill(rect, radius: rect.height / 2, color: palette.label.withAlpha(0.08 * hover.value))
        }
        let base = isSelected ? GlassStyle.label(tone: tone) : GlassStyle.secondaryLabel(tone: tone)
        let color = base.mixed(with: palette.onFocusFill, amount: lift.value)
        if isCompact, let symbol = tab.symbol {
            let side = Theme.current.metrics.symbolRow
            context.symbol(symbol, in: Rect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side), color: color)
            return
        }
        let text = layout
        let x = ((rect.width - text.size.width) / 2 * rasterScale).rounded() / rasterScale
        let y = ((rect.height - text.size.height) / 2 * rasterScale).rounded() / rasterScale
        context.text(text, at: Point(x: x, y: y), color: color)
    }
}

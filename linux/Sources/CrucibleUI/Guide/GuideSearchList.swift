import Foundation
import Kiln

/// One match in the guide's search: a channel, or an airing on now or to come.
public struct GuideSearchItem: Equatable, Sendable {
    public var id: String
    public var logo: ArtworkSource?
    public var title: String
    public var subtitle: String
    /// What the end of the row says: the time left, or when the airing starts.
    public var trailing: String?
    /// How far an airing on now has run, 0 to 1.
    public var progress: Float?

    public init(id: String, logo: ArtworkSource?, title: String, subtitle: String, trailing: String? = nil, progress: Float? = nil) {
        self.id = id
        self.logo = logo
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.progress = progress
    }
}

public struct GuideSearchSection: Equatable, Sendable {
    public var title: String
    public var items: [GuideSearchItem]

    public init(title: String, items: [GuideSearchItem]) {
        self.title = title
        self.items = items
    }
}

/// The guide's search results: sections of rows (a channel's logo, a title, what it is and when), one focus that the
/// arrows, Page Up and Page Down move, the wheel to scroll, a click or Select to open a row and a right click or the Menu
/// key for its menu. Up from the first row leaves the list, back to the search field above it. A note under the rows
/// says when more may come, or that nothing matched.
@MainActor
public final class GuideSearchListView: View {
    public var sections: [GuideSearchSection] = [] {
        didSet {
            guard sections != oldValue else { return }
            let focusedID = items.indices.contains(selection) ? items[selection].id : nil
            items = sections.flatMap(\.items)
            selection = focusedID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
            logos = logos.filter { id, _ in items.contains { $0.id == id } }
            layoutCache.removeAll()
            scrollY.set(clamp(scrollY.target), animation: nil)
            setNeedsDisplay()
        }
    }

    /// A line under the results (or in their place when there are none).
    public var note: String? { didSet { if note != oldValue { setNeedsDisplay() } } }
    public var onActivate: ((GuideSearchItem) -> Void)?
    public var onContextMenu: ((GuideSearchItem, Point) -> Void)?

    private var items: [GuideSearchItem] = []
    private var selection = 0
    private var hovered: Int?
    private var scrollY = Animated(0)
    private var lift = Animated(0)
    private var logos: [String: ArtworkSlot] = [:]
    private var layoutCache: [String: TextLayout] = [:]

    public override init(frame: Rect = .zero) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    public override var canBecomeFocused: Bool { !items.isEmpty }
    public override var isPointerInteractive: Bool { true }
    public override var accessibilityRole: AccessibilityRole { .list }
    public override var accessibilityLabel: String? {
        guard items.indices.contains(selection) else { return note }
        let item = items[selection]
        return [item.title, item.subtitle, item.trailing].compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: Geometry

    private var metrics: Metrics { Theme.current.metrics }
    private var rowHeight: Float { metrics.tv(Theme.current.density == .desk ? 112 : 128) }
    private var headerHeight: Float { metrics.tv(64) }
    private var gap: Float { metrics.tv(8) }

    /// Each row's top and each section heading's, in content points.
    private var placements: (rows: [Float], headings: [(String, Float)], height: Float) {
        var rows: [Float] = []
        var headings: [(String, Float)] = []
        var y: Float = 0
        for section in sections where !section.items.isEmpty {
            headings.append((section.title, y))
            y += headerHeight
            for _ in section.items {
                rows.append(y)
                y += rowHeight + gap
            }
            y += metrics.tv(16)
        }
        return (rows, headings, y)
    }

    private func clamp(_ value: Float) -> Float {
        min(max(value, 0), max(placements.height + metrics.tv(80) - bounds.height, 0))
    }

    private func index(at point: Point) -> Int? {
        let y = point.y + scrollY.value
        return placements.rows.firstIndex { y >= $0 && y < $0 + rowHeight }
    }

    // MARK: Input

    public override func keyPressed(_ event: KeyEvent) -> Bool {
        guard !items.isEmpty, event.modifiers.isEmpty else { return false }
        switch event.key {
        case .up:
            guard selection > 0 else { return false }
            move(to: selection - 1)
        case .down:
            guard selection < items.count - 1 else { return false }
            move(to: selection + 1)
        case .pageUp: move(to: max(selection - 6, 0))
        case .pageDown: move(to: min(selection + 6, items.count - 1))
        case .home: move(to: 0)
        case .end: move(to: items.count - 1)
        default: return false
        }
        return true
    }

    public override func activate() {
        guard items.indices.contains(selection) else { return }
        onActivate?(items[selection])
    }

    public override func showContextMenu(at point: Point?) -> Bool {
        guard items.indices.contains(selection) else { return false }
        let rows = placements.rows
        let anchor = point ?? transformToWindow.apply(Point(x: metrics.tv(120), y: rows[selection] - scrollY.value + rowHeight))
        onContextMenu?(items[selection], anchor)
        return true
    }

    private func move(to index: Int) {
        selection = index
        lift.reset(0.6)
        lift.set(1, animation: .focus)
        reveal()
        startAnimating()
        setNeedsDisplay()
    }

    private func reveal() {
        let rows = placements.rows
        guard rows.indices.contains(selection) else { return }
        let top = rows[selection] - (selection == 0 || sections.first?.items.first?.id == items[selection].id ? headerHeight : 0)
        var target = scrollY.target
        if top < target + metrics.tv(20) { target = top - metrics.tv(20) }
        if rows[selection] + rowHeight > target + bounds.height - metrics.tv(40) { target = rows[selection] + rowHeight - bounds.height + metrics.tv(40) }
        scrollY.set(clamp(target), animation: .scroll)
    }

    public override func scrolled(_ event: ScrollEvent) -> Bool {
        let step = event.notchesY != 0 ? event.notchesY * rowHeight : event.dy
        scrollY.reset(clamp(scrollY.value + step))
        hovered = nil
        setNeedsDisplay()
        return true
    }

    public override func pointerMoved(to point: Point) {
        let hit = index(at: point)
        guard hit != hovered else { return }
        hovered = hit
        setNeedsDisplay()
    }

    public override func pointerExited() {
        hovered = nil
        setNeedsDisplay()
    }

    public override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard let hit = index(at: point) else { return false }
        selection = hit
        window?.focus.focus(self, animated: true, reveal: false)
        setNeedsDisplay()
        switch button {
        case .primary: onActivate?(items[hit])
        case .secondary: onContextMenu?(items[hit], transformToWindow.apply(point))
        default: return false
        }
        return true
    }

    public override func focusDidChange(focused: Bool, animated: Bool) {
        if focused {
            lift.reset(0.6)
            lift.set(1, animation: .focus)
            startAnimating()
        }
        setNeedsDisplay()
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        var moving = scrollY.advance(dt)
        moving = lift.advance(dt) || moving
        for slot in logos.values { moving = slot.advance(dt) || moving }
        setNeedsDisplay()
        return moving
    }

    public override func layoutSubviews() {
        layoutCache.removeAll()
        scrollY.set(clamp(scrollY.target), animation: nil)
    }

    // MARK: Drawing

    private func layout(_ key: String, _ text: String, font: Font, width: Float) -> TextLayout? {
        guard width > metrics.tv(24), let scale = window?.scale else { return nil }
        let cacheKey = "\(key)|\(Int(width))|\(font.size)|\(font.weight.rawValue)"
        if let cached = layoutCache[cacheKey] { return cached }
        let made = TextLayout(text, font: font, maxWidth: width, maxLines: 1, scale: scale)
        layoutCache[cacheKey] = made
        return made
    }

    public override func draw(_ context: inout DrawContext) {
        let theme = Theme.current
        let palette = theme.palette
        let placed = placements
        let offset = scrollY.value
        for (title, top) in placed.headings where top - offset < bounds.height && top - offset + headerHeight > 0 {
            if let label = layout("h\(title)", title, font: theme.type.title3, width: bounds.width) {
                context.text(label, at: Point(x: 0, y: (top - offset + headerHeight - label.size.height - metrics.tv(12)).rounded()), color: palette.label)
            }
        }
        for (index, top) in placed.rows.enumerated() where top - offset < bounds.height && top - offset + rowHeight > 0 {
            drawRow(items[index], y: top - offset, focused: isFocused && index == selection, hovered: hovered == index, in: &context)
        }
        guard let note, let scale = window?.scale else { return }
        let text = TextLayout(note, font: theme.type.callout, maxWidth: bounds.width, scale: scale)
        let y = items.isEmpty ? metrics.tv(24) : placed.height - offset + metrics.tv(8)
        if y < bounds.height { context.text(text, at: Point(x: 0, y: y.rounded()), color: palette.labelSecondary) }
    }

    private func drawRow(_ item: GuideSearchItem, y: Float, focused: Bool, hovered: Bool, in context: inout DrawContext) {
        let theme = Theme.current
        let palette = theme.palette
        var rect = Rect(x: 0, y: y, width: bounds.width, height: rowHeight)
        if focused {
            let grow = metrics.tv(6) * lift.value
            rect = rect.insetBy(-grow, -grow)
            context.shadow(rect, radius: metrics.radiusS, blur: metrics.tv(18), offsetY: metrics.tv(8), opacity: 0.4 * lift.value)
        }
        context.fill(rect, radius: metrics.radiusS, color: focused ? palette.focusFill : (hovered ? palette.surfaceHigh : palette.surface))
        let well = rowHeight - metrics.tv(24)
        let logoRect = Rect(x: rect.minX + metrics.tv(14), y: y + (rowHeight - well) / 2, width: well * 1.5, height: well)
        context.fill(logoRect, radius: metrics.radiusXS, color: palette.surfaceRaised)
        if let logo = item.logo, let scale = window?.scale {
            let slot = logos[item.id] ?? ArtworkSlot(owner: self)
            logos[item.id] = slot
            slot.show(logo, pixelWidth: Int(logoRect.width * scale), pixelHeight: Int(logoRect.height * scale), redraw: false)
            if let texture = slot.texture {
                context.image(texture, in: logoRect.insetBy(metrics.tv(6), metrics.tv(6)), radius: 0, opacity: slot.opacity, fit: true)
            }
        }
        let ink = focused ? palette.onFocusFill : palette.label
        let inkSecondary = focused ? palette.onFocusFillSecondary : palette.labelSecondary
        let left = logoRect.maxX + metrics.tv(20)
        var right = rect.maxX - metrics.tv(20)
        if let trailing = item.trailing, let label = layout("r\(item.id)\(trailing)", trailing, font: theme.type.callout, width: metrics.tv(360)) {
            context.text(label, at: Point(x: (right - label.size.width).rounded(), y: (y + (rowHeight - label.size.height) / 2).rounded()), color: inkSecondary)
            right -= label.size.width + metrics.tv(24)
        }
        let width = right - left
        let title = layout("t\(item.id)", item.title, font: theme.type.cardTitle, width: width)
        let subtitle = item.subtitle.isEmpty ? nil : layout("s\(item.id)\(item.subtitle)", item.subtitle, font: theme.type.cardSubtitle, width: width)
        let barRoom = item.progress == nil ? 0 : metrics.tv(17)
        let block = (title?.size.height ?? 0) + (subtitle.map { $0.size.height + metrics.tv(4) } ?? 0) + barRoom
        var textY = (y + (rowHeight - block) / 2).rounded()
        if let title {
            context.text(title, at: Point(x: left, y: textY), color: ink)
            textY += title.size.height + metrics.tv(4)
        }
        if let subtitle {
            context.text(subtitle, at: Point(x: left, y: textY), color: inkSecondary)
            textY += subtitle.size.height
        }
        if let progress = item.progress {
            let bar = Rect(x: left, y: textY + metrics.tv(12), width: min(width, metrics.tv(420)), height: metrics.tv(5))
            context.fill(bar, radius: bar.height / 2, color: ink.withSRGBAlpha(0.18))
            context.fill(Rect(x: bar.x, y: bar.y, width: max(bar.width * min(max(progress, 0), 1), bar.height), height: bar.height), radius: bar.height / 2,
                         color: focused ? palette.onFocusFill : palette.accent)
        }
    }
}

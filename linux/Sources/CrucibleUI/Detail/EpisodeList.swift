import Foundation
import Kiln

/// A season's episodes as a desktop list (the Desktop layout's stand-in for the episode shelf): one row per episode with
/// its still, number and title, runtime or air date, synopsis and progress, under the season's title. A row lights under
/// the pointer and offers a play button on its still, a watched toggle and a menu button at its end; a click plays (the
/// screen's `onActivate`), a right click or the Menu key opens its menu, Space plays the focused row, Up and Down move.
@MainActor
public final class EpisodeListView: View {
    public var header: SectionHeader? { didSet { if header != oldValue { setNeedsLayout(); setNeedsDisplay() } } }
    public private(set) var items: [CardItem] = []
    public var onActivate: ((CardItem) -> Void)?
    public var onFocus: ((CardItem) -> Void)?
    public var onPlay: ((CardItem) -> Bool)?
    public var onContextMenu: ((CardItem, Point?) -> Void)?
    public var onToggleWatched: ((CardItem) -> Void)?

    private var rows: [String: EpisodeRowView] = [:]
    private var order: [String] = []

    public override init(frame: Rect = .zero) {
        super.init(frame: frame)
    }

    public override var remembersFocus: Bool { true }
    public override var accessibilityRole: AccessibilityRole { .list }
    public override var accessibilityLabel: String? { header?.title }

    /// The row the keyboard lands on first: the one to continue or watch next, else the first.
    public override var preferredFocusView: View? {
        order.lazy.compactMap { self.rows[$0] }.first { $0.item.eyebrow != nil } ?? order.first.flatMap { rows[$0] }
    }

    public func setItems(_ newItems: [CardItem]) {
        items = newItems
        var next: [String: EpisodeRowView] = [:]
        for item in newItems {
            if let row = rows[item.id] {
                row.item = item
                next[item.id] = row
            } else {
                let row = EpisodeRowView(item: item)
                row.list = self
                addSubview(row)
                next[item.id] = row
            }
        }
        for (id, row) in rows where next[id] == nil { row.removeFromSuperview() }
        rows = next
        order = newItems.map(\.id)
        setNeedsLayout()
    }

    public func row(for id: String) -> View? { rows[id] }

    private var headerHeight: Float { header == nil ? 0 : Theme.current.metrics.shelfHeaderHeight }
    static var rowHeight: Float { Theme.current.metrics.tv(250) }
    private static var spacing: Float { Theme.current.metrics.tv(12) }

    public override func sizeThatFits(_ size: Size) -> Size {
        let count = Float(order.count)
        let height = headerHeight + count * Self.rowHeight + max(count - 1, 0) * Self.spacing + Theme.current.metrics.tv(40)
        return Size(width: size.width, height: height.rounded(.up))
    }

    public override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let x = metrics.sideMargin - metrics.tv(16)
        let width = min(frame.width - x * 2, metrics.tv(2600))
        var y = headerHeight
        for id in order {
            rows[id]?.frame = Rect(x: x, y: y, width: width, height: Self.rowHeight)
            y += Self.rowHeight + Self.spacing
        }
    }

    public override func draw(_ context: inout DrawContext) {
        guard let header, let scale = window?.scale else { return }
        let theme = Theme.current
        let title = TextLayout(header.title, font: theme.type.headline, maxLines: 1, scale: scale)
        let top = ((headerHeight - title.size.height) / 2).rounded()
        context.text(title, at: Point(x: theme.metrics.sideMargin, y: top), color: theme.palette.label)
        if let secondary = header.secondaryText, !secondary.isEmpty {
            let layout = TextLayout(secondary, font: theme.type.callout, maxLines: 1, scale: scale)
            context.text(layout, at: Point(x: theme.metrics.sideMargin + title.size.width + theme.metrics.tv(24),
                                           y: top + title.size.height - layout.size.height), color: theme.palette.labelSecondary)
        }
    }

    /// Moves the keyboard to the row after (`step` 1) or before (-1) `row`.
    fileprivate func move(from row: EpisodeRowView, by step: Int) -> Bool {
        guard let index = order.firstIndex(of: row.item.id) else { return false }
        let next = index + step
        guard order.indices.contains(next), let target = rows[order[next]] else { return false }
        window?.focus.focus(target, animated: true)
        return true
    }
}

/// One episode of `EpisodeListView`.
@MainActor
final class EpisodeRowView: View {
    var item: CardItem { didSet { if item != oldValue { setNeedsDisplay() } } }
    weak var list: EpisodeListView?

    private enum Zone: Equatable { case play, watched, menu }

    private lazy var artwork = ArtworkSlot(owner: self)
    private var hover = Animated(0)
    private var hoveredZone: Zone?
    private var pressedZone: Zone?
    private var pressedRow = false

    init(item: CardItem) {
        self.item = item
        super.init()
    }

    override var canBecomeFocused: Bool { true }
    override var accessibilityRole: AccessibilityRole { .listItem }
    override var accessibilityLabel: String? { item.spokenLabel }
    override var accessibilityValue: String? { item.spokenValue }

    // MARK: Geometry

    private var thumb: Rect {
        let metrics = Theme.current.metrics
        let height = bounds.height - metrics.tv(28)
        return Rect(x: metrics.tv(16), y: metrics.tv(14), width: (height * 16 / 9).rounded(), height: height)
    }

    private func zoneRect(_ zone: Zone) -> Rect {
        let metrics = Theme.current.metrics
        let side = metrics.tv(64)
        switch zone {
        case .play:
            let art = thumb
            let play = metrics.tv(88)
            return Rect(x: art.midX - play / 2, y: art.midY - play / 2, width: play, height: play)
        case .menu:
            return Rect(x: bounds.width - metrics.tv(24) - side, y: bounds.midY - side / 2, width: side, height: side)
        case .watched:
            return Rect(x: bounds.width - metrics.tv(24) - side * 2 - metrics.tv(12), y: bounds.midY - side / 2, width: side, height: side)
        }
    }

    private var offeredZones: [Zone] {
        guard let list else { return [] }
        var zones: [Zone] = []
        if list.onPlay != nil { zones.append(.play) }
        if list.onToggleWatched != nil { zones.append(.watched) }
        if list.onContextMenu != nil { zones.append(.menu) }
        return zones
    }

    private func zone(at point: Point) -> Zone? {
        offeredZones.first { zoneRect($0).insetBy(-4, -4).contains(point) }
    }

    // MARK: Pointer and keyboard

    override func pointerEntered() { animateHover() }

    override func pointerExited() {
        hoveredZone = nil
        pressedZone = nil
        pressedRow = false
        animateHover()
    }

    private func animateHover() {
        hover.set(isHovered ? 1 : 0, animation: .timed(duration: 0.12, curve: .easeOut))
        startAnimating()
    }

    override func pointerMoved(to point: Point) {
        let zone = zone(at: point)
        guard zone != hoveredZone else { return }
        hoveredZone = zone
        setNeedsDisplay()
    }

    override func cursor(at point: Point) -> Cursor { .pointer }

    override func tooltip(at point: Point) -> String? {
        switch zone(at: point) {
        case .play: item.hasProgress ? Strings.lookup("Resume") : Strings.lookup("Play")
        case .watched: item.isWatched ? Strings.lookup("Mark as Unwatched") : Strings.lookup("Mark as Watched")
        case .menu: Strings.lookup("More")
        case nil: nil
        }
    }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        switch button {
        case .primary:
            if let zone = zone(at: point) { pressedZone = zone } else { pressedRow = true }
            setNeedsDisplay()
            return true
        case .secondary:
            guard let onContextMenu = list?.onContextMenu else { return false }
            onContextMenu(item, transformToWindow.apply(point))
            return true
        default:
            return false
        }
    }

    override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        guard button == .primary else { return }
        defer {
            pressedZone = nil
            pressedRow = false
            setNeedsDisplay()
        }
        if let pressed = pressedZone {
            guard zone(at: point) == pressed else { return }
            switch pressed {
            case .play: if list?.onPlay?(item) != true { list?.onActivate?(item) }
            case .watched: list?.onToggleWatched?(item)
            case .menu:
                let button = transformToWindow.apply(zoneRect(.menu))
                list?.onContextMenu?(item, Point(x: button.minX, y: button.maxY))
            }
            return
        }
        guard pressedRow, inside else { return }
        window?.focus.focus(self, animated: true, reveal: false)
        list?.onActivate?(item)
    }

    override func activate() { list?.onActivate?(item) }

    override func focusDidChange(focused: Bool, animated: Bool) {
        setNeedsDisplay()
        if focused { list?.onFocus?(item) }
    }

    override func keyPressed(_ event: KeyEvent) -> Bool {
        guard event.modifiers.isEmpty else { return false }
        switch event.key {
        case .up: return list?.move(from: self, by: -1) ?? false
        case .down: return list?.move(from: self, by: 1) ?? false
        case .space, .mediaPlay:
            guard let onPlay = list?.onPlay else { return false }
            return onPlay(item)
        default: return false
        }
    }

    override func showContextMenu(at point: Point?) -> Bool {
        guard let onContextMenu = list?.onContextMenu else { return false }
        let frame = frameInWindow
        onContextMenu(item, point ?? Point(x: frame.minX + thumb.maxX, y: frame.maxY))
        return true
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [hover.advance(dt), artwork.advance(dt)].contains(true)
        setNeedsDisplay()
        return moving
    }

    // MARK: Drawing

    override func draw(_ context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        let palette = theme.palette
        guard let window else { return }
        let scale = window.scale
        let art = thumb
        if artwork.source != item.artwork || (artwork.texture == nil && item.artwork != nil) {
            let width = metrics.imagePixelWidth(points: art.width, scale: scale)
            artwork.show(item.artwork, pixelWidth: width, pixelHeight: Int((Float(width) * 9 / 16).rounded(.up)), redraw: false)
        }
        let focused = isFocused && window.isFocusVisible
        let lit = max(hover.value, pressedRow ? 1 : 0)
        if lit > 0.01 || focused {
            context.fill(bounds, radius: metrics.radiusS, color: palette.label.withAlpha(0.06 + 0.04 * lit))
        }
        if focused { context.stroke(bounds, radius: metrics.radiusS, width: max(metrics.tv(3), 1.5), color: palette.accent) }
        let dim: Float = item.isDimmed && lit < 0.5 ? metrics.watchedDimming : 1
        let radius = metrics.cardCornerRadius
        context.faded(dim) { faded in
            if let texture = artwork.texture, artwork.opacity > 0 {
                if artwork.opacity < 1 { faded.fill(art, radius: radius, color: palette.surfaceRaised) }
                faded.image(texture, in: art, radius: radius, opacity: artwork.opacity)
            } else {
                faded.fill(art, radius: radius, color: palette.surfaceRaised)
                let glyph = art.height * 0.28
                faded.symbol(item.placeholderSymbol, in: Rect(x: art.midX - glyph / 2, y: art.midY - glyph / 2, width: glyph, height: glyph),
                             color: palette.labelTertiary)
            }
            if item.hasProgress, let progress = item.progress {
                let inset = metrics.badgeInset
                let thickness = metrics.progressBarThickness
                ProgressBarStyle.draw(progress: Float(progress), in: Rect(x: art.x + inset, y: art.maxY - inset - thickness, width: art.width - inset * 2,
                                                                          height: thickness), onArt: true, context: &faded)
            }
            drawText(beside: art, scale: scale, context: &faded)
        }
        drawButtons(lit: lit, context: &context)
    }

    private func drawText(beside art: Rect, scale: Float, context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        let palette = theme.palette
        let x = art.maxX + metrics.tv(36)
        let trailing = zoneRect(.watched).minX - metrics.tv(24)
        let width = max(trailing - x, metrics.tv(200))
        var lines: [(TextLayout, Color, Float)] = []
        if let eyebrow = item.eyebrow, !eyebrow.isEmpty {
            lines.append((TextLayout(eyebrow.uppercased(), font: theme.type.eyebrow, maxWidth: width, maxLines: 1, scale: scale), palette.accentText,
                          metrics.tv(6)))
        }
        lines.append((TextLayout(item.title, font: theme.type.headline, maxWidth: width, maxLines: 1, scale: scale), palette.label, metrics.tv(6)))
        if let subtitle = item.subtitle, !subtitle.isEmpty {
            lines.append((TextLayout(subtitle, font: theme.type.callout, maxWidth: width, maxLines: 1, scale: scale), palette.labelSecondary, metrics.tv(10)))
        }
        if let summary = item.summary, !summary.isEmpty {
            lines.append((TextLayout(summary, font: theme.type.body, maxWidth: min(width, metrics.tv(1700)), maxLines: 2, scale: scale),
                          palette.labelSecondary, 0))
        }
        let total = lines.reduce(0) { $0 + $1.0.size.height + $1.2 }
        var y = ((art.midY - total / 2) * scale).rounded() / scale
        for (layout, color, gap) in lines {
            context.text(layout, at: Point(x: x, y: y), color: color)
            y += layout.size.height + gap
        }
    }

    /// The play button on the still and the watched and menu buttons at the row's end, shown under the pointer; the
    /// watched mark stays while the episode is watched.
    private func drawButtons(lit: Float, context: inout DrawContext) {
        let palette = Theme.current.palette
        for zone in offeredZones {
            let rect = zoneRect(zone)
            let isHot = hoveredZone == zone || pressedZone == zone
            let watched = zone == .watched && item.isWatched
            let shown = zone == .play ? lit : max(lit, watched ? 1 : 0)
            guard shown > 0.01 else { continue }
            context.faded(shown) { faded in
                switch zone {
                case .play:
                    faded.fill(rect, radius: rect.width / 2, color: isHot ? palette.accent : Color.shade(0.62))
                    let inset = rect.width * 0.32
                    faded.symbol("play.fill", in: rect.insetBy(inset, inset).offsetBy(rect.width * 0.03, 0), color: palette.onArt)
                case .watched, .menu:
                    let fill = watched ? palette.accent : palette.label.withAlpha(isHot ? 0.18 : 0.08)
                    faded.fill(rect, radius: rect.width / 2, color: fill)
                    let inset = rect.width * 0.28
                    faded.symbol(zone == .watched ? "checkmark" : "ellipsis", in: rect.insetBy(inset, inset),
                                 color: watched ? palette.onArt : palette.label)
                }
            }
        }
    }
}

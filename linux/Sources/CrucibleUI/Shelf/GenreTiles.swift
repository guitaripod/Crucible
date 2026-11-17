import Foundation
import Kiln

/// A heading over a page section that has none of its own (Search's recent searches and genres).
@MainActor
public final class SectionTitleView: View {
    public var title: String { didSet { setNeedsDisplay() } }

    public override var accessibilityRole: AccessibilityRole { title.isEmpty ? .none : .heading }
    public override var accessibilityLabel: String? { title }

    public init(title: String) {
        self.title = title
        super.init()
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: Theme.current.metrics.shelfHeaderHeight * 0.75)
    }

    public override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let theme = Theme.current
        let layout = TextLayout(title, font: theme.type.headline, maxWidth: bounds.width - theme.metrics.sideMargin * 2, scale: scale)
        context.text(layout, at: Point(x: theme.metrics.sideMargin, y: bounds.height - layout.size.height - theme.metrics.tv(8)), color: theme.palette.label)
    }
}

/// A grid of gradient tiles (Search's Browse genres, `TVGenreCell`): each tile its title on a gradient of its own colours,
/// lifting under focus or the pointer. As many fit across as the width allows, sharing it, and the rest wrap onto further
/// lines, so a mouse reaches every genre without scrolling sideways.
@MainActor
public final class GradientTileGridView: View {
    public struct Tile: Hashable, Sendable {
        public var id: String
        public var title: String
        public var top: Color
        public var bottom: Color

        public init(id: String, title: String, top: Color, bottom: Color) {
            self.id = id
            self.title = title
            self.top = top
            self.bottom = bottom
        }
    }

    public var onActivate: ((Tile) -> Void)?
    private var tiles: [Tile] = []
    private var views: [String: GradientTileView] = [:]

    public override var remembersFocus: Bool { true }
    public override var preferredFocusView: View? { tiles.first.flatMap { views[$0.id] } }

    public func setTiles(_ newTiles: [Tile]) {
        tiles = newTiles
        var next: [String: GradientTileView] = [:]
        for tile in newTiles {
            let view = views[tile.id] ?? GradientTileView(tile: tile)
            view.tile = tile
            view.onActivate = { [weak self] tile in self?.onActivate?(tile) }
            if view.superview == nil { addSubview(view) }
            next[tile.id] = view
        }
        for (id, view) in views where next[id] == nil { view.removeFromSuperview() }
        views = next
        setNeedsLayout()
    }

    private var preferredTileSize: Size {
        let metrics = Theme.current.metrics
        return Size(width: metrics.tv(340) * metrics.cardZoom, height: metrics.tv(190) * metrics.cardZoom)
    }

    /// The columns that fit across `width` and the tile size that shares the width among them, in the preferred shape.
    private func grid(width: Float) -> (columns: Int, tile: Size) {
        let metrics = Theme.current.metrics
        let room = max(width - metrics.sideMargin * 2, 1)
        let preferred = preferredTileSize
        let columns = max(1, Int(((room + metrics.gutter) / (preferred.width + metrics.gutter)).rounded(.down)))
        let tileWidth = ((room - metrics.gutter * Float(columns - 1)) / Float(columns)).rounded(.down)
        return (columns, Size(width: tileWidth, height: (tileWidth * preferred.height / preferred.width).rounded()))
    }

    private var lineSpacing: Float { Theme.current.metrics.tv(32) }

    public override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        guard !tiles.isEmpty else { return Size(width: size.width, height: 0) }
        let layout = grid(width: size.width)
        let lines = (tiles.count + layout.columns - 1) / layout.columns
        let height = Float(lines) * layout.tile.height + Float(lines - 1) * lineSpacing
        return Size(width: size.width, height: metrics.shelfTopInset + height + metrics.shelfBottomInset * 0.6)
    }

    public override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let layout = grid(width: frame.width)
        for (index, tile) in tiles.enumerated() {
            let line = index / layout.columns
            let column = index % layout.columns
            views[tile.id]?.frame = Rect(x: metrics.sideMargin + Float(column) * (layout.tile.width + metrics.gutter),
                                         y: metrics.shelfTopInset + Float(line) * (layout.tile.height + lineSpacing),
                                         width: layout.tile.width, height: layout.tile.height)
        }
    }
}

/// One gradient tile.
@MainActor
private final class GradientTileView: View {
    var tile: GradientTileGridView.Tile { didSet { if tile != oldValue { setNeedsDisplay() } } }
    var onActivate: ((GradientTileGridView.Tile) -> Void)?
    private var lift = Animated(0)
    private var press = Animated(0)

    init(tile: GradientTileGridView.Tile) {
        self.tile = tile
        super.init()
    }

    override var canBecomeFocused: Bool { true }
    override var accessibilityLabel: String? { tile.title }
    override var overdraw: Float { Theme.current.metrics.focusShadowRadius * 2 }

    private func update() {
        lift.set((isFocused && (window?.isFocusVisible ?? false)) || isHovered ? 1 : 0, animation: .focus)
        startAnimating()
    }

    override func focusDidChange(focused: Bool, animated: Bool) { update() }
    override func focusVisibilityDidChange(_ visible: Bool) { update() }
    override func pointerEntered() { update() }
    override func pointerExited() { update() }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard button == .primary else { return false }
        press.set(1, animation: .press)
        startAnimating()
        return true
    }

    override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        guard button == .primary else { return }
        press.set(0, animation: .press)
        startAnimating()
        guard inside else { return }
        window?.focus.focus(self, animated: true, reveal: false)
        onActivate?(tile)
    }

    override func activate() { onActivate?(tile) }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [lift.advance(dt), press.advance(dt)].contains(true)
        setNeedsDisplay()
        return moving
    }

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let theme = Theme.current
        let metrics = theme.metrics
        let radius = metrics.cardCornerRadius
        let factor = (1 + (metrics.artworkFocusScale - 1) * lift.value) * (1 - (1 - metrics.pressedScale) * press.value)
        context.transformed(scale: factor, about: bounds.center) { inner in
            if lift.value > 0.001 {
                inner.shadow(bounds, radius: radius, blur: metrics.focusShadowRadius * 0.9, offsetY: metrics.focusShadowOffset, opacity: 0.55 * lift.value)
            }
            inner.gradient(bounds, vertical: true, stops: [(0, tile.top), (1, tile.bottom)], radius: radius)
            let layout = TextLayout(tile.title, font: theme.type.headline, maxWidth: bounds.width - metrics.tv(40), maxLines: 2, scale: scale)
            inner.text(layout, at: Point(x: metrics.tv(24), y: bounds.height - layout.size.height - metrics.tv(20)), color: theme.palette.onArt)
        }
    }
}

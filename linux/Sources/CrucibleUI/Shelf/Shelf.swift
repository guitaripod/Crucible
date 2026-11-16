import Foundation
import Kiln

/// The header above a shelf (`TVSectionHeaderView`): a headline title, quiet secondary text and an optional See All.
public struct SectionHeader: Hashable, Sendable {
    public var title: String
    public var secondaryText: String?
    public var hasSeeAll: Bool

    public init(title: String, secondaryText: String? = nil, hasSeeAll: Bool = false) {
        self.title = title
        self.secondaryText = secondaryText
        self.hasSeeAll = hasSeeAll
    }
}

/// A horizontal row of cards under a header (`TVShelf`): it scrolls sideways under a horizontal swipe, Shift with the
/// wheel, or the edge arrows that appear on hover for mice without a horizontal axis, and keeps the focused card in view.
/// Focus returns to the card it left when it comes back to the shelf.
@MainActor
public final class ShelfView: View {
    public var header: SectionHeader? { didSet { if header != oldValue { rebuildHeader() } } }
    public private(set) var items: [CardItem] = []
    public var style: CardStyle { didSet { if style != oldValue { setNeedsLayout() } } }

    public var onActivate: ((CardItem) -> Void)?
    public var onFocus: ((CardItem) -> Void)?
    public var onPlay: ((CardItem) -> Bool)?
    public var onContextMenu: ((CardItem, Point?) -> Void)?
    public var onSeeAll: (() -> Void)?

    public let scroller = ScrollView(axis: .horizontal)
    private var cards: [String: CardView] = [:]
    private var order: [String] = []
    private let headerLabel = Label(font: Theme.current.type.headline, color: Theme.current.palette.label)
    private let secondaryLabel = Label(font: Theme.current.type.callout, color: Theme.current.palette.labelSecondary)
    private lazy var seeAll = ButtonView(style: .plain, title: Strings.text("See All"), symbol: "chevron.right", symbolTrailing: true)
    private let leadingArrow = ShelfArrow(direction: .left)
    private let trailingArrow = ShelfArrow(direction: .right)

    public init(header: SectionHeader?, style: CardStyle) {
        self.header = header
        self.style = style
        super.init()
        scroller.showsIndicator = false
        addSubview(scroller)
        headerLabel.isHeading = true
        addSubview(headerLabel)
        addSubview(secondaryLabel)
        leadingArrow.onPress = { [weak self] in self?.page(-1) }
        trailingArrow.onPress = { [weak self] in self?.page(1) }
        addSubview(leadingArrow)
        addSubview(trailingArrow)
        scroller.onScroll = { [weak self] _ in self?.updateArrows() }
        rebuildHeader()
    }

    public override var remembersFocus: Bool { true }
    public override var preferredFocusView: View? { order.first.flatMap { cards[$0] } }

    /// Focus coming down from the row above lands on the card below it, not on See All, which sits closer in the header
    /// and is reached by going up from the cards.
    public override func redirectedFocus(_ target: View, from origin: View, moving direction: Direction) -> View? {
        guard direction == .down, target === seeAll else { return nil }
        return FocusEngine.nearest(from: origin, direction: .down, among: order.compactMap { cards[$0] })
    }

    /// Replaces the cards, keeping the views (and focus) of items that stay.
    public func setItems(_ newItems: [CardItem]) {
        items = newItems
        var next: [String: CardView] = [:]
        for item in newItems {
            if let card = cards[item.id] {
                card.item = item
                card.style = style
                next[item.id] = card
            } else {
                let card = CardView(item: item, style: style)
                card.onActivate = { [weak self] item in self?.onActivate?(item) }
                card.onFocus = { [weak self] item in self?.onFocus?(item) }
                card.onPlay = { [weak self] item in self?.onPlay?(item) ?? false }
                card.onContextMenu = { [weak self] item, point in self?.onContextMenu?(item, point) }
                scroller.addSubview(card)
                next[item.id] = card
            }
        }
        for (id, card) in cards where next[id] == nil { card.removeFromSuperview() }
        cards = next
        order = newItems.map(\.id)
        setNeedsLayout()
    }

    public func card(for id: String) -> CardView? { cards[id] }

    private func rebuildHeader() {
        headerLabel.text = header?.title ?? ""
        secondaryLabel.text = header?.secondaryText ?? ""
        if header?.hasSeeAll == true {
            seeAll.onPress = { [weak self] in self?.onSeeAll?() }
            if seeAll.superview == nil { addSubview(seeAll) }
        } else {
            seeAll.removeFromSuperview()
        }
        setNeedsLayout()
    }

    private var headerHeight: Float { header == nil ? 0 : Theme.current.metrics.shelfHeaderHeight }

    /// The height this shelf takes: header, top room, cards, bottom room.
    public var preferredHeight: Float {
        let metrics = Theme.current.metrics
        return headerHeight + metrics.shelfTopInset + style.itemSize.height + metrics.shelfBottomInset
    }

    public override func sizeThatFits(_ size: Size) -> Size { Size(width: size.width, height: preferredHeight) }

    public override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let margin = metrics.sideMargin
        headerLabel.font = Theme.current.type.headline
        headerLabel.color = Theme.current.palette.label
        secondaryLabel.font = Theme.current.type.callout
        secondaryLabel.color = Theme.current.palette.labelSecondary
        let headerBottom = headerHeight - metrics.sectionSpacing
        let titleSize = headerLabel.sizeThatFits(Size(width: frame.width - margin * 2, height: 100))
        headerLabel.frame = Rect(x: margin, y: headerBottom - titleSize.height, width: titleSize.width, height: titleSize.height)
        var x = headerLabel.frame.maxX + metrics.tv(32)
        if !secondaryLabel.text.isEmpty {
            let size = secondaryLabel.sizeThatFits(Size(width: frame.width - x - margin, height: 100))
            secondaryLabel.frame = Rect(x: x, y: headerLabel.frame.midY - size.height / 2, width: size.width, height: size.height)
            x = secondaryLabel.frame.maxX + metrics.tv(32)
        }
        if seeAll.superview != nil {
            let size = seeAll.sizeThatFits(Size(width: 400, height: 100))
            seeAll.frame = Rect(x: x - metrics.plainControlInset, y: headerLabel.frame.midY - size.height / 2, width: size.width, height: size.height)
        }
        let cardsTop = headerHeight
        let rowHeight = metrics.shelfTopInset + style.itemSize.height + metrics.shelfBottomInset
        scroller.frame = Rect(x: 0, y: cardsTop, width: frame.width, height: rowHeight)
        scroller.revealInsets = EdgeInsets(leading: margin, trailing: margin)
        var cardX = margin
        for id in order {
            guard let card = cards[id] else { continue }
            card.frame = Rect(x: cardX, y: metrics.shelfTopInset, width: style.itemWidth, height: style.itemSize.height)
            cardX += style.itemWidth + metrics.gutter
        }
        scroller.contentLength = cardX - metrics.gutter + margin
        scroller.snapInterval = style.itemWidth + metrics.gutter
        scroller.wheelStep = style.itemWidth + metrics.gutter
        let arrowSize = metrics.tv(72)
        let arrowY = metrics.shelfTopInset + style.artworkSize.height / 2 - arrowSize / 2 + cardsTop
        leadingArrow.frame = Rect(x: margin * 0.25, y: arrowY, width: arrowSize, height: arrowSize)
        trailingArrow.frame = Rect(x: frame.width - margin * 0.25 - arrowSize, y: arrowY, width: arrowSize, height: arrowSize)
        updateArrows()
    }

    /// Scrolls a page of cards sideways (the edge arrows).
    private func page(_ direction: Float) {
        let metrics = Theme.current.metrics
        let stride = style.itemWidth + metrics.gutter
        let visible = max(1, ((frame.width - metrics.sideMargin * 2) / stride).rounded(.down))
        let target = (scroller.offset / stride).rounded() * stride + direction * visible * stride
        scroller.setOffset(target, animated: true)
    }

    private var hovering = false

    private func updateArrows() {
        let showLeading = hovering && scroller.offset > 1
        let showTrailing = hovering && scroller.offset < scroller.maximumOffset - 1
        leadingArrow.setShown(showLeading)
        trailingArrow.setShown(showTrailing)
    }

    public override var isPointerInteractive: Bool { true }
    public override var cursor: Cursor { .default }

    public override func hitTest(_ point: Point) -> View? {
        let hit = super.hitTest(point)
        let inside = bounds.contains(point)
        if inside != hovering {
            hovering = inside
            updateArrows()
        }
        return hit
    }

    public override func pointerExited() {
        hovering = false
        updateArrows()
    }
}

/// The round glass arrow at a shelf's edge, shown on hover when the shelf can scroll that way.
@MainActor
final class ShelfArrow: View {
    let direction: Direction
    var onPress: (() -> Void)?
    private var shown = Animated(0)
    private var hover = Animated(0)
    private var tone = GlassTone()

    init(direction: Direction) {
        self.direction = direction
        super.init()
    }

    func setShown(_ visible: Bool) {
        shown.set(visible ? 1 : 0, animation: .fade)
        startAnimating()
    }

    override var isPointerInteractive: Bool { shown.target > 0 }
    override var accessibilityLabel: String? { direction == .left ? Strings.text("Previous") : Strings.text("Next") }
    /// Left out for screen readers, which walk a shelf card by card with the focus; the arrows serve a mouse without a
    /// sideways wheel.
    override var accessibilityRole: AccessibilityRole { .none }

    override func pointerEntered() {
        hover.set(1, animation: .focus)
        startAnimating()
    }

    override func pointerExited() {
        hover.set(0, animation: .focus)
        startAnimating()
    }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard button == .primary, shown.target > 0 else { return false }
        onPress?()
        return true
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [shown.advance(dt), hover.advance(dt), tone.advance(dt)].contains(true)
        setNeedsDisplay()
        return moving
    }

    override func draw(_ context: inout DrawContext) {
        guard shown.value > 0.01 else { return }
        let side = bounds.width
        context.faded(shown.value) { inner in
            inner.transformed(scale: 1 + 0.08 * hover.value, about: bounds.center) { lifted in
                if tone.update(lifted, rect: bounds) { startAnimating() }
                GlassStyle.capsule(in: bounds, light: Point(x: bounds.midX, y: bounds.minY), tone: tone.value, context: &lifted)
                let glyph = side * 0.42
                let symbol: Symbol = direction == .left ? "chevron.left" : "chevron.right"
                lifted.symbol(symbol, in: Rect(x: bounds.midX - glyph / 2, y: bounds.midY - glyph / 2, width: glyph, height: glyph),
                              color: GlassStyle.label(tone: tone.value))
            }
        }
    }
}

/// A vertical grid of cards (a library, search results): as many columns as fit, rows spaced by the tvOS grid rhythm.
@MainActor
public final class CardGridView: View {
    public private(set) var items: [CardItem] = []
    public var aspect: Float = 1.5 { didSet { if aspect != oldValue { setNeedsLayout() } } }
    /// A fixed number of columns (Search's six posters or four episodes) in place of as many as fit.
    public var columns: Int? { didSet { if columns != oldValue { setNeedsLayout() } } }
    public var onActivate: ((CardItem) -> Void)?
    public var onFocus: ((CardItem) -> Void)?
    public var onPlay: ((CardItem) -> Bool)?
    public var onContextMenu: ((CardItem, Point?) -> Void)?
    private var cards: [String: CardView] = [:]
    private var order: [String] = []
    public private(set) var style: CardStyle = .poster

    public override var remembersFocus: Bool { true }
    public override var preferredFocusView: View? { order.first.flatMap { cards[$0] } }

    public func setItems(_ newItems: [CardItem]) {
        items = newItems
        var next: [String: CardView] = [:]
        for item in newItems {
            if let card = cards[item.id] {
                card.item = item
                next[item.id] = card
            } else {
                let card = CardView(item: item, style: style)
                card.onActivate = { [weak self] item in self?.onActivate?(item) }
                card.onFocus = { [weak self] item in self?.onFocus?(item) }
                card.onPlay = { [weak self] item in self?.onPlay?(item) ?? false }
                card.onContextMenu = { [weak self] item, point in self?.onContextMenu?(item, point) }
                addSubview(card)
                next[item.id] = card
            }
        }
        for (id, card) in cards where next[id] == nil { card.removeFromSuperview() }
        cards = next
        order = newItems.map(\.id)
        setNeedsLayout()
    }

    private var margin: Float { Theme.current.metrics.sideMargin }

    /// The cards' geometry: as wide as a poster's area allows, or as `columns` share the width.
    private func gridStyle(width: Float) -> CardStyle {
        guard let columns else { return CardStyle.grid(aspect: aspect, width: width) }
        let metrics = Theme.current.metrics
        let itemWidth = ((width - metrics.gutter * Float(columns - 1)) / Float(columns)).rounded(.down)
        var style = CardStyle.grid(aspect: aspect, width: width)
        style.itemWidth = itemWidth
        style.artworkSize = Size(width: itemWidth, height: (itemWidth * aspect).rounded())
        return style
    }

    private func columnCount(style: CardStyle, width: Float) -> Int {
        columns ?? max(1, Theme.current.metrics.gridColumns(itemWidth: style.itemWidth, width: width))
    }

    /// The card showing the item at `index` in the grid's order.
    public func card(at index: Int) -> CardView? {
        order.indices.contains(index) ? cards[order[index]] : nil
    }

    /// The index of the item a card shows, for the focus to report where in the grid it is.
    public func index(of id: String) -> Int? {
        order.firstIndex(of: id)
    }

    /// The grid's height for `width`.
    public func height(for width: Float) -> Float {
        let metrics = Theme.current.metrics
        let style = gridStyle(width: width - margin * 2)
        let columns = columnCount(style: style, width: width - margin * 2)
        let rows = (order.count + columns - 1) / columns
        guard rows > 0 else { return 0 }
        return metrics.shelfTopInset + Float(rows) * style.itemSize.height + Float(rows - 1) * metrics.gridRowSpacing + metrics.shelfBottomInset
    }

    public override func sizeThatFits(_ size: Size) -> Size { Size(width: size.width, height: height(for: size.width)) }

    public override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let width = frame.width - margin * 2
        style = gridStyle(width: width)
        let columns = columnCount(style: style, width: width)
        for (index, id) in order.enumerated() {
            guard let card = cards[id] else { continue }
            let row = index / columns
            let column = index % columns
            card.style = style
            card.frame = Rect(x: margin + Float(column) * (style.itemWidth + metrics.gutter),
                              y: metrics.shelfTopInset + Float(row) * (style.itemSize.height + metrics.gridRowSpacing),
                              width: style.itemWidth, height: style.itemSize.height)
        }
    }
}

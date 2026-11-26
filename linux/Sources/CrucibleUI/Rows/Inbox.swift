import Foundation
import Kiln

/// A video or a comment as an inbox card shows it: its picture, the channel's face, what happened and how the viewer
/// stands with it.
public struct InboxCardItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var channel: String
    /// The line that says what happened on a comment ("Replied to your comment").
    public var context: String?
    /// The quiet line under the title ("1.2M views · 3 days ago", "Watched").
    public var facts: String?
    public var thumbnail: ArtworkSource?
    public var avatar: ArtworkSource?
    public var badge: String?
    public var isComment: Bool
    public var isUnread: Bool
    public var isWatched: Bool
    /// Whether the channel is known well enough to be muted from here.
    public var canMute: Bool

    public init(id: String, title: String, channel: String, context: String? = nil, facts: String? = nil, thumbnail: ArtworkSource? = nil,
                avatar: ArtworkSource? = nil, badge: String? = nil, isComment: Bool = false, isUnread: Bool = false, isWatched: Bool = false,
                canMute: Bool = false) {
        self.id = id
        self.title = title
        self.channel = channel
        self.context = context
        self.facts = facts
        self.thumbnail = thumbnail
        self.avatar = avatar
        self.badge = badge
        self.isComment = isComment
        self.isUnread = isUnread
        self.isWatched = isWatched
        self.canMute = canMute
    }
}

/// One notification as a card: a sixteen by nine picture on the left, the channel, title and facts on the right, an accent
/// bar while unread, a tick and a dimmed picture once watched. The pointer brings out its actions over the picture (play or
/// open the comments, mark read, save for later, mute the channel); the keyboard has Enter, M, S and B on the focused card.
@MainActor
public final class InboxCardView: View {
    public var item: InboxCardItem {
        didSet {
            guard item != oldValue else { return }
            apply()
        }
    }
    public var onActivate: ((InboxCardItem) -> Void)?
    public var onContextMenu: ((InboxCardItem, Point?) -> Bool)?
    public var onFocus: ((InboxCardItem) -> Void)?
    public var onToggleRead: ((InboxCardItem) -> Void)?
    public var onToggleLater: ((InboxCardItem) -> Void)?
    public var onToggleMute: ((InboxCardItem) -> Void)?

    private enum Zone: Equatable {
        case primary, read, later, mute
    }

    private lazy var artwork = ArtworkSlot(owner: self)
    private lazy var face = ArtworkSlot(owner: self)
    private var focus = Animated(0)
    private var hover = Animated(0)
    private var press = Animated(0)
    private var hoveredZone: Zone?
    private var pressedZone: Zone?
    private var pressedByPointer = false
    private var laidOut: (width: Float, scale: Float, texts: Texts)?
    private var textSignature: String?
    private var loadedArtwork = false
    private var art = Rect.zero

    private struct Texts {
        let context: TextLayout?
        let title: TextLayout
        let channel: TextLayout
        let facts: TextLayout?
    }

    public init(item: InboxCardItem) {
        self.item = item
        super.init()
        apply()
    }

    public override var canBecomeFocused: Bool { true }
    public override var accessibilityLabel: String? {
        [item.context, item.title, item.channel, item.facts].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
    public override var accessibilityValue: String? { item.isUnread ? Strings.lookup("New") : nil }
    public override var accessibilityHint: String? {
        onContextMenu == nil ? nil : Strings.lookup("Press the Menu key for more options")
    }

    private var height: Float { Theme.current.metrics.tv(210) }
    private var padding: Float { Theme.current.metrics.tv(18) }
    private var gap: Float { Theme.current.metrics.tv(28) }
    private var faceSide: Float { Theme.current.metrics.tv(40) }
    private var rasterScale: Float { window?.scale ?? 1 }

    public override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: height)
    }

    private func apply() {
        loadedArtwork = false
        let signature = "\(item.title)\u{1}\(item.channel)\u{1}\(item.context ?? "")\u{1}\(item.facts ?? "")\u{1}\(item.isUnread)"
        if signature != textSignature {
            textSignature = signature
            laidOut = nil
        }
        setNeedsLayout()
        setNeedsDisplay()
    }

    // MARK: Artwork

    private func loadArtwork() {
        guard !loadedArtwork, let window, art.width > 0 else { return }
        loadedArtwork = true
        let artPixels = Theme.current.metrics.imagePixelWidth(points: art.width, scale: window.scale)
        artwork.show(item.thumbnail, pixelWidth: artPixels, pixelHeight: Int((Float(artPixels) * 9 / 16).rounded()), redraw: false)
        let facePixels = Int((faceSide * window.scale * 2).rounded())
        face.show(item.avatar, pixelWidth: facePixels, pixelHeight: facePixels, redraw: false)
    }

    private func artRect(in rect: Rect) -> Rect {
        guard art.width > 0 else { return Rect(x: padding, y: padding, width: max(1, rect.width * 0.4), height: height - padding * 2) }
        return art
    }

    private func placeArtwork() {
        let natural = (height - padding * 2) * 16 / 9
        let width = min(natural, bounds.width * 0.42)
        let height = (width * 9 / 16).rounded()
        let placed = Rect(x: padding, y: ((bounds.height - height) / 2).rounded(), width: width.rounded(), height: height)
        guard placed != art else { return }
        art = placed
        loadedArtwork = false
        laidOut = nil
        setNeedsDisplay()
    }

    // MARK: Words

    private func texts(width: Float) -> Texts {
        let type = Theme.current.type
        let scale = rasterScale
        if let laidOut, laidOut.width == width, laidOut.scale == scale { return laidOut.texts }
        let textX = art.maxX + gap
        let textWidth = max(60, width - textX - padding)
        let title = TextLayout(item.title, font: item.isUnread ? type.cardTitle : type.body, maxWidth: textWidth, maxLines: 3, scale: scale)
        let channelWidth = max(30, textWidth - (item.avatar == nil ? 0 : faceSide + Theme.current.metrics.tv(12)))
        let channel = TextLayout(item.channel, font: type.cardSubtitle, maxWidth: channelWidth, maxLines: 1, scale: scale)
        let facts = item.facts.flatMap { $0.isEmpty ? nil : TextLayout($0, font: type.footnote, maxWidth: textWidth, maxLines: 1, scale: scale) }
        let context = item.context.flatMap {
            $0.isEmpty ? nil : TextLayout($0, font: type.caption1, maxWidth: max(40, textWidth - Theme.current.metrics.tv(30)), maxLines: 1,
                                           scale: scale)
        }
        let texts = Texts(context: context, title: title, channel: channel, facts: facts)
        laidOut = (width, scale, texts)
        return texts
    }

    // MARK: Hover actions

    private var showsActions: Bool { isHovered || (isFocused && (window?.isFocusVisible ?? false)) }

    private var zones: [Zone] {
        var zones: [Zone] = [.primary, .read, .later]
        if item.canMute { zones.append(.mute) }
        return zones
    }

    private var actionSide: Float { Theme.current.metrics.tv(48) }
    private var actionGap: Float { Theme.current.metrics.tv(10) }

    private func actionRects(in art: Rect) -> [(Zone, Rect)] {
        let offered = zones
        guard !offered.isEmpty else { return [] }
        let total = Float(offered.count) * actionSide + Float(offered.count - 1) * actionGap
        var x = art.midX - total / 2
        let y = art.maxY - Theme.current.metrics.tv(14) - actionSide
        return offered.map { zone in
            defer { x += actionSide + actionGap }
            return (zone, Rect(x: x, y: y, width: actionSide, height: actionSide))
        }
    }

    private func zone(at point: Point) -> Zone? {
        guard showsActions else { return nil }
        let art = artRect(in: bounds)
        for (zone, rect) in actionRects(in: art) where rect.insetBy(-3, -3).contains(point) { return zone }
        return nil
    }

    private func symbol(for zone: Zone) -> Symbol {
        switch zone {
        case .primary: item.isComment ? "text.bubble" : "play.fill"
        case .read: "checkmark"
        case .later: "clock"
        case .mute: "bell.badge"
        }
    }

    private func actionName(_ zone: Zone) -> String {
        switch zone {
        case .primary: item.isComment ? Strings.lookup("Open Comments") : Strings.lookup("Play")
        case .read: item.isUnread ? Strings.lookup("Mark as Read") : Strings.lookup("Mark as Unread")
        case .later: Strings.lookup("Watch Later")
        case .mute: Strings.lookup("Mute Notifications")
        }
    }

    public override func tooltip(at point: Point) -> String? {
        if let zone = zone(at: point) { return actionName(zone) }
        guard let scale = window?.scale else { return nil }
        let full = TextLayout(item.title, font: Theme.current.type.cardTitle, scale: scale).size.width
        let willTruncate = full > bounds.width - (art.maxX + gap) - padding
        return willTruncate ? [item.title, item.context, item.channel].compactMap { $0 }.joined(separator: " · ") : nil
    }

    public override func cursor(at point: Point) -> Cursor { zone(at: point) == nil ? cursor : .pointer }

    // MARK: Focus and pointer

    private func update() {
        let focused = isFocused && (window?.isFocusVisible ?? false)
        focus.set(focused ? 1 : 0, animation: .focus)
        hover.set(isHovered && !focused ? 1 : 0, animation: .focus)
        startAnimating()
    }

    public override func focusDidChange(focused: Bool, animated: Bool) {
        update()
        if focused { onFocus?(item) }
    }

    public override func focusVisibilityDidChange(_ visible: Bool) { if isFocused { update() } }
    public override func pointerEntered() { update() }

    public override func pointerExited() {
        pressedByPointer = false
        pressedZone = nil
        hoveredZone = nil
        press.set(0, animation: .press)
        update()
    }

    public override func pointerMoved(to point: Point) {
        let zone = zone(at: point)
        guard zone != hoveredZone else { return }
        hoveredZone = zone
        setNeedsDisplay()
    }

    public override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        if button == .secondary, let onContextMenu {
            window?.focus.focus(self, animated: true, reveal: false)
            let origin = frameInWindow.origin
            return onContextMenu(item, Point(x: origin.x + point.x, y: origin.y + point.y))
        }
        guard button == .primary else { return false }
        if let zone = zone(at: point) {
            pressedZone = zone
            setNeedsDisplay()
            return true
        }
        pressedByPointer = true
        press.set(1, animation: .press)
        startAnimating()
        return true
    }

    public override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        guard button == .primary else { return }
        defer { pressedZone = nil }
        if let zone = pressedZone {
            guard inside, self.zone(at: point) == zone else { return }
            perform(zone)
            return
        }
        press.set(0, animation: .press)
        startAnimating()
        if pressedByPointer && inside {
            window?.focus.focus(self, animated: true, reveal: false)
            onActivate?(item)
        }
        pressedByPointer = false
    }

    private func perform(_ zone: Zone) {
        switch zone {
        case .primary: onActivate?(item)
        case .read: onToggleRead?(item)
        case .later: onToggleLater?(item)
        case .mute: onToggleMute?(item)
        }
    }

    public override func activate() {
        press.reset(1)
        press.set(0, animation: .press)
        startAnimating()
        onActivate?(item)
    }

    public override func keyPressed(_ event: KeyEvent) -> Bool {
        guard event.modifiers.isEmpty, let character = event.text.first else { return false }
        switch String(character).lowercased() {
        case "m": onToggleRead?(item); return true
        case "s": onToggleLater?(item); return true
        case "b" where item.canMute: onToggleMute?(item); return true
        default: return false
        }
    }

    public override func showContextMenu(at point: Point?) -> Bool {
        let frame = frameInWindow
        let anchor = point.map { Rect(x: frame.x + $0.x, y: frame.y + $0.y, width: 1, height: 1) }
            ?? Rect(x: frame.maxX - Theme.current.metrics.tv(500), y: frame.maxY, width: 1, height: 1)
        return onContextMenu?(item, anchor.origin) ?? false
    }

    public override func layoutSubviews() {
        placeArtwork()
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [focus.advance(dt), hover.advance(dt), press.advance(dt), artwork.advance(dt), face.advance(dt)].contains(true)
        setNeedsDisplay()
        return moving
    }

    // MARK: Drawing

    public override func draw(_ context: inout DrawContext) {
        loadArtwork()
        let theme = Theme.current
        let metrics = theme.metrics
        let palette = theme.palette
        let rect = bounds
        let scale = rasterScale
        let dip = 1 - (1 - metrics.pressedScale) * press.value
        let art = artRect(in: rect)
        context.transformed(scale: dip, about: rect.center) { inner in
            if focus.value > 0.01 {
                inner.shadow(rect, radius: metrics.radiusS, blur: metrics.focusShadowRadius, offsetY: metrics.focusShadowOffset,
                             opacity: metrics.focusShadowOpacity * focus.value)
                inner.fill(rect, radius: metrics.radiusS, color: palette.focusFill.withAlpha(focus.value))
            } else {
                inner.fill(rect, radius: metrics.radiusS, color: palette.surface)
                inner.stroke(rect, radius: metrics.radiusS, width: 1 / max(scale, 1), color: palette.separator)
                if hover.value > 0.01 {
                    inner.fill(rect, radius: metrics.radiusS, color: palette.label.withAlpha(0.05 * hover.value))
                }
            }
            if item.isUnread {
                let bar = Rect(x: metrics.tv(5), y: rect.midY - rect.height * 0.24, width: metrics.tv(6), height: rect.height * 0.48)
                inner.fill(bar, radius: bar.width / 2, color: palette.accent.mixed(with: palette.onFocusFill, amount: focus.value * 0.35))
            }
            drawArtwork(in: &inner, art: art)
            let texts = texts(width: rect.width)
            let title = palette.label.mixed(with: palette.onFocusFill, amount: focus.value)
            let read = palette.label.mixed(with: palette.onFocusFill, amount: focus.value)
            let quiet = palette.labelSecondary.mixed(with: palette.onFocusFillSecondary, amount: focus.value)
            let textX = art.maxX + gap
            let block = (texts.context.map { $0.size.height + metrics.tv(4) } ?? 0) + texts.title.size.height + metrics.tv(6)
                + texts.channel.size.height + (texts.facts.map { $0.size.height + metrics.tv(4) } ?? 0)
            var y = ((rect.height - block) / 2 * scale).rounded() / scale
            if let context = texts.context {
                let glyph = metrics.tv(22)
                inner.symbol("text.bubble", in: Rect(x: textX, y: y + (context.size.height - glyph) / 2, width: glyph, height: glyph),
                             color: palette.accentText.mixed(with: palette.onFocusFill, amount: focus.value))
                inner.text(context, at: Point(x: textX + glyph + metrics.tv(8), y: y),
                           color: palette.accentText.mixed(with: palette.onFocusFill, amount: focus.value))
                y += context.size.height + metrics.tv(4)
            }
            inner.text(texts.title, at: Point(x: textX, y: y), color: item.isUnread ? title : read)
            y += texts.title.size.height + metrics.tv(6)
            if item.avatar != nil {
                let faceRect = Rect(x: textX, y: y + (texts.channel.size.height - faceSide) / 2, width: faceSide, height: faceSide)
                drawFace(in: &inner, in: faceRect)
            }
            let channelX = textX + (item.avatar == nil ? 0 : faceSide + metrics.tv(12))
            inner.text(texts.channel, at: Point(x: channelX, y: y + (faceSide - texts.channel.size.height) / 2), color: quiet)
            y += texts.channel.size.height + metrics.tv(4)
            if let facts = texts.facts {
                inner.text(facts, at: Point(x: textX, y: y), color: quiet)
            }
        }
    }

    private func drawArtwork(in context: inout DrawContext, art: Rect) {
        let metrics = Theme.current.metrics
        let palette = Theme.current.palette
        let radius = metrics.radiusS
        if let texture = artwork.texture {
            context.faded(item.isWatched ? 0.55 : 1) { faded in
                faded.image(texture, in: art, radius: radius, opacity: artwork.opacity)
            }
        } else {
            context.fill(art, radius: radius, color: palette.surfaceRaised)
            let glyph = metrics.tv(64)
            context.symbol(item.isComment ? "text.bubble" : "play.rectangle",
                           in: Rect(x: art.midX - glyph / 2, y: art.midY - glyph / 2, width: glyph, height: glyph), color: palette.labelSecondary)
        }
        if let badge = item.badge, !badge.isEmpty, let scale = window?.scale {
            _ = BadgeStyle.draw(badge, at: Point(x: art.x + metrics.tv(12), y: art.y + metrics.tv(12)), maxWidth: art.width - metrics.tv(24),
                                scale: scale, context: &context)
        }
        guard showsActions else { return }
        context.fill(art, radius: radius, color: Color.shade(0.28 + 0.14 * (isHovered ? 1 : 0)))
        for (zone, rect) in actionRects(in: art) {
            let lit = hoveredZone == zone || pressedZone == zone
            context.fill(rect, radius: rect.width / 2, color: Color.shade(lit ? 0.72 : 0.55))
            let glyph = metrics.tv(24)
            context.symbol(symbol(for: zone), in: Rect(x: rect.midX - glyph / 2, y: rect.midY - glyph / 2, width: glyph, height: glyph),
                           color: Theme.current.palette.onArt)
        }
    }

    private func drawFace(in context: inout DrawContext, in rect: Rect) {
        if let texture = face.texture {
            context.image(texture, in: rect, opacity: face.opacity, circle: true)
        } else {
            context.fill(rect, radius: rect.width / 2, color: Theme.current.palette.surfaceHigh)
        }
    }
}

/// The heading above a day's notifications ("Today", "Yesterday", "Tuesday", "Earlier") with how many are new.
@MainActor
public final class InboxGroupHeaderView: View {
    public var title: String { didSet { laidOut = nil; setNeedsDisplay() } }
    public var detail: String? { didSet { laidOut = nil; setNeedsDisplay() } }

    public init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
        super.init()
    }

    public override var accessibilityRole: AccessibilityRole { .heading }
    public override var accessibilityLabel: String? { [title, detail].compactMap { $0 }.joined(separator: ", ") }

    private var rasterScale: Float { window?.scale ?? 1 }
    private var laidOut: (width: Float, scale: Float, title: TextLayout, detail: TextLayout?)?

    private func layouts(width: Float) -> (TextLayout, TextLayout?) {
        let scale = rasterScale
        if let laidOut, laidOut.width == width, laidOut.scale == scale { return (laidOut.title, laidOut.detail) }
        let type = Theme.current.type
        let title = TextLayout(self.title, font: type.headline, maxLines: 1, scale: scale)
        let detail = self.detail.flatMap { text in
            text.isEmpty ? nil : TextLayout(text, font: type.callout, maxWidth: max(1, width - title.size.width - Theme.current.metrics.tv(32)),
                                            maxLines: 1, scale: scale)
        }
        laidOut = (width, scale, title, detail)
        return (title, detail)
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: Theme.current.metrics.tv(92))
    }

    public override func draw(_ context: inout DrawContext) {
        let (title, detail) = layouts(width: bounds.width)
        let metrics = Theme.current.metrics
        let palette = Theme.current.palette
        let y = ((bounds.height - title.size.height) / 2 * rasterScale).rounded() / rasterScale
        context.text(title, at: Point(x: 0, y: y), color: palette.label)
        if let detail {
            let x = title.size.width + metrics.tv(32)
            let detailY = y + (title.size.height - detail.size.height) / 2
            context.text(detail, at: Point(x: x, y: detailY), color: palette.labelSecondary)
        }
    }
}

/// The inbox's cards: day headings over as many columns of cards as the window has room for, the newest first, with a Show
/// More button under them while more notifications are left. Cards are made only for what the screen hands over, so a
/// thousand arrivals cost a page at a time.
@MainActor
public final class InboxGridView: View {
    public struct Section: Hashable, Sendable {
        public var title: String
        public var detail: String?
        public var items: [InboxCardItem]

        public init(title: String, detail: String? = nil, items: [InboxCardItem]) {
            self.title = title
            self.detail = detail
            self.items = items
        }
    }

    public private(set) var sections: [Section] = []
    public var onActivate: ((InboxCardItem) -> Void)?
    public var onContextMenu: ((InboxCardItem, Point?) -> Bool)?
    public var onFocus: ((InboxCardItem) -> Void)?
    public var onToggleRead: ((InboxCardItem) -> Void)?
    public var onToggleLater: ((InboxCardItem) -> Void)?
    public var onToggleMute: ((InboxCardItem) -> Void)?
    /// The Show More button's title, or nil for no button.
    public var moreTitle: String? {
        didSet {
            guard moreTitle != oldValue else { return }
            more.title = moreTitle ?? ""
            more.isHidden = moreTitle == nil
            superview?.setNeedsLayout()
            setNeedsLayout()
        }
    }
    public var onMore: (() -> Void)?

    private var cards: [String: InboxCardView] = [:]
    private var headers: [InboxGroupHeaderView] = []
    private let more = ButtonView(style: .glass, title: nil, symbol: "chevron.down", symbolTrailing: true)

    public override var remembersFocus: Bool { true }
    public override var preferredFocusView: View? {
        sections.first?.items.first.flatMap { cards[$0.id] } ?? (moreTitle == nil ? nil : more)
    }

    public override init(frame: Rect = .zero) {
        super.init(frame: frame)
        more.isHidden = true
        more.onPress = { [weak self] in self?.onMore?() }
        addSubview(more)
    }

    public func setSections(_ newSections: [Section]) {
        sections = newSections
        var next: [String: InboxCardView] = [:]
        for item in newSections.flatMap(\.items) {
            let card = cards[item.id] ?? InboxCardView(item: item)
            card.item = item
            card.onActivate = { [weak self] item in self?.onActivate?(item) }
            card.onFocus = { [weak self] item in self?.onFocus?(item) }
            card.onContextMenu = { [weak self] item, point in self?.onContextMenu?(item, point) ?? false }
            card.onToggleRead = { [weak self] item in self?.onToggleRead?(item) }
            card.onToggleLater = { [weak self] item in self?.onToggleLater?(item) }
            card.onToggleMute = { [weak self] item in self?.onToggleMute?(item) }
            if card.superview == nil { addSubview(card) }
            next[item.id] = card
        }
        for (id, card) in cards where next[id] == nil { card.removeFromSuperview() }
        cards = next
        for header in headers { header.removeFromSuperview() }
        headers = newSections.map { InboxGroupHeaderView(title: $0.title, detail: $0.detail) }
        for header in headers { addSubview(header) }
        setNeedsLayout()
        setNeedsDisplay()
    }

    /// Puts the focus on a card by its item's id, as on the first card a Show More brought in.
    @discardableResult
    public func focus(id: String) -> Bool {
        guard let card = cards[id] else { return false }
        window?.focus.focus(card, animated: true)
        return true
    }

    private var margin: Float { Theme.current.metrics.sideMargin }
    private var columnGap: Float { Theme.current.metrics.tv(40) }
    private var rowGap: Float { Theme.current.metrics.tv(24) }
    private var sectionGap: Float { Theme.current.metrics.tv(32) }
    private var headerHeight: Float { Theme.current.metrics.tv(92) }
    private var cardHeight: Float { Theme.current.metrics.tv(210) }
    private var moreHeight: Float { Theme.current.metrics.tv(96) }
    private var moreWidth: Float { Theme.current.metrics.tv(560) }

    private func cardWidth(for width: Float, columns: Int) -> Float {
        (width - Float(columns - 1) * columnGap) / Float(max(columns, 1))
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        let width = max(0, size.width - margin * 2)
        let columns = columnCount(for: width)
        var total: Float = 0
        for section in sections {
            total += headerHeight
            let rows = (section.items.count + columns - 1) / columns
            if rows > 0 { total += Float(rows) * cardHeight + Float(rows - 1) * rowGap }
            total += sectionGap
        }
        if moreTitle != nil { total += moreHeight }
        return Size(width: size.width, height: total)
    }

    private func columnCount(for width: Float) -> Int {
        let metrics = Theme.current.metrics
        guard metrics.density == .desk else { return 2 }
        let minimum = metrics.tv(640)
        return max(1, min(4, Int(((width + columnGap) / (minimum + columnGap)).rounded(.down))))
    }

    public override func layoutSubviews() {
        let width = max(0, frame.width - margin * 2)
        let columns = columnCount(for: width)
        let cardWidth = cardWidth(for: width, columns: columns)
        var y: Float = 0
        var headerIndex = 0
        for section in sections {
            let header = headers[headerIndex]
            header.frame = Rect(x: margin, y: y, width: width, height: headerHeight)
            y += headerHeight
            headerIndex += 1
            for (index, item) in section.items.enumerated() {
                guard let card = cards[item.id] else { continue }
                let row = index / columns
                let column = index % columns
                card.frame = Rect(x: margin + Float(column) * (cardWidth + columnGap), y: y + Float(row) * (cardHeight + rowGap),
                                  width: cardWidth, height: cardHeight)
            }
            let rows = (section.items.count + columns - 1) / columns
            if rows > 0 { y += Float(rows) * cardHeight + Float(rows - 1) * rowGap }
            y += sectionGap
        }
        more.frame = Rect(x: margin, y: y, width: min(moreWidth, width), height: moreHeight - Theme.current.metrics.tv(16))
        more.isHidden = moreTitle == nil
    }
}

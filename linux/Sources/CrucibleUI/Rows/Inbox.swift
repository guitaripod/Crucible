import Foundation
import Kiln

/// A video as an inbox row shows it: its picture, who posted it, what it is and how the viewer stands with it.
public struct InboxRowItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var channel: String
    /// The quiet line under the title ("1.2M views · 3 days ago · New").
    public var facts: String?
    public var thumbnail: ArtworkSource?
    public var avatar: ArtworkSource?
    public var isUnread: Bool
    public var isWatched: Bool

    public init(id: String, title: String, channel: String, facts: String? = nil, thumbnail: ArtworkSource? = nil, avatar: ArtworkSource? = nil,
                isUnread: Bool = false, isWatched: Bool = false) {
        self.id = id
        self.title = title
        self.channel = channel
        self.facts = facts
        self.thumbnail = thumbnail
        self.avatar = avatar
        self.isUnread = isUnread
        self.isWatched = isWatched
    }
}

/// One video in the inbox: a sixteen by nine picture, the channel's round face, a title on two lines and the facts under
/// it. Unread rows carry an accent bar and a brighter title; read ones rest quieter, and a watched one is dimmed. Focus
/// lifts it onto the app's light plate, as a settings row does.
@MainActor
public final class InboxRowView: View {
    public var item: InboxRowItem {
        didSet {
            guard item != oldValue else { return }
            apply()
        }
    }
    public var onActivate: ((InboxRowItem) -> Void)?
    public var onContextMenu: ((InboxRowItem, Point?) -> Bool)?
    public var onFocus: ((InboxRowItem) -> Void)?

    private let picture = ArtworkView()
    private let face = ArtworkView()
    private var focus = Animated(0)
    private var hover = Animated(0)
    private var press = Animated(0)
    private var pressedByPointer = false
    private var laidOut: (width: Float, scale: Float, texts: Texts)?

    private struct Texts {
        let title: TextLayout
        let channel: TextLayout
        let facts: TextLayout?
    }

    public init(item: InboxRowItem) {
        self.item = item
        super.init()
        picture.cornerRadius = Theme.current.metrics.radiusS
        picture.fillsUntilLoaded = true
        face.cornerRadius = Theme.current.metrics.tv(44) / 2
        addSubview(picture)
        addSubview(face)
        apply()
    }

    public override var canBecomeFocused: Bool { true }
    public override var accessibilityLabel: String? { [item.channel, item.title, item.facts].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ") }
    public override var accessibilityValue: String? { item.isUnread ? Strings.lookup("New") : nil }

    private var rasterScale: Float { window?.scale ?? 1 }

    private var pictureWidth: Float { Theme.current.metrics.tv(280) }
    private var padding: Float { Theme.current.metrics.tv(16) }
    private var gap: Float { Theme.current.metrics.tv(28) }
    private var faceSide: Float { Theme.current.metrics.tv(48) }

    public override func sizeThatFits(_ size: Size) -> Size {
        let height = (pictureWidth * 9 / 16).rounded() + padding * 2
        return Size(width: size.width, height: height)
    }

    private func apply() {
        picture.source = item.thumbnail
        picture.alpha = item.isWatched ? 0.55 : 1
        face.source = item.avatar
        face.isHidden = item.avatar == nil
        laidOut = nil
        setNeedsLayout()
        setNeedsDisplay()
    }

    private func texts(width: Float) -> Texts {
        let type = Theme.current.type
        let scale = rasterScale
        if let laidOut, laidOut.width == width, laidOut.scale == scale { return laidOut.texts }
        let textX = padding + pictureWidth + gap
        let textWidth = max(80, width - textX - padding)
        let channelWidth = max(40, textWidth - (item.avatar == nil ? 0 : faceSide + Theme.current.metrics.tv(16)))
        let title = TextLayout(item.title, font: item.isUnread ? type.cardTitle : type.body, maxWidth: textWidth, maxLines: 2, scale: scale)
        let channel = TextLayout(item.channel, font: type.cardSubtitle, maxWidth: channelWidth, maxLines: 1, scale: scale)
        let facts = item.facts.flatMap { $0.isEmpty ? nil : TextLayout($0, font: type.footnote, maxWidth: textWidth, maxLines: 1, scale: scale) }
        let texts = Texts(title: title, channel: channel, facts: facts)
        laidOut = (width, scale, texts)
        return texts
    }

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
        press.set(0, animation: .press)
        update()
    }

    public override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        if button == .secondary, let onContextMenu {
            window?.focus.focus(self, animated: true, reveal: false)
            let origin = frameInWindow.origin
            return onContextMenu(item, Point(x: origin.x + point.x, y: origin.y + point.y))
        }
        guard button == .primary else { return false }
        pressedByPointer = true
        press.set(1, animation: .press)
        startAnimating()
        return true
    }

    public override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        guard button == .primary else { return }
        press.set(0, animation: .press)
        startAnimating()
        if pressedByPointer && inside {
            window?.focus.focus(self, animated: true, reveal: false)
            onActivate?(item)
        }
        pressedByPointer = false
    }

    public override func activate() {
        press.reset(1)
        press.set(0, animation: .press)
        startAnimating()
        onActivate?(item)
    }

    public override func showContextMenu(at point: Point?) -> Bool {
        let frame = frameInWindow
        let anchor = point.map { Rect(x: frame.x + $0.x, y: frame.y + $0.y, width: 1, height: 1) }
            ?? Rect(x: frame.maxX - Theme.current.metrics.tv(500), y: frame.maxY, width: 1, height: 1)
        return onContextMenu?(item, anchor.origin) ?? false
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [focus.advance(dt), hover.advance(dt), press.advance(dt)].contains(true)
        setNeedsDisplay()
        return moving
    }

    public override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let height = (pictureWidth * 9 / 16).rounded()
        picture.frame = Rect(x: padding, y: ((bounds.height - height) / 2).rounded(), width: pictureWidth, height: height)
        let texts = texts(width: bounds.width)
        let block = texts.title.size.height + metrics.tv(6) + texts.channel.size.height + (texts.facts.map { $0.size.height + metrics.tv(4) } ?? 0)
        let top = ((bounds.height - block) / 2 * rasterScale).rounded() / rasterScale
        let channelY = top + texts.title.size.height + metrics.tv(6)
        face.frame = Rect(x: padding + pictureWidth + gap, y: channelY + (texts.channel.size.height - faceSide) / 2, width: faceSide, height: faceSide)
    }

    public override func draw(_ context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        let palette = theme.palette
        let rect = bounds
        let scale = rasterScale
        let dip = 1 - (1 - metrics.pressedScale) * press.value
        context.transformed(scale: dip, about: rect.center) { inner in
            if focus.value > 0.01 {
                inner.shadow(rect, radius: metrics.radiusS, blur: metrics.focusShadowRadius, offsetY: metrics.focusShadowOffset,
                             opacity: metrics.focusShadowOpacity * focus.value)
                inner.fill(rect, radius: metrics.radiusS, color: palette.focusFill.withAlpha(focus.value))
            } else if hover.value > 0.01 {
                inner.fill(rect, radius: metrics.radiusS, color: palette.label.withAlpha(0.06 * hover.value))
            }
            if item.isUnread {
                let bar = Rect(x: metrics.tv(5), y: rect.midY - rect.height * 0.22, width: metrics.tv(6), height: rect.height * 0.44)
                inner.fill(bar, radius: bar.width / 2, color: palette.accent.mixed(with: palette.onFocusFill, amount: focus.value * 0.35))
            }
            let texts = texts(width: rect.width)
            let title = palette.label.mixed(with: palette.onFocusFill, amount: focus.value)
            let read = palette.label.withAlpha(0.92).mixed(with: palette.onFocusFill, amount: focus.value)
            let quiet = palette.labelSecondary.mixed(with: palette.onFocusFillSecondary, amount: focus.value)
            let textX = padding + pictureWidth + gap
            let block = texts.title.size.height + metrics.tv(6) + texts.channel.size.height + (texts.facts.map { $0.size.height + metrics.tv(4) } ?? 0)
            var y = ((rect.height - block) / 2 * scale).rounded() / scale
            inner.text(texts.title, at: Point(x: textX, y: y), color: item.isUnread ? title : read)
            y += texts.title.size.height + metrics.tv(6)
            let channelX = textX + (item.avatar == nil ? 0 : faceSide + metrics.tv(16))
            inner.text(texts.channel, at: Point(x: channelX, y: y + (faceSide - texts.channel.size.height) / 2), color: quiet)
            if item.isWatched {
                let glyph = metrics.symbolAccessory
                let after = channelX + texts.channel.size.width + metrics.tv(12)
                inner.symbol("checkmark", in: Rect(x: after, y: y + (faceSide - glyph) / 2, width: glyph, height: glyph), color: quiet)
            }
            y += texts.channel.size.height + metrics.tv(4)
            if let facts = texts.facts {
                inner.text(facts, at: Point(x: textX, y: y), color: quiet)
            }
        }
    }
}

/// The heading above a day's arrivals ("Today", "Yesterday", "Tuesday", "Earlier") with how many are new under it.
@MainActor
public final class InboxGroupHeaderView: View {
    public var title: String { didSet { setNeedsDisplay() } }
    public var detail: String? { didSet { setNeedsDisplay() } }

    public init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
        super.init()
    }

    public override var accessibilityRole: AccessibilityRole { .heading }
    public override var accessibilityLabel: String? { [title, detail].compactMap { $0 }.joined(separator: ", ") }

    private var rasterScale: Float { window?.scale ?? 1 }

    private func layouts(width: Float) -> (TextLayout, TextLayout?) {
        let type = Theme.current.type
        let title = TextLayout(self.title, font: type.cardTitle, maxLines: 1, scale: rasterScale)
        let detail = self.detail.flatMap { text in
            text.isEmpty ? nil : TextLayout(text, font: type.callout, maxWidth: max(1, width - title.size.width - Theme.current.metrics.tv(32)),
                                            maxLines: 1, scale: rasterScale)
        }
        return (title, detail)
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: Theme.current.metrics.tv(78))
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

/// The inbox's list: day headings and their rows in one column, newest first, each row focusable in turn.
@MainActor
public final class InboxListView: View {
    public struct Section: Hashable, Sendable {
        public var title: String
        public var detail: String?
        public var items: [InboxRowItem]

        public init(title: String, detail: String? = nil, items: [InboxRowItem]) {
            self.title = title
            self.detail = detail
            self.items = items
        }
    }

    public private(set) var sections: [Section] = []
    public var onActivate: ((InboxRowItem) -> Void)?
    public var onContextMenu: ((InboxRowItem, Point?) -> Bool)?
    public var onFocus: ((InboxRowItem) -> Void)?

    private var rows: [String: InboxRowView] = [:]
    private var headers: [InboxGroupHeaderView] = []

    public override var remembersFocus: Bool { true }
    public override var preferredFocusView: View? { sections.first?.items.first.flatMap { rows[$0.id] } }

    public func setSections(_ newSections: [Section]) {
        sections = newSections
        let wanted = newSections.flatMap(\.items)
        var next: [String: InboxRowView] = [:]
        for item in wanted {
            let row = rows[item.id] ?? InboxRowView(item: item)
            row.item = item
            row.onActivate = { [weak self] item in self?.onActivate?(item) }
            row.onFocus = { [weak self] item in self?.onFocus?(item) }
            row.onContextMenu = { [weak self] item, point in self?.onContextMenu?(item, point) ?? false }
            next[item.id] = row
        }
        for (id, row) in rows where next[id] == nil { row.removeFromSuperview() }
        rows = next
        for header in headers { header.removeFromSuperview() }
        headers = newSections.map { InboxGroupHeaderView(title: $0.title, detail: $0.detail) }
        for header in headers { addSubview(header) }
        for section in newSections {
            for item in section.items where rows[item.id]?.superview == nil {
                if let row = rows[item.id] { addSubview(row) }
            }
        }
        setNeedsLayout()
        setNeedsDisplay()
    }

    /// The row showing `id`, for a screen that puts the focus on one.
    public func row(id: String) -> View? { rows[id] }

    private var column: Rect {
        let metrics = Theme.current.metrics
        return Rect(x: metrics.sideMargin, y: 0, width: max(0, frame.width - metrics.sideMargin * 2), height: frame.height)
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        let width = max(0, size.width - metrics.sideMargin * 2)
        var total: Float = metrics.tv(24)
        for section in sections {
            total += Theme.current.metrics.tv(78)
            for item in section.items {
                total += (rows[item.id]?.sizeThatFits(Size(width: width, height: 0)).height ?? 0) + metrics.tv(6)
            }
            total += metrics.tv(24)
        }
        return Size(width: size.width, height: total)
    }

    public override func layoutSubviews() {
        let area = column
        var y: Float = Theme.current.metrics.tv(24)
        var index = 0
        for section in sections {
            let header = headers[index]
            header.frame = Rect(x: area.x, y: y, width: area.width, height: Theme.current.metrics.tv(78))
            y += header.frame.height
            for item in section.items {
                guard let row = rows[item.id] else { continue }
                let height = row.sizeThatFits(Size(width: area.width, height: 0)).height
                row.frame = Rect(x: area.x, y: y, width: area.width, height: height)
                y += height + Theme.current.metrics.tv(6)
            }
            y += Theme.current.metrics.tv(24)
            index += 1
        }
    }
}

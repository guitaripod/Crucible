import Foundation
import Kiln

/// View data for every card (`TVCardItem`): screens map their models onto it, so one card serves movies, episodes,
/// people, genres and libraries.
public struct CardItem: Hashable, Sendable {
    public var id: String
    public var artwork: ArtworkSource?
    public var title: String
    public var subtitle: String?
    public var detail: String?
    public var eyebrow: String?
    public var progress: Double?
    public var isUnwatched = false
    public var isWatched = false
    public var isDimmed = false
    public var badgeText: String?
    /// What acting on the card does beyond opening it, read after its state ("Press the Menu key for more options").
    public var accessibilityHint: String?
    /// The title's `crucible://` link, which a middle click opens in a new window.
    public var link: URL?
    public var placeholderSymbol: Symbol = "film"
    /// UTF-16 ranges of the title tinted in the accent (a search query's match).
    public var titleHighlights: [Range<Int>] = []
    /// Initials on a gradient drawn while the card has no picture (a person without a photo), in place of the symbol.
    public var monogram: Monogram?
    /// A longer description where a list has room for it (an episode's synopsis in the desktop episode list).
    public var summary: String?
    /// Whether the card offers the hover watched toggle: off where it keeps no watched state of its own to show (a show).
    public var canToggleWatched = true
    /// The hover button in the middle of the artwork, and its name: Play by default, Request for a title the server lacks.
    public var primarySymbol: Symbol = "play.fill"
    public var primaryName: String?

    public struct Monogram: Hashable, Sendable {
        public var initials: String
        public var top: Color
        public var bottom: Color

        public init(initials: String, top: Color, bottom: Color) {
            self.initials = initials
            self.top = top
            self.bottom = bottom
        }
    }

    public init(id: String, artwork: ArtworkSource? = nil, title: String, subtitle: String? = nil, detail: String? = nil, eyebrow: String? = nil,
                progress: Double? = nil, isUnwatched: Bool = false, isWatched: Bool = false, isDimmed: Bool = false, badgeText: String? = nil,
                placeholderSymbol: Symbol = "film") {
        self.id = id
        self.artwork = artwork
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.eyebrow = eyebrow
        self.progress = progress
        self.isUnwatched = isUnwatched
        self.isWatched = isWatched
        self.isDimmed = isDimmed
        self.badgeText = badgeText
        self.placeholderSymbol = placeholderSymbol
    }

    public var hasProgress: Bool { (progress ?? 0) > 0 && (progress ?? 0) < 1 }

    public var spokenLabel: String {
        [eyebrow, title, subtitle, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The watch state a screen reader reads after the label (`TVCardItem.spokenValue`).
    @MainActor
    public var spokenValue: String? {
        if hasProgress, let progress {
            return String(format: Strings.lookup("%lld percent watched"), Int((progress * 100).rounded()))
        }
        if isWatched { return Strings.lookup("Watched") }
        if isUnwatched { return Strings.lookup("Unwatched") }
        return nil
    }
}

/// The geometry and caption rules of one card shape (`TVCardStyle`).
public struct CardStyle: Hashable, Sendable {
    public enum Shape: Hashable, Sendable { case rounded, circle }

    public var artworkSize: Size
    public var itemWidth: Float
    public var kind: ArtworkKind
    public var shape: Shape
    public var titleLines: Int
    public var showsEyebrow: Bool
    public var centersCaption: Bool
    public var scrimsArtwork: Bool

    @MainActor public static var poster: CardStyle {
        let metrics = Theme.current.metrics
        return CardStyle(artworkSize: metrics.posterSize, itemWidth: metrics.posterSize.width, kind: .poster, shape: .rounded, titleLines: 1,
                         showsEyebrow: false, centersCaption: false, scrimsArtwork: false)
    }

    @MainActor public static var landscape: CardStyle {
        let metrics = Theme.current.metrics
        return CardStyle(artworkSize: metrics.landscapeSize, itemWidth: metrics.landscapeSize.width, kind: .backdrop, shape: .rounded, titleLines: 1,
                         showsEyebrow: false, centersCaption: false, scrimsArtwork: true)
    }

    @MainActor public static var episode: CardStyle {
        let metrics = Theme.current.metrics
        return CardStyle(artworkSize: metrics.landscapeSize, itemWidth: metrics.landscapeSize.width, kind: .backdrop, shape: .rounded, titleLines: 2,
                         showsEyebrow: true, centersCaption: false, scrimsArtwork: true)
    }

    @MainActor public static var person: CardStyle {
        let metrics = Theme.current.metrics
        let diameter = metrics.personDiameter
        return CardStyle(artworkSize: Size(width: diameter, height: diameter), itemWidth: diameter + metrics.tv(40), kind: .poster, shape: .circle,
                         titleLines: 1, showsEyebrow: false, centersCaption: true, scrimsArtwork: false)
    }

    /// A grid card whose artwork is `aspect` tall for its width, as wide as covers about a poster's area, rounded to whole
    /// columns of `width`.
    @MainActor public static func grid(aspect: Float, width: Float) -> CardStyle {
        let metrics = Theme.current.metrics
        let posterAspect: Float = 1.5
        let target = metrics.posterSize.width * max(1, (posterAspect / aspect).squareRoot())
        let columns = metrics.gridColumns(itemWidth: target, width: width)
        let itemWidth = ((width - metrics.gutter * Float(columns - 1)) / Float(columns)).rounded(.down)
        return CardStyle(artworkSize: Size(width: itemWidth, height: (itemWidth * aspect).rounded()), itemWidth: itemWidth,
                         kind: aspect < 1 ? .backdrop : .poster, shape: .rounded, titleLines: metrics.cardZoom < 1 ? 2 : 1, showsEyebrow: false,
                         centersCaption: false, scrimsArtwork: false)
    }

    private struct LineKey: Hashable {
        let font: Font
        let opticalScale: Float
    }

    @MainActor private static var lineHeights: [LineKey: Float] = [:]

    @MainActor public var captionHeight: Float {
        let type = Theme.current.type
        let metrics = Theme.current.metrics
        let spacing = metrics.captionLabelSpacing
        var height = lineHeight(type.cardTitle) * Float(titleLines) + spacing + lineHeight(type.cardSubtitle)
        if showsEyebrow { height += lineHeight(type.eyebrow) + spacing }
        return height.rounded(.up)
    }

    @MainActor public var itemSize: Size {
        Size(width: itemWidth, height: artworkSize.height + Theme.current.metrics.captionSpacing + captionHeight)
    }

    /// A line of `font`'s height, measured once per font: grids ask for every card's size on every layout.
    @MainActor private func lineHeight(_ font: Font) -> Float {
        let key = LineKey(font: font, opticalScale: Font.opticalScale)
        if let known = Self.lineHeights[key] { return known }
        let height = TextLayout("Ag", font: font, scale: 2).size.height
        Self.lineHeights[key] = height
        return height
    }
}

/// What a card offers under the pointer on a desk: a play button in the middle of its artwork, a watched toggle in one
/// corner and a button for its menu in the other.
public struct CardHoverActions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let play = CardHoverActions(rawValue: 1)
    public static let watched = CardHoverActions(rawValue: 2)
    public static let menu = CardHoverActions(rawValue: 4)
}

/// The one card (`TVCardContentView`): artwork that lifts under focus or the pointer, tilting its sheen toward the
/// pointer, with a caption that slides down with it; progress, watched and unwatched marks and a corner badge on the art.
/// On a desk the pointer also brings out the card's hover actions (`CardHoverActions`), the full title in a tooltip when
/// the caption cuts it short, and resting on a card tells `onHover` (Home's hero follows it); Space plays the focused card.
@MainActor
public final class CardView: View {
    public var item: CardItem { didSet { if item != oldValue { apply(oldValue) } } }
    public var style: CardStyle { didSet { if style != oldValue { setNeedsLayout(); setNeedsDisplay() } } }

    public var onActivate: ((CardItem) -> Void)?
    /// Right click or the Menu key, with where to anchor the menu in window points.
    public var onContextMenu: ((CardItem, Point?) -> Void)?
    /// Called when the card gains focus (Home's backdrop follows it).
    public var onFocus: ((CardItem) -> Void)?
    /// The Play/Pause key on the focused card; returns whether it played, so a show passes the press on.
    public var onPlay: ((CardItem) -> Bool)?
    /// The hover watched toggle.
    public var onToggleWatched: ((CardItem) -> Void)?
    /// The pointer rested on the card for a moment.
    public var onHover: ((CardItem) -> Void)?
    /// Which hover actions the card offers now; its shelf or grid says, from the callbacks its screen set.
    public var hoverActions: () -> CardHoverActions = { [] }

    /// One of the hover buttons.
    enum Zone: Equatable {
        case play, watched, menu
    }

    private var hoverChrome = Animated(0)
    private var hoveredZone: Zone?
    private var pressedZone: Zone?
    private var restTask: DispatchWorkItem?

    private lazy var artwork = ArtworkSlot(owner: self)
    private var lift = Animated(0)
    private var press = Animated(0)
    private var tiltX = Animated(0)
    private var tiltY = Animated(0)
    private var pressedByPointer = false

    public init(item: CardItem, style: CardStyle) {
        self.item = item
        self.style = style
        super.init()
    }

    public override var canBecomeFocused: Bool { true }
    public override var accessibilityLabel: String? { item.spokenLabel }
    public override var accessibilityValue: String? { item.spokenValue }
    public override var accessibilityHint: String? {
        item.accessibilityHint ?? (onContextMenu == nil ? nil : Strings.lookup("Press the Menu key for more options"))
    }
    public override var overdraw: Float { Theme.current.metrics.focusShadowRadius * 2 + style.artworkSize.height * 0.1 }

    private func apply(_ old: CardItem) {
        setNeedsDisplay()
    }

    /// Artwork loads the first time the card is drawn, so a grid of thousands fetches only what comes on screen.
    private func loadArtwork() {
        guard let window else { return }
        let metrics = Theme.current.metrics
        let width = metrics.imagePixelWidth(points: style.artworkSize.width, scale: window.scale)
        let height = Int((Float(width) * style.artworkSize.height / max(style.artworkSize.width, 1)).rounded(.up))
        artwork.show(item.artwork, pixelWidth: width, pixelHeight: height, redraw: false)
    }

    // MARK: Focus and pointer

    private var isLifted: Bool { (isFocused && (window?.isFocusVisible ?? false)) || isHovered }

    private func updateLift() {
        lift.set(isLifted ? 1 : 0, animation: .focus)
        if !isHovered {
            tiltX.set(0, animation: .focus)
            tiltY.set(0, animation: .focus)
        }
        startAnimating()
    }

    public override func focusDidChange(focused: Bool, animated: Bool) {
        updateLift()
        if focused { onFocus?(item) }
    }

    public override func focusVisibilityDidChange(_ visible: Bool) {
        if isFocused { updateLift() }
    }

    public override func pointerEntered() {
        updateLift()
        guard Theme.current.density == .desk else { return }
        hoverChrome.set(1, animation: .timed(duration: 0.14, curve: .easeOut))
        startAnimating()
        restTask?.cancel()
        let rest = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isHovered else { return }
                self.onHover?(self.item)
            }
        }
        restTask = rest
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: rest)
    }

    public override func pointerExited() {
        pressedByPointer = false
        pressedZone = nil
        hoveredZone = nil
        restTask?.cancel()
        press.set(0, animation: .press)
        hoverChrome.set(0, animation: .timed(duration: 0.18, curve: .easeOut))
        updateLift()
    }

    /// The actions shown on hover: on a desk, for a rounded card, what its shelf or grid offers.
    private var offered: CardHoverActions {
        guard Theme.current.density == .desk, style.shape == .rounded else { return [] }
        var actions = hoverActions()
        if !item.canToggleWatched { actions.remove(.watched) }
        return actions
    }

    /// Where each hover button sits in the card's points, following the artwork's lift.
    func zoneRect(_ zone: Zone) -> Rect {
        let metrics = Theme.current.metrics
        let art = artworkRect
        let inset = metrics.badgeInset
        let corner = metrics.tv(46)
        let raw: Rect
        switch zone {
        case .play:
            let side = min(max(min(art.width, art.height) * 0.3, metrics.tv(64)), metrics.tv(112))
            raw = Rect(x: art.midX - side / 2, y: art.midY - side / 2, width: side, height: side)
        case .watched:
            raw = Rect(x: art.minX + inset, y: art.minY + inset, width: corner, height: corner)
        case .menu:
            raw = Rect(x: art.maxX - inset - corner, y: art.minY + inset, width: corner, height: corner)
        }
        let scale = artworkScale
        let parallax = Point(x: tiltX.value * art.width * 0.012 * lift.value, y: tiltY.value * art.height * 0.012 * lift.value)
        let center = art.center
        return Rect(x: center.x + (raw.x - center.x) * scale + parallax.x, y: center.y + (raw.y - center.y) * scale + parallax.y,
                    width: raw.width * scale, height: raw.height * scale)
    }

    private func zone(at point: Point) -> Zone? {
        let offered = offered
        guard !offered.isEmpty, hoverChrome.target > 0 else { return nil }
        if offered.contains(.menu), zoneRect(.menu).insetBy(-4, -4).contains(point) { return .menu }
        if offered.contains(.watched), zoneRect(.watched).insetBy(-4, -4).contains(point) { return .watched }
        if offered.contains(.play), zoneRect(.play).contains(point) { return .play }
        return nil
    }

    /// A hover button's name, or the full title and subtitle when the caption cuts the title short.
    public override func tooltip(at point: Point) -> String? {
        switch zone(at: point) {
        case .play: return item.primaryName ?? (item.hasProgress ? Strings.lookup("Resume") : Strings.lookup("Play"))
        case .watched: return item.isWatched ? Strings.lookup("Mark as Unwatched") : Strings.lookup("Mark as Watched")
        case .menu: return Strings.lookup("More")
        case nil:
            guard Theme.current.density == .desk, let scale = window?.scale else { return nil }
            let full = TextLayout(item.title, font: Theme.current.type.cardTitle, scale: scale).size.width
            guard full > frame.width * Float(style.titleLines) else { return nil }
            return [item.title, item.subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    public override func cursor(at point: Point) -> Cursor { zone(at: point) == nil ? cursor : .pointer }

    /// The hover buttons ride on the lifted artwork, which reaches past the card's own frame (its top corners above it),
    /// so they take the pointer there too.
    public override func hitTest(_ point: Point) -> View? {
        if !isHidden, alpha > 0.01, zone(at: point) != nil { return self }
        return super.hitTest(point)
    }

    /// A gamepad's right stick tilts the focused card as the pointer does over it.
    public override func gamepadTilted(x: Float, y: Float) -> Bool {
        tiltX.set(min(max(x, -1), 1), animation: .spring(response: 0.25, dampingFraction: 0.9))
        tiltY.set(min(max(y, -1), 1), animation: .spring(response: 0.25, dampingFraction: 0.9))
        startAnimating()
        return true
    }

    public override func pointerMoved(to point: Point) {
        let zone = zone(at: point)
        if zone != hoveredZone {
            hoveredZone = zone
            setNeedsDisplay()
        }
        let art = artworkRect
        let x = min(max((point.x - art.midX) / max(art.width / 2, 1), -1), 1)
        let y = min(max((point.y - art.midY) / max(art.height / 2, 1), -1), 1)
        tiltX.set(x, animation: .spring(response: 0.25, dampingFraction: 0.9))
        tiltY.set(y, animation: .spring(response: 0.25, dampingFraction: 0.9))
        startAnimating()
    }

    public override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        switch button {
        case .primary:
            if let zone = zone(at: point) {
                pressedZone = zone
                setNeedsDisplay()
                return true
            }
            pressedByPointer = true
            press.set(1, animation: .press)
            startAnimating()
            return true
        case .secondary:
            onContextMenu?(item, transformToWindow.apply(point))
            return onContextMenu != nil
        case .middle:
            guard let link = item.link, let window else { return false }
            window.openInNewWindow(link)
            return true
        default:
            return false
        }
    }

    public override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        guard button == .primary else { return }
        if let pressed = pressedZone {
            pressedZone = nil
            setNeedsDisplay()
            guard zone(at: point) == pressed else { return }
            switch pressed {
            case .play:
                if onPlay?(item) != true { onActivate?(item) }
            case .watched:
                onToggleWatched?(item)
            case .menu:
                let button = transformToWindow.apply(zoneRect(.menu))
                onContextMenu?(item, Point(x: button.minX, y: button.maxY))
            }
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

    public override func keyPressed(_ event: KeyEvent) -> Bool {
        guard let onPlay else { return false }
        if event.key == .mediaPlay || event.key == .mediaPause { return onPlay(item) }
        if event.key == .space, event.modifiers.isEmpty, Theme.current.density == .desk, offered.contains(.play) { return onPlay(item) }
        return false
    }

    public override func activate() {
        press.reset(1)
        press.set(0, animation: .press)
        startAnimating()
        onActivate?(item)
    }

    /// The context menu, anchored at the pointer (window points) or, from the keyboard, under the artwork.
    public override func showContextMenu(at point: Point?) -> Bool {
        guard let onContextMenu else { return false }
        let art = transformToWindow.apply(artworkRect)
        onContextMenu(item, point ?? Point(x: art.minX, y: art.maxY))
        return true
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [lift.advance(dt), press.advance(dt), tiltX.advance(dt), tiltY.advance(dt), artwork.advance(dt), hoverChrome.advance(dt)]
        setNeedsDisplay()
        return moving.contains(true)
    }

    // MARK: Layout and drawing

    private var artworkRect: Rect {
        let x = style.shape == .rounded ? 0 : (frame.width - style.artworkSize.width) / 2
        return Rect(x: x, y: 0, width: style.artworkSize.width, height: style.artworkSize.height)
    }

    /// The artwork's scale now: lifted by focus or hover, pressed down by a click.
    private var artworkScale: Float {
        let metrics = Theme.current.metrics
        let lifted = 1 + (metrics.artworkFocusScale - 1) * lift.value
        return lifted * (1 - (1 - metrics.pressedScale) * press.value)
    }

    public override func draw(_ context: inout DrawContext) {
        if artwork.source != item.artwork || (artwork.texture == nil && item.artwork != nil) { loadArtwork() }
        let palette = Theme.current.palette
        let metrics = Theme.current.metrics
        let type = Theme.current.type
        let art = artworkRect
        let scale = artworkScale
        let parallax = Point(x: tiltX.value * art.width * 0.012 * lift.value, y: tiltY.value * art.height * 0.012 * lift.value)
        let radius = style.shape == .circle ? art.width / 2 : metrics.cardCornerRadius
        let dimming: Float = item.isDimmed ? metrics.watchedDimming + (1 - metrics.watchedDimming) * lift.value : 1

        context.transformed(scale: scale, about: art.center, translation: parallax) { inner in
            if lift.value > 0.001 {
                inner.shadow(art, radius: radius, blur: metrics.focusShadowRadius * 0.9, offsetY: metrics.focusShadowOffset,
                             opacity: 0.55 * lift.value)
            }
            inner.faded(dimming) { faded in
                drawArtwork(in: art, radius: radius, context: &faded)
                drawDecorations(in: art, radius: radius, context: &faded)
            }
            if hoverChrome.value > 0.01, !offered.isEmpty {
                inner.fill(art, radius: radius, color: Color.shade(0.28 * hoverChrome.value))
            }
            if lift.value > 0.001 {
                let light = Point(x: art.midX - tiltX.value * art.width * 0.45, y: art.minY + art.height * (0.15 - tiltY.value * 0.3))
                inner.glow(in: art, radius: radius, center: light, glowRadius: art.width * 0.9, color: Color.white.withAlpha(0.16 * lift.value))
            }
        }

        let captionTop = art.maxY + (scale - 1) * art.height / 2 + metrics.captionSpacing + max(0, parallax.y)
        drawCaption(top: captionTop, type: type, palette: palette, metrics: metrics, context: &context)
        drawHoverActions(context: &context)
    }

    /// The hover buttons, faded in with the pointer: dark circles that light under it.
    private func drawHoverActions(context: inout DrawContext) {
        let offered = offered
        guard hoverChrome.value > 0.01, !offered.isEmpty else { return }
        let palette = Theme.current.palette
        context.faded(hoverChrome.value) { faded in
            for zone in [Zone.play, .watched, .menu] {
                let action: CardHoverActions = zone == .play ? .play : zone == .watched ? .watched : .menu
                guard offered.contains(action) else { continue }
                let rect = zoneRect(zone)
                let lit = hoveredZone == zone || pressedZone == zone
                let filled = zone == .watched && item.isWatched
                let fill = lit ? (zone == .play ? palette.accent : Color.white.withAlpha(0.9)) : (filled ? palette.accent : Color.shade(0.62))
                faded.fill(rect, radius: rect.width / 2, color: fill)
                if !filled && !lit { faded.stroke(rect, radius: rect.width / 2, width: 1, color: Color.white.withAlpha(0.35)) }
                let glyph: Symbol = zone == .play ? item.primarySymbol : zone == .watched ? "checkmark" : "ellipsis"
                let inset = rect.width * (zone == .play ? 0.32 : 0.27)
                let nudged = zone == .play && item.primarySymbol == "play.fill"
                let glyphRect = nudged ? rect.insetBy(inset, inset).offsetBy(rect.width * 0.03, 0) : rect.insetBy(inset, inset)
                let glyphColor = lit && zone != .play ? Color(hex: 0x1A1816) : palette.onArt
                faded.symbol(glyph, in: glyphRect, color: glyphColor)
            }
        }
    }

    private func drawArtwork(in art: Rect, radius: Float, context: inout DrawContext) {
        let palette = Theme.current.palette
        let opacity = artwork.texture == nil ? 0 : artwork.opacity
        if opacity < 1, let monogram = item.monogram {
            drawMonogram(monogram, in: art, radius: radius, opacity: 1 - opacity, context: &context)
        } else if opacity < 1 {
            context.fill(art, radius: radius, color: palette.surfaceRaised)
            let glyph = min(art.width, art.height) * 0.22
            let glyphRect = Rect(x: art.midX - glyph / 2, y: art.midY - glyph / 2, width: glyph, height: glyph)
            context.symbol(item.placeholderSymbol, in: glyphRect, color: palette.labelTertiary.multipliedAlpha(1 - opacity))
        }
        if let texture = artwork.texture, opacity > 0 {
            context.image(texture, in: art, radius: radius, opacity: opacity, circle: style.shape == .circle)
        }
    }

    /// A person without a photo (`MonogramView`): their initials on their own gradient, from the top left corner down.
    private func drawMonogram(_ monogram: CardItem.Monogram, in art: Rect, radius: Float, opacity: Float, context: inout DrawContext) {
        context.faded(opacity) { faded in
            faded.gradient(art, axis: .diagonal, stops: [(0, monogram.top), (1, monogram.bottom)], radius: radius)
            let text = monogram.initials.isEmpty ? "?" : monogram.initials
            let layout = TextLayout(text, font: Font(size: (art.height * 0.34).rounded(), weight: .semibold), scale: window?.scale ?? 1)
            faded.text(layout, at: Point(x: (art.midX - layout.size.width / 2).rounded(), y: (art.midY - layout.size.height / 2).rounded()),
                       color: Theme.current.palette.onArt)
        }
    }

    private func drawDecorations(in art: Rect, radius: Float, context: inout DrawContext) {
        let palette = Theme.current.palette
        let metrics = Theme.current.metrics
        let type = Theme.current.type
        let inset = metrics.badgeInset
        let showsProgress = item.hasProgress
        if style.scrimsArtwork {
            let scrim = Rect(x: art.x, y: art.maxY - art.height * 0.4, width: art.width, height: art.height * 0.4)
            context.gradient(scrim, vertical: true, stops: [(0, Color.shade(0)), (1, Color.shade(0.6))], radius: radius)
        }
        var footerBottom = art.maxY - inset
        if showsProgress, let progress = item.progress {
            let thickness = metrics.progressBarThickness
            let bar = Rect(x: art.x + inset, y: footerBottom - thickness, width: art.width - inset * 2, height: thickness)
            ProgressBarStyle.draw(progress: Float(progress), in: bar, onArt: true, context: &context)
            footerBottom = bar.y - metrics.artCaptionSpacing
        }
        if style.scrimsArtwork, let detail = item.detail, !detail.isEmpty, let scale = window?.scale {
            let layout = TextLayout(detail, font: type.artCaption, maxWidth: art.width - inset * 2, scale: scale)
            context.text(layout, at: Point(x: art.x + inset, y: footerBottom - layout.size.height), color: palette.onArt)
        }
        let hoverCoversCorners = hoverChrome.value > 0.5 && !offered.isEmpty
        if item.isUnwatched && !showsProgress && !item.isWatched && !hoverCoversCorners {
            let d = metrics.dotDiameter
            let dot = Rect(x: art.maxX - inset - d, y: art.y + inset, width: d, height: d)
            context.fill(dot.insetBy(-1.5, -1.5), radius: d, color: Color.shade(0.5))
            context.fill(dot, radius: d / 2, color: palette.accent)
        }
        if item.isWatched && !showsProgress && !hoverCoversCorners {
            let d = metrics.checkDiameter
            let badge = Rect(x: art.maxX - inset - d, y: art.maxY - inset - d, width: d, height: d)
            context.fill(badge, radius: d / 2, color: Color.shade(0.55))
            let glyph = metrics.symbolBadge
            context.symbol("checkmark", in: Rect(x: badge.midX - glyph / 2, y: badge.midY - glyph / 2, width: glyph, height: glyph), color: palette.onArt)
        }
        if let badge = item.badgeText, !badge.isEmpty, !hoverCoversCorners, let scale = window?.scale {
            BadgeStyle.draw(badge, at: Point(x: art.x + inset, y: art.y + inset), maxWidth: art.width - inset * 2, scale: scale, context: &context)
        }
    }

    private func drawCaption(top: Float, type: TypeScale, palette: Palette, metrics: Metrics, context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let alignment: TextStyle.Alignment = style.centersCaption ? .center : .leading
        let width = frame.width
        var y = top
        func place(_ layout: TextLayout) -> Float {
            style.centersCaption ? ((width - layout.size.width) / 2 * scale).rounded() / scale : 0
        }
        if style.showsEyebrow, let eyebrow = item.eyebrow, !eyebrow.isEmpty {
            let layout = TextLayout(eyebrow.uppercased(), font: type.eyebrow, maxWidth: width, alignment: alignment, scale: scale)
            context.text(layout, at: Point(x: place(layout), y: y), color: palette.accentText)
            y += layout.size.height + metrics.captionLabelSpacing
        }
        let title = TextLayout(item.title, font: type.cardTitle, maxWidth: width, maxLines: style.titleLines, alignment: alignment, scale: scale)
        context.text(title, at: Point(x: place(title), y: y), color: palette.label)
        if let match = title.showingOnly(utf16: item.titleHighlights.map { (location: $0.lowerBound, length: $0.count) }) {
            context.text(match, at: Point(x: place(title), y: y), color: palette.accentText)
        }
        y += title.size.height + metrics.captionLabelSpacing
        if let subtitle = item.subtitle, !subtitle.isEmpty {
            let layout = TextLayout(subtitle, font: type.cardSubtitle, maxWidth: width, alignment: alignment, scale: scale)
            context.text(layout, at: Point(x: place(layout), y: y), color: palette.labelSecondary)
        }
    }

    public override func sizeThatFits(_ size: Size) -> Size { style.itemSize }
}

/// The ember progress bar (`ProgressBar`): a dark track over artwork or the raised surface on cards and rows.
@MainActor
public enum ProgressBarStyle {
    public static func draw(progress: Float, in rect: Rect, onArt: Bool, context: inout DrawContext) {
        let palette = Theme.current.palette
        let radius = rect.height / 2
        context.fill(rect, radius: radius, color: onArt ? Color.shade(0.5) : palette.surfaceHigh)
        let clamped = min(max(progress, 0), 1)
        guard clamped > 0 else { return }
        context.fill(Rect(x: rect.x, y: rect.y, width: max(rect.width * clamped, rect.height), height: rect.height), radius: radius, color: palette.accent)
    }
}

/// A short caption on a dark capsule for the corner of artwork (NEW, 4K, a runtime).
@MainActor
public enum BadgeStyle {
    @discardableResult
    public static func draw(_ text: String, at origin: Point, maxWidth: Float, scale: Float, context: inout DrawContext) -> Size {
        let metrics = Theme.current.metrics
        let layout = TextLayout(text, font: Theme.current.type.badge, maxWidth: maxWidth - metrics.badgeInsetHorizontal * 2, scale: scale)
        let size = Size(width: layout.size.width + metrics.badgeInsetHorizontal * 2, height: layout.size.height + metrics.badgeInsetVertical * 2)
        context.fill(Rect(origin: origin, size: size), radius: size.height / 2, color: Color.shade(0.6))
        context.text(layout, at: Point(x: origin.x + metrics.badgeInsetHorizontal, y: origin.y + metrics.badgeInsetVertical), color: Theme.current.palette.onArt)
        return size
    }
}

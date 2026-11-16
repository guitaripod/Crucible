import Foundation

/// A scrolling container on one axis: wheel notches glide, a touchpad moves the content under the fingers with rubber
/// banding past the ends and momentum after the fingers lift, and focus moving inside scrolls the focused view into
/// view on a spring. An overlay indicator shows while it scrolls and on hover, never as a permanent bar.
@MainActor
open class ScrollView: View {
    public enum Axis: Sendable { case vertical, horizontal }

    public let axis: Axis

    /// The scrolled content's length along the axis, in points.
    public var contentLength: Float = 0 {
        didSet {
            guard contentLength != oldValue else { return }
            let clamped = clamp(position.target)
            if clamped != position.target { position.set(clamped, animation: Animation.scroll) ; startAnimating() }
            setNeedsDisplay()
        }
    }

    /// Room kept between a revealed view and the edges (a shelf's gutter, a page's top inset).
    public var revealInsets = EdgeInsets()

    /// Points per wheel notch.
    public var wheelStep: Float = 120

    /// Whether the overlay indicator shows.
    public var showsIndicator = true

    /// Desktop scrollbars for every vertical scroll view (the app's Desktop layout): a slim thumb that stays while there is
    /// more to scroll, widens under the pointer, drags, and pages on a click beside it; Page Up, Page Down, Home and End
    /// scroll too. Off, the indicator only shows while scrolling, as tvOS's does.
    public static var desktopScrollbars = false
    /// The indicator's colour: light over the dark appearance, dark over the light one.
    public static var indicatorColor = Color.white

    /// Called whenever the offset changes (the tab bar hides as content scrolls).
    public var onScroll: ((Float) -> Void)?
    /// When set, a touchpad flick settles on a multiple of this distance (a shelf's card and gutter), so a card's leading
    /// edge lands at the start, as tvOS pages a shelf.
    public var snapInterval: Float?

    private var position = Animated(0)
    private var momentum: Float = 0
    private var dragging = false
    private var recent: [(time: UInt32, delta: Float)] = []
    private var indicator = Animated(0)
    private var indicatorIdle: Float = 0
    /// How far the desktop scrollbar has widened under the pointer, 0 to 1.
    private var widen = Animated(0)
    /// Where on the thumb a drag took hold, in points from its start, while the thumb is being dragged.
    private var thumbGrab: Float?

    public init(axis: Axis, frame: Rect = .zero) {
        self.axis = axis
        super.init(frame: frame)
        clipsToBounds = true
    }

    private var viewportLength: Float { axis == .vertical ? frame.height : frame.width }

    public var maximumOffset: Float { max(0, contentLength - viewportLength) }

    /// The offset along the axis.
    public var offset: Float { position.value }

    private func clamp(_ value: Float) -> Float { min(max(value, 0), maximumOffset) }

    private func apply() {
        let value = position.value
        contentOffset = axis == .vertical ? Point(x: 0, y: value) : Point(x: value, y: 0)
        onScroll?(value)
    }

    open override func layoutSubviews() {
        super.layoutSubviews()
        let clamped = clamp(position.value)
        if clamped != position.value, !dragging, momentum == 0 {
            position.reset(clamped)
            apply()
        }
    }

    /// Scrolls to `value` along the axis.
    public func setOffset(_ value: Float, animated: Bool) {
        momentum = 0
        position.set(clamp(value), animation: animated ? Animation.scroll : nil)
        apply()
        if animated { startAnimating() }
        wake()
    }

    // MARK: Focus

    open override func reveal(_ rect: Rect, of view: View, animated: Bool) {
        let start = axis == .vertical ? rect.minY - revealInsets.top : rect.minX - revealInsets.leading
        let end = axis == .vertical ? rect.maxY + revealInsets.bottom : rect.maxX + revealInsets.trailing
        let current = position.target
        var target = current
        if end > current + viewportLength { target = end - viewportLength }
        if start < target { target = start }
        target = clamp(target)
        if target != current {
            momentum = 0
            position.set(target, animation: animated ? Animation.scroll : nil)
            apply()
            if animated { startAnimating() }
        }
        let shift = target - position.value
        let settled = axis == .vertical ? rect.offsetBy(0, -position.value - shift) : rect.offsetBy(-position.value - shift, 0)
        superview?.reveal(transformToSuperview.apply(settled), of: view, animated: animated)
    }

    // MARK: Scrolling

    open override func scrolled(_ event: ScrollEvent) -> Bool {
        let along = axis == .vertical ? event.dy : event.dx
        let across = axis == .vertical ? event.dx : event.dy
        let notches = axis == .vertical ? event.notchesY : event.notchesX
        guard maximumOffset > 0 || dragging else { return false }
        if event.isDiscrete {
            guard notches != 0 else { return false }
            if (notches < 0 && position.target <= 0) || (notches > 0 && position.target >= maximumOffset) { return false }
            momentum = 0
            var target = position.target + notches * wheelStep
            if let snapInterval, snapInterval > 0 { target = (target / snapInterval).rounded() * snapInterval }
            position.set(clamp(target), animation: .timed(duration: 0.22, curve: .easeOut))
            apply()
            startAnimating()
            wake()
            return true
        }
        if event.ended {
            guard dragging else { return false }
            dragging = false
            let velocity = releaseVelocity()
            recent.removeAll()
            if position.value < 0 || position.value > maximumOffset {
                position.set(clamp(position.value), animation: .spring(response: 0.4, dampingFraction: 1))
            } else if let snapInterval, snapInterval > 0 {
                settle(on: snapInterval, velocity: velocity)
            } else {
                momentum = abs(velocity) > 40 ? velocity : 0
                position.reset(position.value)
            }
            startAnimating()
            return true
        }
        guard along != 0 else { return dragging }
        if !dragging && abs(across) > abs(along) { return false }
        dragging = true
        momentum = 0
        recent.append((event.timeMilliseconds, along))
        if recent.count > 8 { recent.removeFirst(recent.count - 8) }
        let next = position.value + rubberBanded(along)
        position.reset(next)
        apply()
        wake()
        return true
    }

    /// Springs to the snap point nearest where the flick's momentum would have carried the content, keeping its speed.
    private func settle(on interval: Float, velocity: Float) {
        let projected = position.value + velocity * 0.5
        var target = clamp((projected / interval).rounded() * interval)
        if abs(maximumOffset - projected) < abs(target - projected) { target = maximumOffset }
        position.reset(position.value)
        position.set(target, animation: .spring(response: 0.45, dampingFraction: 1))
        position.setVelocity(velocity)
    }

    /// A drag past an end moves the content less and less, as iOS's rubber band does.
    private func rubberBanded(_ delta: Float) -> Float {
        let value = position.value
        let beyond = value < 0 ? -value : max(0, value - maximumOffset)
        guard beyond > 0 || (value + delta < 0) || (value + delta > maximumOffset) else { return delta }
        let resistance = 1 / (1 + beyond / max(viewportLength * 0.15, 1))
        return delta * resistance * 0.55
    }

    /// Points per second over the last few touchpad frames.
    private func releaseVelocity() -> Float {
        guard let last = recent.last, let first = recent.first, recent.count > 1 else { return 0 }
        let span = Float(last.time &- first.time) / 1000
        guard span > 0.004, span < 0.2 else { return 0 }
        let distance = recent.dropFirst().reduce(0) { $0 + $1.delta }
        return distance / span
    }

    private func wake() {
        indicator.set(1, animation: .timed(duration: 0.12, curve: .easeOut))
        indicatorIdle = 0
        startAnimating()
    }

    open override func advanceAnimations(_ dt: Float) -> Bool {
        var moving = false
        if momentum != 0 {
            let decay = pow(0.998, dt * 1000)
            let next = position.value + momentum * dt
            momentum *= decay
            if next < 0 || next > maximumOffset {
                position.reset(next)
                position.set(clamp(next), animation: .spring(response: 0.35, dampingFraction: 1))
                position.setVelocity(momentum)
                momentum = 0
            } else {
                position.reset(next)
                if abs(momentum) < 8 { momentum = 0 }
            }
            moving = true
            indicatorIdle = 0
        }
        if position.advance(dt) {
            moving = true
            indicatorIdle = 0
        }
        if moving || dragging { apply() }
        if !moving && !dragging && indicator.target > 0 && !isHovered {
            indicatorIdle += dt
            if indicatorIdle > 0.8 { indicator.set(0, animation: .timed(duration: 0.3, curve: .easeInOut)) }
        }
        let fading = indicator.advance(dt)
        let widening = widen.advance(dt)
        if fading || widening { setNeedsDisplay() }
        return moving || dragging || fading || widening || (indicator.target > 0 && !isHovered)
    }

    open override func pointerEntered() {
        if maximumOffset > 0 { wake() }
    }

    /// The pointer left: the indicator's idle fade starts counting.
    open override func pointerExited() {
        setWidened(thumbGrab != nil)
        guard indicator.target > 0 else { return }
        indicatorIdle = 0
        startAnimating()
    }

    open override var isPointerInteractive: Bool { true }
    open override var cursor: Cursor { .default }

    // MARK: Desktop scrollbar

    private var hasScrollbar: Bool { Self.desktopScrollbars && axis == .vertical && showsIndicator && maximumOffset > 0 }

    /// The strip along the trailing edge the scrollbar takes, in this view's points (its content scrolls; the strip does not).
    private var scrollbarStrip: Rect { Rect(x: frame.width - 16, y: 0, width: 16, height: frame.height) }

    /// The scrollbar's strip takes the pointer even over content that would, so the thumb can be grabbed anywhere.
    open override func hitTest(_ point: Point) -> View? {
        if hasScrollbar, !isHidden, alpha > 0.01, scrollbarStrip.contains(point) { return self }
        return super.hitTest(point)
    }

    open override func pointerMoved(to point: Point) {
        guard hasScrollbar else { return }
        setWidened(thumbGrab != nil || scrollbarStrip.contains(point))
        wake()
    }

    open override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard hasScrollbar, button == .primary, scrollbarStrip.contains(point) else { return false }
        let thumb = thumbSpan
        if point.y >= thumb.start && point.y <= thumb.start + thumb.length {
            thumbGrab = point.y - thumb.start
        } else {
            let page = viewportLength * 0.9
            setOffset(position.target + (point.y < thumb.start ? -page : page), animated: true)
        }
        setWidened(true)
        return true
    }

    open override func pointerDragged(to point: Point) {
        guard let grab = thumbGrab else { return }
        let thumb = thumbSpan
        let travel = max(viewportLength - thumb.length - 8, 1)
        setOffset((point.y - grab - 4) / travel * maximumOffset, animated: false)
    }

    open override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        thumbGrab = nil
        setWidened(scrollbarStrip.contains(point))
    }

    private func setWidened(_ on: Bool) {
        guard widen.target != (on ? 1 : 0) else { return }
        widen.set(on ? 1 : 0, animation: .timed(duration: 0.12, curve: .easeOut))
        startAnimating()
    }

    /// Page Up and Page Down scroll a viewport less a tenth, Home and End to the ends, when nothing inside took the key.
    open override func keyPressed(_ event: KeyEvent) -> Bool {
        guard hasScrollbar, event.modifiers.isEmpty else { return false }
        let page = viewportLength * 0.9
        switch event.key {
        case .pageDown: setOffset(position.target + page, animated: true)
        case .pageUp: setOffset(position.target - page, animated: true)
        case .home: setOffset(0, animated: true)
        case .end: setOffset(maximumOffset, animated: true)
        default: return false
        }
        return true
    }

    // MARK: Indicator

    /// Where the thumb starts along the axis and how long it is.
    private var thumbSpan: (start: Float, length: Float) {
        let length = viewportLength
        let thumb = max(length * length / max(contentLength, 1), 36)
        let progress = maximumOffset > 0 ? position.value / maximumOffset : 0
        let travel = length - thumb - 8
        return (4 + travel * min(max(progress, 0), 1), thumb)
    }

    open override func drawOverlay(_ context: inout DrawContext) {
        let shown = hasScrollbar ? max(indicator.value, 0.55) : indicator.value
        guard showsIndicator, shown > 0.01, maximumOffset > 0 else { return }
        let thumb = thumbSpan
        let thickness: Float = hasScrollbar ? 5 + 4 * widen.value : 5
        let rect = axis == .vertical
            ? Rect(x: frame.width - thickness - 3, y: thumb.start, width: thickness, height: thumb.length)
            : Rect(x: thumb.start, y: frame.height - thickness - 3, width: thumb.length, height: thickness)
        context.fill(rect, radius: thickness / 2, color: Self.indicatorColor.withAlpha((0.42 + 0.2 * widen.value) * shown))
    }
}

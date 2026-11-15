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

    /// Called whenever the offset changes (the tab bar hides as content scrolls).
    public var onScroll: ((Float) -> Void)?

    private var position = Animated(0)
    private var momentum: Float = 0
    private var dragging = false
    private var recent: [(time: UInt32, delta: Float)] = []
    private var indicator = Animated(0)
    private var indicatorIdle: Float = 0

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
            position.set(clamp(position.target + notches * wheelStep), animation: .timed(duration: 0.22, curve: .easeOut))
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
        if fading { setNeedsDisplay() }
        return moving || dragging || fading || (indicator.target > 0 && !isHovered)
    }

    open override func pointerEntered() {
        if maximumOffset > 0 { wake() }
    }

    /// The pointer left: the indicator's idle fade starts counting.
    open override func pointerExited() {
        guard indicator.target > 0 else { return }
        indicatorIdle = 0
        startAnimating()
    }

    open override var isPointerInteractive: Bool { true }
    open override var cursor: Cursor { .default }

    // MARK: Indicator

    open override func drawOverlay(_ context: inout DrawContext) {
        guard showsIndicator, indicator.value > 0.01, maximumOffset > 0 else { return }
        let length = viewportLength
        let thumb = max(length * length / max(contentLength, 1), 36)
        let progress = position.value / maximumOffset
        let travel = length - thumb - 8
        let start = 4 + travel * min(max(progress, 0), 1)
        let thickness: Float = 5
        let rect = axis == .vertical
            ? Rect(x: frame.width - thickness - 3, y: start, width: thickness, height: thumb)
            : Rect(x: start, y: frame.height - thickness - 3, width: thumb, height: thickness)
        context.fill(rect, radius: thickness / 2, color: Color.white.withAlpha(0.42 * indicator.value))
    }
}

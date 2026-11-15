import Foundation

/// A rectangle of the interface, UIKit's shape: a frame in its superview, subviews drawn over its own content, layout on
/// demand and the focus, pointer and key responders the tvOS design relies on. Geometry is in points.
@MainActor
open class View {
    public init(frame: Rect = .zero) {
        self.frame = frame
    }

    // MARK: Geometry

    public var frame: Rect {
        didSet {
            guard frame != oldValue else { return }
            if frame.size != oldValue.size { setNeedsLayout() }
            setNeedsDisplay()
        }
    }

    /// The scroll position: the point of this view's content shown at its top left.
    public var contentOffset: Point = .zero {
        didSet { if contentOffset != oldValue { setNeedsDisplay() } }
    }

    /// Scale about the centre (the focus lift), applied over layout without changing `frame`.
    public var scale: Float = 1 {
        didSet { if scale != oldValue { setNeedsDisplay() } }
    }

    /// A shift over layout (parallax, a sliding tab bar), in the superview's points.
    public var translation: Point = .zero {
        didSet { if translation != oldValue { setNeedsDisplay() } }
    }

    public var alpha: Float = 1 {
        didSet { if alpha != oldValue { setNeedsDisplay() } }
    }

    public var isHidden = false {
        willSet {
            wasPreferredWhenHidden = newValue && !isHidden && containsFocus && superview?.preferredFocusView === self
        }
        didSet {
            guard isHidden != oldValue else { return }
            setNeedsDisplay()
            if isHidden {
                window?.viewBecameUnavailable(self, formerSuperview: superview, handingOn: wasPreferredWhenHidden)
            } else {
                window?.viewBecameAvailable(self)
            }
        }
    }

    /// Clips subviews to the bounds (shelves and pages).
    public var clipsToBounds = false

    /// Whether the superview preferred this view at the moment it was hidden, so focus inside goes where it prefers next.
    private var wasPreferredWhenHidden = false

    public var bounds: Rect { Rect(x: 0, y: 0, width: frame.width, height: frame.height) }

    /// This view's points to its superview's points: content offset, then position, then the lift about the centre.
    public var transformToSuperview: Affine {
        let base = Affine(scale: 1, tx: frame.x, ty: frame.y)
        guard scale != 1 || translation != .zero else { return base }
        let cx = frame.midX
        let cy = frame.midY
        let lift = Affine(scale: scale, tx: cx - scale * cx + translation.x, ty: cy - scale * cy + translation.y)
        return lift.concatenating(base)
    }

    /// The transform into the superview's content coordinates, including the superview's scroll offset.
    var transformToSuperviewContent: Affine {
        guard let superview else { return transformToSuperview }
        return Affine(scale: 1, tx: -superview.contentOffset.x, ty: -superview.contentOffset.y).concatenating(transformToSuperview)
    }

    /// This view's points to window points, through every ancestor's offset, position and scale.
    public var transformToWindow: Affine {
        var transform = Affine.identity
        var view: View? = self
        while let current = view {
            transform = current.transformToSuperviewContent.concatenating(transform)
            view = current.superview
        }
        return transform
    }

    /// The frame in window points, with lifts and scrolling applied.
    public var frameInWindow: Rect { transformToWindow.apply(bounds) }

    /// The frame in window points as layout placed it, ignoring this view's own lift: what focus geometry measures, so a
    /// lifted card does not reach into its neighbours.
    public var layoutFrameInWindow: Rect {
        guard let superview else { return frame }
        let parent = Affine(scale: 1, tx: -superview.contentOffset.x, ty: -superview.contentOffset.y)
        return superview.transformToWindow.concatenating(parent).apply(frame)
    }

    public func convert(_ point: Point, from view: View?) -> Point {
        let windowPoint = view?.transformToWindow.apply(point) ?? point
        return transformToWindow.inverted.apply(windowPoint)
    }

    // MARK: Hierarchy

    public private(set) var subviews: [View] = []
    public private(set) weak var superview: View?
    public internal(set) weak var window: Window? {
        didSet {
            guard window !== oldValue else { return }
            for subview in subviews { subview.window = window }
            guard let window else { return }
            if animationPending {
                animationPending = false
                window.startAnimating(self)
            }
            didMoveToWindow()
        }
    }

    /// `startAnimating` was asked for before the view was in a window; the animation starts when it joins one.
    private var animationPending = false

    public func addSubview(_ view: View) {
        insertSubview(view, at: subviews.count)
    }

    public func insertSubview(_ view: View, at index: Int) {
        view.removeFromSuperview()
        subviews.insert(view, at: min(max(index, 0), subviews.count))
        view.superview = self
        view.window = window
        setNeedsLayout()
        setNeedsDisplay()
    }

    public func insertSubview(_ view: View, below sibling: View) {
        insertSubview(view, at: subviews.firstIndex { $0 === sibling } ?? 0)
    }

    public func removeFromSuperview() {
        guard let superview else { return }
        let oldWindow = window
        superview.subviews.removeAll { $0 === self }
        superview.setNeedsDisplay()
        self.superview = nil
        window = nil
        oldWindow?.viewBecameUnavailable(self, formerSuperview: superview)
    }

    public func removeAllSubviews() {
        for subview in subviews { subview.removeFromSuperview() }
    }

    public func isDescendant(of view: View) -> Bool {
        var current: View? = self
        while let candidate = current {
            if candidate === view { return true }
            current = candidate.superview
        }
        return false
    }

    /// Visible: in a window, not hidden and not transparent, nor any ancestor.
    public var isVisible: Bool {
        guard window != nil else { return false }
        var view: View? = self
        while let current = view {
            if current.isHidden || current.alpha <= 0.001 { return false }
            view = current.superview
        }
        return true
    }

    open func didMoveToWindow() {}

    // MARK: Layout and drawing

    private(set) var needsLayout = true

    public func setNeedsLayout() {
        needsLayout = true
        window?.setNeedsDisplay()
    }

    public func setNeedsDisplay() {
        window?.setNeedsDisplay()
    }

    public func layoutIfNeeded() {
        if needsLayout {
            needsLayout = false
            layoutSubviews()
        }
        for subview in subviews where !subview.isHidden { subview.layoutIfNeeded() }
    }

    /// Positions the subviews in `bounds`.
    open func layoutSubviews() {}

    /// The size this view wants inside `size` (labels measure their text; containers sum their content).
    open func sizeThatFits(_ size: Size) -> Size { frame.size }

    /// Draws this view's own content in its points, under its subviews.
    open func draw(_ context: inout DrawContext) {}

    /// How far, in points, this view's drawing reaches outside its bounds (shadows, lifts); views entirely outside the
    /// clip by more than this are skipped.
    open var overdraw: Float { 0 }

    /// Draws over the subviews (focus rings, scroll indicators).
    open func drawOverlay(_ context: inout DrawContext) {}

    // MARK: Animation

    /// Advances this view's animated values by `dt` seconds; returns whether any is still moving. A view starts
    /// receiving these with `startAnimating()`.
    open func advanceAnimations(_ dt: Float) -> Bool { false }

    public func startAnimating() {
        guard let window else {
            animationPending = true
            return
        }
        window.startAnimating(self)
        setNeedsDisplay()
    }

    // MARK: Focus

    /// Whether the focus engine may move focus here (cards, buttons, rows, chips).
    open var canBecomeFocused: Bool { false }

    public var isFocused: Bool { window?.focusedView === self }

    /// Whether focus is on this view or inside it.
    public var containsFocus: Bool {
        guard let focused = window?.focusedView else { return false }
        return focused.isDescendant(of: self)
    }

    /// The view focus goes to when it enters this container without a remembered child (tvOS `preferredFocusEnvironments`).
    open var preferredFocusView: View? { nil }

    /// Whether focus returning into this container goes back to the child it left from (a shelf's last card).
    open var remembersFocus: Bool { false }

    /// A modal overlay (a menu, an alert): while focus is inside it, arrows and Tab move only among its own views.
    open var isFocusScope: Bool { false }

    /// The child focus last left this container from, while it is still in the container.
    public weak var rememberedFocus: View?

    /// Called when this view gains or loses focus; `animated` is false for the first focus of a screen.
    open func focusDidChange(focused: Bool, animated: Bool) {}

    /// Called on every view when the keyboard starts or stops showing focus (the focus-visible rule).
    open func focusVisibilityDidChange(_ visible: Bool) {}

    /// Called on every container the focus left or entered, with the view that has it now.
    open func descendantFocusDidChange(to view: View?) {}

    /// Scrolls ancestors so `rect` (in this view's points) is in view; scroll containers override it.
    open func reveal(_ rect: Rect, of view: View, animated: Bool) {
        superview?.reveal(transformToSuperview.apply(rect), of: view, animated: animated)
    }

    // MARK: Pointer and keys

    /// Whether the pointer interacts with this view (hover, click); focusable views do by default.
    open var isPointerInteractive: Bool { canBecomeFocused }

    open var cursor: Cursor { isPointerInteractive ? .pointer : .default }

    /// Whether the pointer is over this view (hover lift).
    public internal(set) var isHovered = false

    /// The deepest interactive view under `point` (in this view's points), front to back.
    open func hitTest(_ point: Point) -> View? {
        guard !isHidden, alpha > 0.01 else { return nil }
        let inside = bounds.contains(point)
        if clipsToBounds && !inside { return nil }
        let inner = Point(x: point.x + contentOffset.x, y: point.y + contentOffset.y)
        for subview in subviews.reversed() {
            let local = subview.transformToSuperview.inverted.apply(inner)
            if let hit = subview.hitTest(local) { return hit }
        }
        return inside && isPointerInteractive ? self : nil
    }

    open func pointerEntered() {}
    open func pointerExited() {}
    open func pointerMoved(to point: Point) {}

    /// A press on this view; returning false passes it to the superview.
    open func pointerPressed(_ button: MouseButton, at point: Point) -> Bool { false }

    open func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {}

    /// Scrolling over this view; returning false passes it to the superview.
    open func scrolled(_ event: ScrollEvent) -> Bool { false }

    /// A key while focus is on or inside this view; returning false passes it up to the window.
    open func keyPressed(_ event: KeyEvent) -> Bool { false }

    /// The primary action: Enter, a click, the A button.
    open func activate() {}

    /// The context menu: right click, the Menu key, Y on a gamepad.
    open func showContextMenu(at point: Point?) -> Bool { false }

    /// A short label for accessibility and tooltips.
    open var accessibilityLabel: String? { nil }

    /// What a tooltip says when the pointer rests on `point` (in this view's points): the name of an icon-only control.
    open func tooltip(at point: Point) -> String? { nil }
}

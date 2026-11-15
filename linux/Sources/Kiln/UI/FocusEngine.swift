import Foundation

/// tvOS focus for a desk: geometric movement with the arrows, reading order with Tab, preferred focus and focus memory
/// for containers, and a focus that is drawn only once the keyboard is in use. Hover never moves it.
@MainActor
public final class FocusEngine {
    weak var window: Window?
    public private(set) weak var focusedView: View?
    public private(set) var isVisible = false

    /// Called after focus moves, with the old and new views.
    public var onChange: ((View?, View?) -> Void)?

    // MARK: Moving focus

    /// Focuses `view` (or what it prefers when it is a container), scrolling it into view.
    @discardableResult
    public func focus(_ view: View?, animated: Bool = true, reveal: Bool = true) -> Bool {
        let resolved = view.flatMap { resolve($0) }
        if view != nil && resolved == nil { return false }
        guard resolved !== focusedView else { return resolved != nil }
        let old = focusedView
        if let old {
            var container = old.superview
            while let current = container {
                if current.remembersFocus, resolved.map({ !$0.isDescendant(of: current) }) ?? true {
                    current.rememberedFocus = old
                }
                container = current.superview
            }
        }
        focusedView = resolved
        old?.focusDidChange(focused: false, animated: animated)
        resolved?.focusDidChange(focused: true, animated: animated)
        notifyAncestors(of: old, and: resolved)
        if reveal, let resolved, let superview = resolved.superview {
            superview.reveal(resolved.frame, of: resolved, animated: animated)
        }
        onChange?(old, resolved)
        window?.textInputFocusChanged()
        window?.setNeedsDisplay()
        return resolved != nil
    }

    /// Tells every container the focus left or entered that it moved, once each, innermost first.
    private func notifyAncestors(of old: View?, and new: View?) {
        var told: Set<ObjectIdentifier> = []
        for start in [old?.superview, new?.superview] {
            var container = start
            while let current = container {
                if told.insert(ObjectIdentifier(current)).inserted { current.descendantFocusDidChange(to: new) }
                container = current.superview
            }
        }
    }

    /// The view focus lands on when asked to focus `view`: itself when focusable, otherwise its remembered or preferred
    /// child, otherwise its first focusable descendant in reading order.
    func resolve(_ view: View) -> View? {
        if view.canBecomeFocused && view.isVisible { return view }
        if view.remembersFocus, let remembered = view.rememberedFocus, remembered.isDescendant(of: view), let resolved = resolve(remembered) {
            return resolved
        }
        if let preferred = view.preferredFocusView, preferred !== view, let resolved = resolve(preferred) { return resolved }
        return Self.readingOrder(candidates(in: view)).first
    }

    /// Every focusable, visible view in `root`.
    func candidates(in root: View) -> [View] {
        var found: [View] = []
        func walk(_ view: View) {
            guard !view.isHidden, view.alpha > 0.001 else { return }
            if view.canBecomeFocused { found.append(view) }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        return found
    }

    static func readingOrder(_ views: [View]) -> [View] {
        views.map { ($0, $0.layoutFrameInWindow) }.sorted { lhs, rhs in
            let a = lhs.1
            let b = rhs.1
            if abs(a.minY - b.minY) > min(a.height, b.height) / 2 { return a.minY < b.minY }
            return a.minX < b.minX
        }.map(\.0)
    }

    /// Moves focus one step in `direction` from the focused view; returns whether it moved. Views placed since the last frame
    /// (a menu opened by the key before) are laid out first, so their places are real.
    @discardableResult
    public func move(_ direction: Direction) -> Bool {
        guard let window else { return false }
        guard let current = focusedView, current.window === window else {
            return focus(window.contentView, animated: false)
        }
        let area = scope(of: current, in: window)
        area.layoutIfNeeded()
        guard let target = Self.nearest(from: current, direction: direction, among: candidates(in: area)) else { return false }
        return focus(entry(into: target, from: current), animated: true)
    }

    /// Where arrows and Tab look for the next view: the innermost focus scope (a menu, an alert) holding `view`, otherwise
    /// the whole window.
    private func scope(of view: View, in window: Window) -> View {
        var current: View? = view
        while let candidate = current {
            if candidate.isFocusScope { return candidate }
            current = candidate.superview
        }
        return window.contentView
    }

    /// Focus moving into a container that remembers its last focus goes back there instead of to the nearest child.
    private func entry(into target: View, from current: View) -> View {
        var container = target.superview
        var outermost: View?
        while let view = container {
            if view.remembersFocus, !current.isDescendant(of: view), let remembered = view.rememberedFocus,
               remembered.isDescendant(of: view), remembered.canBecomeFocused, remembered.isVisible {
                outermost = remembered
            }
            container = view.superview
        }
        return outermost ?? target
    }

    /// The best candidate in `direction`: among views beyond the focused one in that direction, those overlapping its
    /// span across the direction win; then the smallest gap along it, with the offset across it weighing in. Left and right
    /// stay in the focused view's row, so the end of a shelf stops focus instead of jumping to a row above or below.
    static func nearest(from current: View, direction: Direction, among views: [View]) -> View? {
        let origin = current.layoutFrameInWindow
        var best: (view: View, overlaps: Bool, score: Float)?
        for view in views where view !== current {
            let frame = view.layoutFrameInWindow
            let gap: Float
            let overlap: Float
            let across: Float
            switch direction {
            case .right:
                guard frame.minX >= origin.maxX - 1 || (frame.midX > origin.maxX && frame.minX > origin.minX) else { continue }
                gap = max(0, frame.minX - origin.maxX)
                overlap = min(frame.maxY, origin.maxY) - max(frame.minY, origin.minY)
                across = abs(frame.midY - origin.midY)
            case .left:
                guard frame.maxX <= origin.minX + 1 || (frame.midX < origin.minX && frame.maxX < origin.maxX) else { continue }
                gap = max(0, origin.minX - frame.maxX)
                overlap = min(frame.maxY, origin.maxY) - max(frame.minY, origin.minY)
                across = abs(frame.midY - origin.midY)
            case .down:
                guard frame.minY >= origin.maxY - 1 || (frame.midY > origin.maxY && frame.minY > origin.minY) else { continue }
                gap = max(0, frame.minY - origin.maxY)
                overlap = min(frame.maxX, origin.maxX) - max(frame.minX, origin.minX)
                across = edgeDistance(frame.minX, frame.maxX, origin.minX, origin.maxX) + abs(frame.minX - origin.minX) * 0.05
            case .up:
                guard frame.maxY <= origin.minY + 1 || (frame.midY < origin.minY && frame.maxY < origin.maxY) else { continue }
                gap = max(0, origin.minY - frame.maxY)
                overlap = min(frame.maxX, origin.maxX) - max(frame.minX, origin.minX)
                across = edgeDistance(frame.minX, frame.maxX, origin.minX, origin.maxX) + abs(frame.minX - origin.minX) * 0.05
            }
            let overlaps = overlap > 0
            if direction.isHorizontal && !overlaps { continue }
            let score = gap + across * (overlaps ? 0.5 : 2)
            if let current = best {
                if current.overlaps && !overlaps { continue }
                if overlaps && !current.overlaps || score < current.score { best = (view, overlaps, score) }
            } else {
                best = (view, overlaps, score)
            }
        }
        return best?.view
    }

    private static func edgeDistance(_ a0: Float, _ a1: Float, _ b0: Float, _ b1: Float) -> Float {
        if a1 < b0 { return b0 - a1 }
        if b1 < a0 { return a0 - b1 }
        return 0
    }

    /// Tab and Shift+Tab: the next or previous focusable view in reading order, wrapping.
    @discardableResult
    public func cycle(backward: Bool) -> Bool {
        guard let window else { return false }
        let area = focusedView.map { scope(of: $0, in: window) } ?? window.contentView
        area.layoutIfNeeded()
        let ordered = Self.readingOrder(candidates(in: area))
        guard !ordered.isEmpty else { return false }
        guard let current = focusedView, let index = ordered.firstIndex(where: { $0 === current }) else {
            return focus(backward ? ordered.last : ordered.first)
        }
        let next = (index + (backward ? ordered.count - 1 : 1)) % ordered.count
        return focus(ordered[next])
    }

    // MARK: Keys and visibility

    /// Arrows, Tab and Enter. Any of them shows focus; the first press after a click only shows it where it is.
    func handle(_ event: KeyEvent) -> Bool {
        if let direction = event.key.direction, event.modifiers.isDisjoint(with: [.control, .alt, .super]) {
            if !isVisible {
                setVisible(true)
                if focusedView != nil { return true }
            }
            if !move(direction) { bump(direction) }
            return true
        }
        if event.key == .tab || event.key == .leftTab {
            setVisible(true)
            return cycle(backward: event.key == .leftTab || event.modifiers.contains(.shift))
        }
        if event.key.isActivation, event.modifiers.isEmpty, let focusedView {
            setVisible(true)
            focusedView.activate()
            return true
        }
        if event.key == .menu, let focusedView {
            return focusedView.showContextMenu(at: nil)
        }
        return false
    }

    /// The pointer clicked: hide the focus ring until the keyboard is used again.
    func pointerDidClick() {
        setVisible(false)
    }

    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if let window { broadcastVisibility(window.contentView, visible) }
        window?.setNeedsDisplay()
    }

    private func broadcastVisibility(_ view: View, _ visible: Bool) {
        view.focusVisibilityDidChange(visible)
        for subview in view.subviews { broadcastVisibility(subview, visible) }
    }

    /// Focus could not move: the focused view nudges toward the edge it hit, as tvOS does.
    private func bump(_ direction: Direction) {
        (focusedView as? FocusBumping)?.bump(direction)
    }

    /// A view left the tree or was hidden: focus moves to the nearest focusable view in the closest container that still
    /// has one (a removed card's neighbour in its shelf before anything in another shelf), as tvOS re-resolves it. With
    /// `handingOn`, the view was what its container preferred as it hid (a loading state giving way to the content), so focus
    /// goes where the container prefers now instead.
    func viewBecameUnavailable(_ view: View, formerSuperview: View?, handingOn: Bool = false) {
        guard let focused = focusedView, focused === view || focused.isDescendant(of: view) else { return }
        let lastFrame = focused.layoutFrameInWindow
        focusedView = nil
        focused.focusDidChange(focused: false, animated: false)
        guard let window else { return }
        var container = formerSuperview
        var replacement = handingOn ? formerSuperview.flatMap(resolve).flatMap { $0.isDescendant(of: view) ? nil : $0 } : nil
        while replacement == nil, let current = container {
            let nearby = candidates(in: current).filter { $0 !== focused && !$0.isDescendant(of: view) }
            replacement = nearby.min { distance($0.layoutFrameInWindow, lastFrame) < distance($1.layoutFrameInWindow, lastFrame) }
            container = current.superview
        }
        if replacement == nil {
            replacement = candidates(in: window.contentView).min { distance($0.layoutFrameInWindow, lastFrame) < distance($1.layoutFrameInWindow, lastFrame) }
        }
        if let replacement { focus(replacement, animated: false, reveal: false) }
        onChange?(focused, focusedView)
        window.textInputFocusChanged()
    }

    private func distance(_ a: Rect, _ b: Rect) -> Float {
        let dx = a.midX - b.midX
        let dy = a.midY - b.midY
        return dx * dx + dy * dy
    }
}

/// A focusable view that answers a blocked move with a small nudge toward the edge.
@MainActor
public protocol FocusBumping: AnyObject {
    func bump(_ direction: Direction)
}

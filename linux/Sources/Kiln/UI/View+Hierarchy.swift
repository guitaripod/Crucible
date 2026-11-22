import Foundation

extension View {
    /// Whether this view or an ancestor is hidden (transparency does not count: a view fading in from zero still animates).
    public var isUnderHiddenView: Bool {
        var view: View? = self
        while let current = view {
            if current.isHidden { return true }
            view = current.superview
        }
        return false
    }

    /// The deepest view under `point` whether or not it is interactive: scrolling goes to whatever is under the pointer.
    func hitTestAny(_ point: Point) -> View? {
        guard !isHidden, alpha > 0.01 else { return nil }
        let inside = bounds.contains(point)
        if clipsToBounds && !inside { return nil }
        let inner = Point(x: point.x + contentOffset.x, y: point.y + contentOffset.y)
        for subview in subviews.reversed() {
            if let hit = subview.hitTestAny(subview.transformToSuperview.inverted.apply(inner)) { return hit }
        }
        return inside ? self : nil
    }
}

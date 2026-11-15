import Foundation
import Kiln

/// A screen's vertical page: sections stacked top to bottom (hero, shelves, grids), scrolling under the wheel and the
/// touchpad and to whatever takes focus, keeping a focused row clear of the tab bar.
@MainActor
public final class PageView: ScrollView {
    public private(set) var sections: [View] = []
    /// Room above the first section (the tab bar's clearance on pushed screens, less under a hero).
    public var topInset: Float = 0 { didSet { setNeedsLayout() } }
    public var bottomInset: Float = 0 { didSet { setNeedsLayout() } }

    private var appearance = Animated(1)

    public init() {
        super.init(axis: .vertical)
    }

    /// Fades the page in where it takes over from a loading or empty state while the screen is up (`TVScreenViewController`'s
    /// 0.25 s dissolve); at once under Reduce Motion or before the page is in a window. It starts just above invisible, so
    /// focus can land in it at once.
    public func fadeIn() {
        guard window != nil else { return }
        appearance.reset(0.02)
        appearance.set(1, animation: .fade)
        alpha = appearance.value
        startAnimating()
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let scrolling = super.advanceAnimations(dt)
        let fading = appearance.advance(dt)
        alpha = appearance.value
        return scrolling || fading
    }

    public func setSections(_ views: [View]) {
        for section in sections where !views.contains(where: { $0 === section }) { section.removeFromSuperview() }
        sections = views
        for view in views where view.superview !== self { addSubview(view) }
        setNeedsLayout()
    }

    public override func layoutSubviews() {
        let metrics = Theme.current.metrics
        revealInsets = EdgeInsets(top: metrics.tabBarClearance, bottom: metrics.tv(60))
        wheelStep = metrics.tv(200)
        var y = topInset
        for section in sections where !section.isHidden {
            let size = section.sizeThatFits(Size(width: frame.width, height: frame.height))
            section.frame = Rect(x: 0, y: y, width: frame.width, height: size.height)
            y += size.height
        }
        contentLength = y + bottomInset
        super.layoutSubviews()
    }
}

/// A fixed-height block in a page (the hero's room, a spacer).
@MainActor
public final class SpacerView: View {
    public var height: Float

    public init(height: Float) {
        self.height = height
        super.init()
    }

    public override func sizeThatFits(_ size: Size) -> Size { Size(width: size.width, height: height) }
}

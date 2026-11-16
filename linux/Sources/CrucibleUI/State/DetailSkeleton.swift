import Foundation
import Kiln

/// A title page while it loads (`TVDetailSkeletonView`): soft blocks where the title, facts, synopsis and button will be,
/// over a row of people, pulsing together on the canvas. It holds the focus until the page arrives, then fades out under
/// it.
@MainActor
public final class DetailSkeletonView: View {
    private let shelf = SkeletonShelfView(style: .person)
    private var pulse: Float = 0
    private var fade = Animated(1)

    public init() {
        super.init()
        shelf.count = 8
        addSubview(shelf)
    }

    public override var canBecomeFocused: Bool { !isHidden }
    public override var isPointerInteractive: Bool { false }
    public override func didMoveToWindow() { startAnimating() }

    /// Shows the skeleton at full strength again, for a page that reloads from nothing.
    public func show() {
        fade.reset(1)
        alpha = 1
        isHidden = false
        startAnimating()
    }

    /// Fades the skeleton out under the arrived page and hides it.
    public func fadeOut() {
        guard !isHidden else { return }
        fade.set(0, animation: .fade)
        if !fade.isAnimating { finishFade() }
        startAnimating()
    }

    private func finishFade() {
        isHidden = true
        alpha = 1
        fade.reset(1)
    }

    /// The pulse steps thirty times a second; the fade that hands over to the page runs every frame.
    public override var animationInterval: Double? { fade.isAnimating ? nil : 1.0 / 30 }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let fading = fade.advance(dt)
        alpha = fade.value
        if !fading, fade.value < 0.001 { finishFade() }
        guard window != nil, !isHidden else { return false }
        if !Animation.reduceMotion {
            pulse = (pulse + dt / (Durations.skeletonPulse * 2)).truncatingRemainder(dividingBy: 1)
        }
        setNeedsDisplay()
        return fading || !Animation.reduceMotion
    }

    public override func layoutSubviews() {
        let height = shelf.sizeThatFits(Size(width: frame.width, height: 0)).height
        shelf.frame = Rect(x: 0, y: frame.height - height - Theme.current.metrics.tv(40), width: frame.width, height: height)
    }

    public override func draw(_ context: inout DrawContext) {
        let metrics = Theme.current.metrics
        let palette = Theme.current.palette
        context.fill(bounds, color: palette.canvas)
        let opacity: Float = Animation.reduceMotion ? 1 : 0.775 + 0.225 * cos(pulse * 2 * .pi)
        let block = palette.surfaceRaised.multipliedAlpha(opacity)
        let radius = metrics.radiusXS
        let sizes: [(width: Float, height: Float, gapAfter: Float)] = [
            (520, 64, 32), (360, 28, 48), (900, 26, 32), (860, 26, 32), (640, 26, 48),
        ]
        let button = metrics.primaryControlHeight
        var height = button
        for size in sizes { height += metrics.tv(size.height) + metrics.tv(size.gapAfter) }
        var y = shelf.frame.minY - metrics.tv(48) - height
        let x = metrics.sideMargin
        for size in sizes {
            context.fill(Rect(x: x, y: y, width: min(metrics.tv(size.width), frame.width - x * 2), height: metrics.tv(size.height)), radius: radius, color: block)
            y += metrics.tv(size.height) + metrics.tv(size.gapAfter)
        }
        context.fill(Rect(x: x, y: y, width: metrics.tv(360), height: button), radius: button / 2, color: block)
    }
}

import Foundation
import Kiln

/// The tvOS 26 soft top edge: content scrolling up under where the tab bar floats fades into the canvas instead of being
/// cut off at the window's edge. It lies over the scrolling content and takes no pointer input; set `alpha` from how far
/// the content has scrolled, so it is not there while nothing is under it.
@MainActor
public final class SoftTopEdgeView: View {
    public override init(frame: Rect = .zero) {
        super.init(frame: frame)
        alpha = 0
    }

    /// How tall the fade is.
    public static var height: Float { Theme.current.metrics.tv(170) }

    public override func draw(_ context: inout DrawContext) {
        let canvas = Theme.current.palette.canvas
        context.gradient(bounds, vertical: true, stops: [
            (0, canvas.withAlpha(0.94)),
            (0.45, canvas.withAlpha(0.6)),
            (1, canvas.withAlpha(0)),
        ])
    }
}

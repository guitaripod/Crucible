import Foundation
import Kiln

/// The label a tooltip shows near the pointer: the name of an icon-only control on a dark capsule, as desktop tooltips
/// are, so it reads over glass and video alike.
@MainActor
public final class TooltipView: View {
    private let text: String

    public init(text: String) {
        self.text = text
        super.init()
    }

    private func layout(scale: Float) -> TextLayout {
        TextLayout(text, font: Theme.current.type.caption1, maxWidth: Theme.current.metrics.tv(600), maxLines: 2, scale: scale)
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        let label = layout(scale: window?.scale ?? 1).size
        return Size(width: (label.width + metrics.tv(32)).rounded(.up), height: (label.height + metrics.tv(16)).rounded(.up))
    }

    public override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let metrics = Theme.current.metrics
        context.shadow(bounds, radius: bounds.height / 2, blur: metrics.tv(16), offsetY: metrics.tv(4), opacity: 0.35)
        context.fill(bounds, radius: bounds.height / 2, color: Color.black.withSRGBAlpha(0.82))
        context.stroke(bounds, radius: bounds.height / 2, width: 1, color: Color.white.withAlpha(0.14))
        context.text(layout(scale: scale), at: Point(x: metrics.tv(16), y: metrics.tv(8)), color: .white)
    }
}

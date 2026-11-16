import Foundation
import Kiln

/// A block of read-only information (the account, the server, the log's counts, the statistics hero), as
/// `TVReadOnlyPanel`: a screen reader follows the focus, so while one listens the panel becomes a focus stop that it reads
/// as one element, ringed by a thin accent rim. Sighted users never meet a focus stop that does nothing.
@MainActor
open class ReadOnlyPanelView: View {
    private var rimOutset: Float { Theme.current.metrics.tv(14) }

    open override var canBecomeFocused: Bool { window?.isScreenReaderActive == true }
    open override var isPointerInteractive: Bool { false }
    open override var accessibilityRole: AccessibilityRole { .label }
    open override var accessibilityExposesChildren: Bool { false }
    open override var overdraw: Float { rimOutset + Theme.current.metrics.tv(4) }

    open override func focusDidChange(focused: Bool, animated: Bool) {
        setNeedsDisplay()
    }

    open override func drawOverlay(_ context: inout DrawContext) {
        guard isFocused else { return }
        let metrics = Theme.current.metrics
        context.stroke(bounds.insetBy(-rimOutset, -rimOutset), radius: metrics.radiusM + rimOutset, width: max(metrics.tv(3), 1.5),
                       color: Theme.current.palette.accent)
    }
}

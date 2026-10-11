import UIKit

/// An invisible, focusable point that holds focus on a screen while it has nothing else to focus
/// (loading, a state without a button), so Menu goes back instead of leaving the app from the tab bar.
/// It is focusable only while `isNeeded` says so: a focusable point in the middle of the screen
/// would otherwise win a directional move from the tab bar over the real content below it.
final class TVFocusAnchorView: UIView {
    var isNeeded: @MainActor () -> Bool = { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        alpha = 0.02
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { !isHidden && isNeeded() }
}

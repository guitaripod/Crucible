import UIKit

extension UIView {
    /// Self-sizing content views must report a finite height for any fitting target; without a
    /// bounded height constraint UIKit's expanded-size pass returns an unbounded value and asserts.
    /// A weak zero-height preference collapses the view to its content while leaving every
    /// required constraint, and the cell-imposed size, in charge.
    func preferContentHeight() {
        let preference = heightAnchor.constraint(equalToConstant: 0)
        preference.priority = UILayoutPriority(100)
        preference.isActive = true
    }
}

extension UIImageView {
    /// An aspect-fill image view pinned inside a card must never size the card: its intrinsic size is
    /// the decoded bitmap's, so once an image is cached a re-dequeue measures the card at the
    /// artwork's own height instead of the layout's.
    func ignoreIntrinsicSize() {
        for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
            setContentHuggingPriority(UILayoutPriority(1), for: axis)
            setContentCompressionResistancePriority(UILayoutPriority(1), for: axis)
        }
    }
}

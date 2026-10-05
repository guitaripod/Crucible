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

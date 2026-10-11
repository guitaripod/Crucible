import CrucibleDesign
import UIKit

/// The focus lift of custom focusable views: a 1.04 scale and a soft shadow, driven through the
/// focus animation coordinator so it moves with the system's own animation. `TVFocusableSurface` and
/// `TVRowCell` both use it, so every plate lifts the same way.
@MainActor
enum TVFocusLift {
    static func prepare(_ view: UIView) {
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0
        view.layer.shadowRadius = TVMetrics.Focus.shadowRadius
        view.layer.shadowOffset = TVMetrics.Focus.shadowOffset
    }

    static func transform(focused: Bool) -> CGAffineTransform {
        focused ? CGAffineTransform(scaleX: TVMetrics.Focus.scale, y: TVMetrics.Focus.scale) : .identity
    }

    static func apply(to view: UIView, focused: Bool) {
        view.transform = transform(focused: focused)
        view.layer.shadowOpacity = focused ? TVMetrics.Focus.shadowOpacity : 0
    }

    static func animate(_ view: UIView, focused: Bool, with coordinator: UIFocusAnimationCoordinator, alongside extra: (() -> Void)? = nil) {
        coordinator.addCoordinatedAnimations({
            apply(to: view, focused: focused)
            extra?()
        })
    }

    static func updateShadowPath(of view: UIView, cornerRadius: CGFloat) {
        view.layer.shadowPath = UIBezierPath(roundedRect: view.bounds, cornerRadius: cornerRadius).cgPath
    }
}

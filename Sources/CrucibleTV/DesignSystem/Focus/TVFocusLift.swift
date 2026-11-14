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

    static func transform(focused: Bool, scale: CGFloat = TVMetrics.Focus.scale) -> CGAffineTransform {
        focused ? CGAffineTransform(scaleX: scale, y: scale) : .identity
    }

    static func apply(to view: UIView, focused: Bool, scale: CGFloat = TVMetrics.Focus.scale) {
        view.transform = transform(focused: focused, scale: scale)
        view.layer.shadowOpacity = focused ? TVMetrics.Focus.shadowOpacity : 0
    }

    static func animate(
        _ view: UIView,
        focused: Bool,
        scale: CGFloat = TVMetrics.Focus.scale,
        with coordinator: UIFocusAnimationCoordinator,
        alongside extra: (() -> Void)? = nil
    ) {
        coordinator.addCoordinatedAnimations({
            apply(to: view, focused: focused, scale: scale)
            extra?()
        })
    }

    /// The scale that grows a view `width` points wide by `Row.focusGrowth` at each side, never more than `Focus.scale`: a
    /// full-width row lifts as far past its edges as a half-width one instead of reaching beyond the safe area.
    static func rowScale(width: CGFloat) -> CGFloat {
        guard width > 0 else { return TVMetrics.Focus.scale }
        return min(TVMetrics.Focus.scale, 1 + 2 * TVMetrics.Row.focusGrowth / width)
    }

    static func updateShadowPath(of view: UIView, cornerRadius: CGFloat) {
        view.layer.shadowPath = UIBezierPath(roundedRect: view.bounds, cornerRadius: cornerRadius).cgPath
    }
}

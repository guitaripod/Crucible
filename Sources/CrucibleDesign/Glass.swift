import CrucibleCore
@preconcurrency import UIKit

@MainActor
package enum Glass {
    /// The single gate for every glass decision: true on iOS 26 and later, and on tvOS 26 and later
    /// only when the Apple TV can render Liquid Glass.
    package static let isAvailable: Bool = {
        guard #available(iOS 26.0, tvOS 26.0, *) else { return false }
        return DeviceModel.supportsLiquidGlass
    }()

    /// Whether the system's focus effect on an image view takes its outline from the view's corner radius and draws its rim
    /// along it, as tvOS 26 and later do on every Apple TV. Earlier systems draw the effect on the image itself, so an image
    /// view there masks the effect to the shape baked into its picture (`masksFocusEffectToContents`).
    package static let systemShapesFocusEffect: Bool = {
        guard #available(iOS 26.0, tvOS 26.0, *) else { return false }
        return true
    }()

    package static func effectView(
        fallback: UIBlurEffect.Style,
        clear: Bool = false,
        interactive: Bool = false
    ) -> UIVisualEffectView {
        if isAvailable, #available(iOS 26.0, tvOS 26.0, *) {
            let effect = UIGlassEffect(style: clear ? .clear : .regular)
            effect.isInteractive = interactive
            return UIVisualEffectView(effect: effect)
        }
        return UIVisualEffectView(effect: UIBlurEffect(style: fallback))
    }

    package static func concentricCorners(_ view: UIView, fallbackRadius: CGFloat) {
        if isAvailable, #available(iOS 26.0, tvOS 26.0, *) {
            view.cornerConfiguration = .corners(radius: .containerConcentric())
        } else {
            view.layer.cornerRadius = fallbackRadius
            view.layer.cornerCurve = .continuous
        }
    }

    package static func prominentButton(_ fallback: () -> UIButton.Configuration) -> UIButton.Configuration {
        if isAvailable, #available(iOS 26.0, tvOS 26.0, *) {
            return .prominentGlass()
        }
        return fallback()
    }

    package static func glassButton(_ fallback: () -> UIButton.Configuration) -> UIButton.Configuration {
        if isAvailable, #available(iOS 26.0, tvOS 26.0, *) {
            return .glass()
        }
        return fallback()
    }

    package static func clearGlassButton(_ fallback: () -> UIButton.Configuration) -> UIButton.Configuration {
        if isAvailable, #available(iOS 26.0, tvOS 26.0, *) {
            return .clearGlass()
        }
        return fallback()
    }
}

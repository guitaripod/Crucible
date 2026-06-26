@preconcurrency import UIKit

@MainActor
enum Glass {
    static func effectView(
        fallback: UIBlurEffect.Style,
        clear: Bool = false,
        interactive: Bool = false
    ) -> UIVisualEffectView {
        if #available(iOS 26.0, tvOS 26.0, *) {
            let effect = UIGlassEffect(style: clear ? .clear : .regular)
            effect.isInteractive = interactive
            return UIVisualEffectView(effect: effect)
        }
        return UIVisualEffectView(effect: UIBlurEffect(style: fallback))
    }

    static func concentricCorners(_ view: UIView, fallbackRadius: CGFloat) {
        if #available(iOS 26.0, tvOS 26.0, *) {
            view.cornerConfiguration = .corners(radius: .containerConcentric())
        } else {
            view.layer.cornerRadius = fallbackRadius
            view.layer.cornerCurve = .continuous
        }
    }

    static func prominentButton(_ fallback: () -> UIButton.Configuration) -> UIButton.Configuration {
        if #available(iOS 26.0, tvOS 26.0, *) {
            return .prominentGlass()
        }
        return fallback()
    }

    static func glassButton(_ fallback: () -> UIButton.Configuration) -> UIButton.Configuration {
        if #available(iOS 26.0, tvOS 26.0, *) {
            return .glass()
        }
        return fallback()
    }

    static func clearGlassButton(_ fallback: () -> UIButton.Configuration) -> UIButton.Configuration {
        if #available(iOS 26.0, tvOS 26.0, *) {
            return .clearGlass()
        }
        return fallback()
    }
}

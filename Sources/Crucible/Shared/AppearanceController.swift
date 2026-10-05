import UIKit

/// Applies the user's appearance preference (System, Dark, Light) to every window in the app.
@MainActor
enum AppearanceController {
    static var style: UIUserInterfaceStyle {
        switch Preferences.appearance {
        case .system: return .unspecified
        case .dark: return .dark
        case .light: return .light
        }
    }

    static func apply(to window: UIWindow) {
        window.overrideUserInterfaceStyle = style
    }

    static func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.windows.forEach { apply(to: $0) }
        }
    }
}

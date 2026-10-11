import UIKit

/// Entry point the scene delegate calls once at launch. Returns the design gallery when the process was
/// started with `CRUCIBLE_GALLERY` set, and nil otherwise, so release builds never see the gallery.
/// `CRUCIBLE_GALLERY=1` is the full gallery; `state-loading`, `state-empty` and `state-error` show one
/// state screen. `CRUCIBLE_GALLERY_STYLE=light|dark` forces the appearance (the tvOS simulator cannot
/// switch it through `simctl ui`).
@MainActor
enum TVGalleryLauncher {
    #if DEBUG
    private static func interfaceStyle() -> UIUserInterfaceStyle {
        switch ProcessInfo.processInfo.environment["CRUCIBLE_GALLERY_STYLE"] {
        case "light": .light
        case "dark": .dark
        default: .unspecified
        }
    }
    #endif

    static func rootIfRequested() -> UIViewController? {
        #if DEBUG
        guard let value = ProcessInfo.processInfo.environment["CRUCIBLE_GALLERY"], !value.isEmpty else { return nil }
        let root: UIViewController
        if value.hasPrefix("state-") {
            root = TVGalleryStateViewController(mode: value)
        } else {
            root = TVDesignGalleryViewController()
        }
        root.overrideUserInterfaceStyle = interfaceStyle()
        return root
        #else
        return nil
        #endif
    }
}

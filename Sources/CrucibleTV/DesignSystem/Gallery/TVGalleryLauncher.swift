import UIKit

/// Entry point the scene delegate calls once at launch. Returns the design gallery when the process was
/// started with `CRUCIBLE_GALLERY` set, and nil otherwise, so release builds never see the gallery.
/// `CRUCIBLE_GALLERY=1` is the full gallery; `state-loading`, `state-empty` and `state-error` show one
/// state screen; `host` is the screen-host scenarios; `title-cell`, `title-header` (the pushed-screen title), `panel` (the VoiceOver focus stop; add `CRUCIBLE_VOICEOVER=1`), `hero-short`, `hero-long`, `hero-title1` and
/// `hero-accessible` are the hero info block. `CRUCIBLE_GALLERY_STYLE=light|dark` forces the appearance (the tvOS simulator cannot
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
        if value == "host" {
            root = TVNavigation.makeNavigationController(root: TVGalleryHostRootViewController())
        } else if value == "panel" {
            root = TVGalleryPanelViewController()
        } else if value.hasPrefix("title-") {
            root = TVGalleryTitleViewController(usesHeader: value == "title-header")
        } else if value == "images" {
            root = TVGalleryImagesViewController()
        } else if value.hasPrefix("hero") {
            root = TVGalleryHeroViewController(mode: value)
        } else if value.hasPrefix("state-") {
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

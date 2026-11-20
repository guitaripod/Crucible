import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// How Crucible draws itself, kept between launches: light or dark, the layout, and the poster size (which `CardZoom`
/// keeps). The Desktop layout (the desk density) is made for a mouse and keyboard on a monitor; the Steam Deck layout (the
/// couch density) draws the Apple TV design for a gamepad, on the Deck or a TV across the room, and is the default in
/// Steam's Game Mode until the viewer picks one. `--light`, `--steam-deck` (or `--couch`) and `--desktop` on the command
/// line, and `CRUCIBLE_LAYOUT=steam-deck|desktop`, win over what is saved, for that launch only.
@MainActor
enum LinuxDisplay {
    private static let appearanceKey = "linux.appearance"
    private static let densityKey = "linux.density"
    /// Couch's canvas: the tvOS tokens one to one on the Apple TV's 1920 by 1080 points, scaled to the screen.
    static let couchCanvas = Size(width: 1920, height: 1080)
    /// Every open window, which a change of appearance or density reaches at once; the app sets it.
    static var windows: @MainActor () -> [Window] = { [] }

    /// Lays `window` out on Couch's canvas, or at the desk's own size.
    static func applyCanvas(to window: Window) {
        window.canvas = isCouch ? couchCanvas : nil
    }

    /// Puts the saved appearance, density and poster size on the theme at launch.
    static func restore(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) {
        let theme = Theme.current
        let defaults = UserDefaults.standard
        let savedLight = defaults.string(forKey: appearanceKey) == "light"
        theme.density = density(arguments: arguments, environment: environment, saved: defaults.string(forKey: densityKey))
        theme.palette = arguments.contains("--light") || savedLight ? .light : .dark
        theme.cardZoom = CardZoom.saved
        applyScrolling()
    }

    /// Desktop scrollbars in the Desktop layout, in the appearance's colour.
    static func applyScrolling() {
        ScrollView.desktopScrollbars = !isCouch
        ScrollView.indicatorColor = isLight ? Color(hex: 0x1A1816) : .white
    }

    /// The layout for this launch: a command-line flag, then `CRUCIBLE_LAYOUT`, then what the viewer picked, then Steam
    /// Deck in Steam's Game Mode and Desktop anywhere else.
    static func density(arguments: [String], environment: [String: String], saved: String?) -> Density {
        if arguments.contains("--steam-deck") || arguments.contains("--couch") { return .couch }
        if arguments.contains("--desktop") { return .desk }
        switch environment["CRUCIBLE_LAYOUT"]?.lowercased() {
        case "steam-deck", "couch": return .couch
        case "desktop", "desk": return .desk
        default: break
        }
        if let saved { return saved == "couch" ? .couch : .desk }
        return isGameMode(environment) ? .couch : .desk
    }

    /// Whether Crucible runs in Steam's Game Mode: under gamescope with Steam's gamepad interface. Neither alone says it,
    /// since gamescope also runs on a desktop and Steam sets `SteamDeck` and `SteamGamepadUI` for apps started from the
    /// Deck's desktop or from Big Picture.
    static func isGameMode(_ environment: [String: String]) -> Bool {
        let gamescope = environment["XDG_CURRENT_DESKTOP"]?.lowercased().contains("gamescope") == true || environment["GAMESCOPE_WAYLAND_DISPLAY"] != nil
        let steamInterface = environment["SteamGamepadUI"] == "1" || environment["SteamDeck"] == "1"
        return gamescope && steamInterface
    }

    static var isLight: Bool { Theme.current.palette.appearance == .light }
    static var isCouch: Bool { Theme.current.density == .couch }

    static var appearanceLabel: String { isLight ? String(localized: "Light") : String(localized: "Dark") }
    static var densityLabel: String {
        isCouch ? String(localized: "Steam Deck", comment: "Linux layout made for a gamepad, on a Steam Deck or a TV")
                : String(localized: "Desktop", comment: "Linux layout made for a mouse and keyboard on a monitor")
    }

    static var layoutTitle: String { String(localized: "Layout", comment: "Linux setting: the Desktop or Steam Deck layout") }

    static var layoutExplanation: String {
        String(localized: "Desktop is made for a mouse and keyboard on a monitor. Steam Deck is made for a gamepad, on the Deck or a TV across the room.",
               comment: "Linux setting: what the two layouts are for")
    }
    static var posterSizeLabel: String { "\(Int((Theme.current.cardZoom * 100).rounded()))%" }

    /// Takes a window out of full screen for Escape, as desktop players and browsers do, when the Desktop layout put it
    /// there by choice; Steam Deck keeps its full screen, where Escape is Back. False when there was nothing to leave, including a window
    /// that already asked and is still full screen, so a compositor that keeps it there does not swallow every Escape.
    static func leaveFullscreen(_ window: Window?) -> Bool {
        guard let window, window.isFullscreen, !window.isLeavingFullscreen, !isCouch else { return false }
        window.setFullscreen(false)
        return true
    }

    /// "Dark · Desktop · 100%", the Appearance category's value line.
    static var summary: String { [appearanceLabel, densityLabel, posterSizeLabel].joined(separator: " · ") }

    /// Switches between light and dark everywhere at once, and keeps the choice.
    static func toggleAppearance(in window: Window?) {
        let theme = Theme.current
        theme.palette = isLight ? .dark : .light
        UserDefaults.standard.set(isLight ? "light" : "dark", forKey: appearanceKey)
        applyScrolling()
        for each in everyWindow(window) {
            each.background = theme.palette.canvas
            each.relayoutEverything()
        }
    }

    /// Switches between the Desktop and Steam Deck layouts everywhere at once, and keeps the choice.
    static func toggleDensity(in window: Window?) {
        let theme = Theme.current
        theme.density = isCouch ? .desk : .couch
        UserDefaults.standard.set(isCouch ? "couch" : "desk", forKey: densityKey)
        applyScrolling()
        for each in everyWindow(window) {
            applyCanvas(to: each)
            each.relayoutEverything()
        }
    }

    /// The open windows, with `window` among them even before the app has listed it.
    private static func everyWindow(_ window: Window?) -> [Window] {
        var all = windows()
        if let window, !all.contains(where: { $0 === window }) { all.append(window) }
        return all
    }
}

/// The Steam Deck layout, offered once (docs/LINUX.md §5.5): the first time a gamepad is used while Crucible fills a
/// screen of 40 inches or more in the Desktop layout, it asks whether to draw itself for a gamepad and a TV across the room. `CRUCIBLE_SCREEN_INCHES` stands in
/// for the screen's own size in headless checks.
@MainActor
enum CouchOffer {
    private static let offeredKey = "linux.couchOffered"
    private static let smallestTV: Float = 40

    static func consider(in window: Window?) {
        guard let window, !LinuxDisplay.isCouch, window.isFullscreen, !UserDefaults.standard.bool(forKey: offeredKey) else { return }
        let inches = ProcessInfo.processInfo.environment["CRUCIBLE_SCREEN_INCHES"].flatMap(Float.init) ?? window.screenDiagonalInches
        guard let inches, inches >= smallestTV else { return }
        UserDefaults.standard.set(true, forKey: offeredKey)
        AlertView(title: String(localized: "Switch to the Steam Deck Layout?", comment: "Linux: offered once when a gamepad is used full screen on a TV"),
                  message: String(localized: "The Steam Deck layout is made for a gamepad, on the Deck or a TV across the room. Settings › Appearance changes it back.",
                                  comment: "Linux: the Steam Deck layout offer's message"),
                  actions: [
                      AlertView.Action(String(localized: "Use Steam Deck Layout", comment: "Linux: takes the Steam Deck layout offer")) {
                          LinuxDisplay.toggleDensity(in: window)
                      },
                      AlertView.Action(String(localized: "Not Now"), role: .cancel),
                  ]).present(in: window)
    }
}

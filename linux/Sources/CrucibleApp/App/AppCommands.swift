import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// The names of keys in a shortcut as the desktop writes them, in the interface language ("Strg+F" in German).
enum KeyName {
    static let ctrl = String(localized: "Ctrl", comment: "Name of the Control key in a keyboard shortcut, as in Ctrl+F")
    static let alt = String(localized: "Alt", comment: "Name of the Alt key in a keyboard shortcut, as in Alt+Left")
    static let space = String(localized: "Space", comment: "Name of the space bar in a keyboard shortcut")
    static let esc = String(localized: "Esc", comment: "Name of the Escape key in a keyboard shortcut")
    static let pageUp = String(localized: "Page Up", comment: "Name of the Page Up key in a keyboard shortcut")
    static let pageDown = String(localized: "Page Down", comment: "Name of the Page Down key in a keyboard shortcut")
    static let left = "←"
    static let right = "→"
    static let up = "↑"
    static let down = "↓"

    static func chord(_ keys: String...) -> String {
        keys.joined(separator: "+")
    }
}

/// One thing the app's menu and the shortcut list offer: its name, its keys, and what it does from the menu (nil for
/// keys that only make sense where they are pressed).
struct AppCommand {
    let title: String
    let keys: [String]
    let run: (@MainActor () -> Void)?

    init(_ title: String, keys: [String] = [], run: (@MainActor () -> Void)? = nil) {
        self.title = title
        self.keys = keys
        self.run = run
    }
}

/// A menu of the app's menu (F10 and the tab bar's menu button): Go, View, Media and Settings (docs/LINUX.md §6).
struct AppCommandGroup {
    let title: String
    let commands: [AppCommand]
    /// Whether the menu lists it now; the shortcut list always does.
    let inMenu: Bool

    var shortcuts: ShortcutsPanel.Group {
        ShortcutsPanel.Group(title, shortcuts: commands.filter { !$0.keys.isEmpty }.map { ShortcutsPanel.Shortcut($0.title, keys: $0.keys) })
    }
}

/// The words of the menu and the shortcut list.
enum AppCommandCopy {
    static let menu = String(localized: "Menu", comment: "Name of the button at the end of the Linux tab bar that opens the app's menu")
    static let view = String(localized: "View", comment: "Linux app menu: the menu of how things are shown (poster size, full screen)")
    static let forward = String(localized: "Forward", comment: "Linux app menu: go forward to the screen just left with Back")
    static let fullScreen = String(localized: "Full Screen", comment: "Linux app menu: show the window full screen, or leave full screen")
    static let shortcuts = String(localized: "Keyboard Shortcuts", comment: "Linux app menu item and title of the list of every keyboard shortcut")
    static let playOrPause = String(localized: "Play or Pause", comment: "Linux shortcut list: the key that plays or pauses the player")
    static let mute = String(localized: "Mute", comment: "Linux shortcut list: the key that mutes or unmutes the player")
    static let volumeUp = String(localized: "Volume Up", comment: "Linux shortcut list: the key that turns the player louder")
    static let volumeDown = String(localized: "Volume Down", comment: "Linux shortcut list: the key that turns the player quieter")
    static let quit = String(localized: "Quit Crucible", comment: "Linux app menu: close the app")
}

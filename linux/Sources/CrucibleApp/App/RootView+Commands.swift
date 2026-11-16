import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// The app's menu and its shortcut list (docs/LINUX.md §6, from the iPad's `AppCommand` and `AppMenu` with Ctrl for
/// Command): F10 or the tab bar's menu button opens Go, View, Media while something plays, and Settings, each item with
/// its keys; Ctrl+? shows every shortcut at once.
extension RootView {
    var commandGroups: [AppCommandGroup] {
        [goCommands, viewCommands, mediaCommands, textCommands, settingsCommands]
    }

    /// The keys for selected text and fields, in the shortcut list only: they work where the text is.
    private var textCommands: AppCommandGroup {
        AppCommandGroup(title: String(localized: "Text"), commands: [
            AppCommand(String(localized: "Copy"), keys: [KeyName.chord(KeyName.ctrl, "C")]),
            AppCommand(String(localized: "Cut"), keys: [KeyName.chord(KeyName.ctrl, "X")]),
            AppCommand(String(localized: "Paste"), keys: [KeyName.chord(KeyName.ctrl, "V")]),
            AppCommand(String(localized: "Select All"), keys: [KeyName.chord(KeyName.ctrl, "A")]),
        ], inMenu: false)
    }

    private var goCommands: AppCommandGroup {
        let tabs = tabBar.tabs.prefix(9).enumerated().map { index, tab in
            let extra = tab.id == "search" ? [KeyName.chord(KeyName.ctrl, "F"), "/"] : []
            return AppCommand(tab.title, keys: [KeyName.chord(KeyName.ctrl, "\(index + 1)")] + extra) { [weak self] in self?.select(tab.id) }
        }
        return AppCommandGroup(title: String(localized: "Go"), commands: tabs + [
            AppCommand(String(localized: "Back"), keys: [KeyName.chord(KeyName.alt, KeyName.left), KeyName.esc]) { [weak self] in _ = self?.handleBack() },
            AppCommand(AppCommandCopy.forward, keys: [KeyName.chord(KeyName.alt, KeyName.right)]) { [weak self] in _ = self?.handleForward() },
        ], inMenu: true)
    }

    private var viewCommands: AppCommandGroup {
        AppCommandGroup(title: AppCommandCopy.view, commands: [
            AppCommand(String(localized: "Refresh"), keys: [KeyName.chord(KeyName.ctrl, "R")]) { [weak self] in (self?.current?.top as? Reloadable)?.reload() },
            AppCommand(String(localized: "Larger Posters"), keys: [KeyName.chord(KeyName.ctrl, "+")]) { [weak self] in self?.zoomCards(.larger) },
            AppCommand(String(localized: "Smaller Posters"), keys: [KeyName.chord(KeyName.ctrl, "-")]) { [weak self] in self?.zoomCards(.smaller) },
            AppCommand(AppCommandCopy.fullScreen, keys: ["F11"]) { [weak self] in
                guard let window = self?.window else { return }
                window.setFullscreen(!window.isFullscreen)
            },
            AppCommand(String(localized: "Interface Size")) { [weak self] in LinuxDisplay.toggleDensity(in: self?.window) },
            AppCommand(String(localized: "Appearance")) { [weak self] in LinuxDisplay.toggleAppearance(in: self?.window) },
            AppCommand(AppCommandCopy.shortcuts, keys: [KeyName.chord(KeyName.ctrl, "?")]) { [weak self] in self?.presentShortcuts() },
            AppCommand(AppCommandCopy.newWindow, keys: [KeyName.chord(KeyName.ctrl, "N")]) { [weak self] in self?.onNewWindow?(nil) },
            AppCommand(AppCommandCopy.closeWindow, keys: [KeyName.chord(KeyName.ctrl, "W")]) { [weak self] in self?.onCloseWindow?() },
        ], inMenu: true)
    }

    /// The player's keys; from the menu each sends its key to the player, so the menu and the keyboard do the same thing.
    private var mediaCommands: AppCommandGroup {
        func send(_ key: Key) -> @MainActor () -> Void {
            { [weak self] in self?.window?.handleKey(KeyEvent(key: key)) }
        }
        return AppCommandGroup(title: String(localized: "Media"), commands: [
            AppCommand(AppCommandCopy.playOrPause, keys: [KeyName.space, "K"], run: send(.space)),
            AppCommand(String(localized: "Skip Back"), keys: [KeyName.left, "J"], run: send(.left)),
            AppCommand(String(localized: "Skip Ahead"), keys: [KeyName.right, "L"], run: send(.right)),
            AppCommand(String(localized: "Back or Ahead One Second", comment: "Shortcut list: Shift with Left or Right"),
                       keys: [KeyName.chord(KeyName.shift, KeyName.left), KeyName.chord(KeyName.shift, KeyName.right)]),
            AppCommand(String(localized: "Jump to a Tenth", comment: "Shortcut list: the digit keys jump to 0% to 90% of the title"), keys: ["0–9"]),
            AppCommand(String(localized: "Previous or Next Frame", comment: "Shortcut list: comma and period step a frame"), keys: [",", "."]),
            AppCommand(String(localized: "Go Back", comment: "Shortcut list: return to before the last long jump"),
                       keys: [KeyName.chord(KeyName.shift, KeyName.backspace)]) { [weak self] in self?.player?.goBack() },
            AppCommand(String(localized: "Skip Intro"), keys: ["S"], run: send(.character("s"))),
            AppCommand(String(localized: "Play Next Episode"), keys: ["N"], run: send(.character("n"))),
            AppCommand(String(localized: "Chapters"), keys: [KeyName.pageUp, KeyName.pageDown]),
            AppCommand(String(localized: "Info"), keys: ["I"], run: send(.character("i"))),
            AppCommand(String(localized: "Audio"), keys: ["A"], run: send(.character("a"))),
            AppCommand(String(localized: "Subtitles"), keys: ["C"], run: send(.character("c"))),
            AppCommand(String(localized: "Subtitles On or Off", comment: "Shortcut list"), keys: ["V"], run: send(.character("v"))),
            AppCommand(String(localized: "Subtitle Sync", comment: "Shortcut list: subtitles earlier or later"), keys: ["Z", "X"]),
            AppCommand(String(localized: "Sound Sync", comment: "Shortcut list: sound earlier or later"), keys: ["−", "="]),
            AppCommand(String(localized: "Sleep Timer"), keys: ["T"], run: send(.character("t"))),
            AppCommand(String(localized: "Playback Speed"), keys: ["[", "]"]),
            AppCommand(AppCommandCopy.mute, keys: ["M"], run: send(.character("m"))),
            AppCommand(AppCommandCopy.volumeUp, keys: [KeyName.up], run: send(.up)),
            AppCommand(AppCommandCopy.volumeDown, keys: [KeyName.down], run: send(.down)),
            AppCommand(AppCommandCopy.fullScreen, keys: ["F"], run: send(.character("f"))),
            AppCommand(String(localized: "Loop a Stretch", comment: "Shortcut list: A-B loop"), keys: [KeyName.chord(KeyName.shift, "L")]) { [weak self] in
                self?.player?.markLoop()
            },
            AppCommand(String(localized: "Save Picture", comment: "Player menu: screenshot to a file"), keys: [KeyName.chord(KeyName.shift, "S")]) { [weak self] in
                self?.player?.screenshot(withSubtitles: false, copy: false)
            },
            AppCommand(String(localized: "Copy Picture", comment: "Player menu: screenshot to the clipboard"), keys: [KeyName.chord(KeyName.ctrl, "C")]) {
                [weak self] in self?.player?.screenshot(withSubtitles: false, copy: true)
            },
            AppCommand(String(localized: "Player Menu", comment: "Shortcut list: the player's right-click menu"),
                       keys: [String(localized: "Right Click", comment: "Shortcut list: the secondary mouse button")]) { [weak self] in
                self?.player?.presentContextMenu(at: nil)
            },
            AppCommand(String(localized: "Close Player"), keys: [KeyName.esc]) { [weak self] in self?.player?.close() },
        ], inMenu: player != nil)
    }

    private var settingsCommands: AppCommandGroup {
        AppCommandGroup(title: String(localized: "Settings"), commands: [
            AppCommand(String(localized: "Settings…"), keys: [KeyName.chord(KeyName.ctrl, ",")]) { [weak self] in self?.openSettings() },
            AppCommand(OwnModelCopy.title) { [weak self] in
                self?.openSettings()
                self?.current?.push(OwnModelSettingsScreen())
            },
            AppCommand(AppCommandCopy.quit, keys: [KeyName.chord(KeyName.ctrl, "Q")]) { [weak self] in self?.onQuit?() },
        ], inMenu: true)
    }

    /// Opens the menu at `anchor` (the menu button, or under it for F10): its menus first, then the chosen menu's items.
    func presentCommandMenu(anchor: Rect? = nil) {
        guard let window else { return }
        let groups = commandGroups.filter(\.inMenu)
        let place = anchor ?? tabBar.menuAnchor ?? Rect(x: bounds.midX, y: Theme.current.metrics.tabBarTop, width: 1, height: 1)
        let menu = MenuView(title: AppCommandCopy.menu, items: groups.enumerated().map { index, group in
            MenuView.Item(id: "\(index)", title: group.title, symbol: "chevron.right")
        }, anchor: place)
        menu.onSelect = { [weak self] chosen in
            guard let self, let index = Int(chosen.id), groups.indices.contains(index) else { return }
            self.presentCommands(groups[index], anchor: place)
        }
        menu.present(in: window)
    }

    private func presentCommands(_ group: AppCommandGroup, anchor: Rect) {
        guard let window else { return }
        let commands = group.commands.filter { $0.run != nil }
        let menu = MenuView(title: group.title, items: commands.enumerated().map { index, command in
            MenuView.Item(id: "\(index)", title: command.title, shortcut: command.keys.isEmpty ? nil : command.keys.joined(separator: "  "))
        }, anchor: anchor)
        menu.onSelect = { chosen in
            guard let index = Int(chosen.id), commands.indices.contains(index) else { return }
            commands[index].run?()
        }
        menu.present(in: window)
    }

    /// Every shortcut at once (Ctrl+?), the player's among them.
    func presentShortcuts() {
        guard let window else { return }
        ShortcutsPanel(title: AppCommandCopy.shortcuts, groups: commandGroups.map(\.shortcuts)).present(in: window)
    }
}

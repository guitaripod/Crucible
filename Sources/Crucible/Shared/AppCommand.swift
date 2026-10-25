@preconcurrency import UIKit

/// Everything the keyboard and the iPad menu bar can do. Each command reaches the window's `TabBarController` through the responder
/// chain; the ones that act on what is on screen are passed on to that screen through `CommandHandling`.
enum AppCommand: String, CaseIterable {
    case home, library, downloads, you, search
    case back
    case statistics, history, surpriseMe
    case refresh, largerPosters, smallerPosters
    case play, skip, playNext, closePlayer, toggleWatched, download
    case settings, switchServer
    case newWindow

    var title: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .downloads: return "Downloads"
        case .you: return "You"
        case .search: return "Search"
        case .back: return "Back"
        case .statistics: return "Statistics"
        case .history: return "Watch History"
        case .surpriseMe: return "Surprise Me"
        case .refresh: return "Refresh"
        case .largerPosters: return "Larger Posters"
        case .smallerPosters: return "Smaller Posters"
        case .play: return "Play"
        case .skip: return "Skip Intro"
        case .playNext: return "Play Next Episode"
        case .closePlayer: return "Close Player"
        case .toggleWatched: return "Mark as Watched"
        case .download: return "Download"
        case .settings: return "Settings…"
        case .switchServer: return "Switch Server…"
        case .newWindow: return "New Window"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .library: return "rectangle.stack"
        case .downloads: return "arrow.down.circle"
        case .you: return "person.crop.circle"
        case .search: return "magnifyingglass"
        case .back: return "chevron.backward"
        case .statistics: return "chart.bar"
        case .history: return "clock.arrow.circlepath"
        case .surpriseMe: return "shuffle"
        case .refresh: return "arrow.clockwise"
        case .largerPosters: return "plus.magnifyingglass"
        case .smallerPosters: return "minus.magnifyingglass"
        case .play: return "play.fill"
        case .skip: return "forward.end"
        case .playNext: return "forward.frame"
        case .closePlayer: return "xmark"
        case .toggleWatched: return "checkmark.circle"
        case .download: return "arrow.down.circle"
        case .settings: return "gearshape"
        case .switchServer: return "server.rack"
        case .newWindow: return "macwindow.badge.plus"
        }
    }

    /// The key that runs the command; nil for commands that live in the menu bar only.
    private var shortcut: (input: String, modifiers: UIKeyModifierFlags)? {
        switch self {
        case .home: return ("1", .command)
        case .library: return ("2", .command)
        case .downloads: return ("3", .command)
        case .you: return ("4", .command)
        case .search: return ("f", .command)
        case .back: return ("[", .command)
        case .statistics: return ("s", [.command, .shift])
        case .history: return ("y", .command)
        case .surpriseMe: return ("s", [.command, .alternate])
        case .refresh: return ("r", .command)
        case .largerPosters: return ("+", .command)
        case .smallerPosters: return ("-", .command)
        case .play: return (" ", [])
        case .skip: return ("s", [])
        case .playNext: return ("n", [])
        case .closePlayer: return (UIKeyCommand.inputEscape, [])
        case .settings: return (",", .command)
        case .newWindow: return ("n", .command)
        case .toggleWatched, .download, .switchServer: return nil
        }
    }

    /// Poster size may step while the key is held; everything else fires once per press.
    private var repeats: Bool {
        self == .largerPosters || self == .smallerPosters
    }

    @MainActor
    func menuElement() -> UICommand {
        let action = #selector(TabBarController.performCommand(_:))
        guard let shortcut else {
            return UICommand(title: title, image: UIImage(systemName: symbol), action: action, propertyList: rawValue)
        }
        let command = UIKeyCommand(
            title: title,
            image: UIImage(systemName: symbol),
            action: action,
            input: shortcut.input,
            modifierFlags: shortcut.modifiers,
            propertyList: rawValue
        )
        command.discoverabilityTitle = title
        if !repeats { command.repeatBehavior = .nonRepeatable }
        return command
    }

    init?(sender: Any?) {
        guard let command = sender as? UICommand, let raw = command.propertyList as? String else { return nil }
        self.init(rawValue: raw)
    }
}

/// A screen that acts on the commands about what it shows (play, refresh, mark as watched, poster size).
@MainActor
protocol CommandHandling: AnyObject {
    func canPerform(_ command: AppCommand) -> Bool
    func perform(_ command: AppCommand)
    /// The menu title for `command` right now, when it should read differently from the default ("Resume", "Mark as Unwatched").
    func title(for command: AppCommand) -> String?
}

extension CommandHandling {
    func title(for command: AppCommand) -> String? { nil }
}

/// The menus Crucible adds to the iPad menu bar and to the keyboard shortcut overlay (hold Command).
@MainActor
enum AppMenu {
    static func build(_ builder: any UIMenuBuilder) {
        let account = [AppCommand.settings, .switchServer].map { $0.menuElement() }
        if builder.menu(for: .preferences) != nil {
            builder.replaceChildren(ofMenu: .preferences) { _ in [account[0]] }
            builder.insertSibling(UIMenu(options: .displayInline, children: [account[1]]), afterMenu: .preferences)
        } else {
            builder.insertChild(UIMenu(options: .displayInline, children: account), atEndOfMenu: .application)
        }
        let anchor: UIMenu.Identifier = builder.menu(for: .view) != nil ? .view : .edit
        if anchor == .view {
            builder.insertChild(UIMenu(options: .displayInline, children: [AppCommand.refresh.menuElement()]), atStartOfMenu: .view)
            builder.insertChild(
                UIMenu(options: .displayInline, children: [AppCommand.largerPosters, .smallerPosters].map { $0.menuElement() }),
                atEndOfMenu: .view
            )
            builder.insertSibling(go(), afterMenu: .view)
        } else {
            builder.insertSibling(go(including: [.refresh, .largerPosters, .smallerPosters]), afterMenu: anchor)
        }
        builder.insertSibling(media, afterMenu: goIdentifier)
    }

    /// The command overlay on iPadOS before the menu bar has no New Window of its own.
    static func buildLegacy(_ builder: any UIMenuBuilder) {
        build(builder)
        builder.insertChild(
            UIMenu(options: .displayInline, children: [AppCommand.newWindow.menuElement()]),
            atStartOfMenu: .file
        )
    }

    private static let goIdentifier = UIMenu.Identifier("com.guitaripod.crucible.menu.go")
    private static let mediaIdentifier = UIMenu.Identifier("com.guitaripod.crucible.menu.media")

    private static func go(including extras: [AppCommand] = []) -> UIMenu {
        var sections = [
            UIMenu(options: .displayInline, children: [AppCommand.home, .library, .downloads, .you, .search].map { $0.menuElement() }),
            UIMenu(options: .displayInline, children: [AppCommand.back.menuElement()]),
            UIMenu(options: .displayInline, children: [AppCommand.statistics, .history, .surpriseMe].map { $0.menuElement() }),
        ]
        if !extras.isEmpty {
            sections.append(UIMenu(options: .displayInline, children: extras.map { $0.menuElement() }))
        }
        return UIMenu(title: "Go", identifier: goIdentifier, children: sections)
    }

    private static var media: UIMenu {
        UIMenu(title: "Media", identifier: mediaIdentifier, children: [
            UIMenu(options: .displayInline, children: [AppCommand.play, .skip, .playNext, .closePlayer].map { $0.menuElement() }),
            UIMenu(options: .displayInline, children: [AppCommand.toggleWatched, .download].map { $0.menuElement() }),
        ])
    }
}

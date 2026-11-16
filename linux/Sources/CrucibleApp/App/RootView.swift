import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// The main UI: one navigation stack per destination, reached in the Steam Deck layout from the floating glass tab bar as
/// on the Apple TV, and in the Desktop layout from a sidebar down the window's leading edge with Back and Forward at its
/// head, every library listed (no More), and Settings and the app's menu at its foot (Ctrl+B narrows it to a rail of
/// symbols, as does a narrow window). Escape pops the current stack and, at its root, moves focus to the tab bar or the
/// sidebar; Ctrl with a number picks a destination in the order they show.
@MainActor
final class RootView: View, WindowRestoration.Restorable {
    let payload: LaunchPayload
    var onSignOut: (() -> Void)?
    /// Leaves the demo (You's Leave the Demo, the tour).
    var onLeaveDemo: (() -> Void)?
    var onSwitchServer: (() -> Void)?
    /// Connects again from the saved server (after Add Server by Address).
    var onReconnect: (() -> Void)?
    /// Quit Crucible from the app's menu.
    var onQuit: (() -> Void)?
    /// Opens a new window (Ctrl+N), on a title's link when one is given (Open in New Window, a middle click).
    var onNewWindow: ((URL?) -> Void)?
    /// Closes this window (Ctrl+W).
    var onCloseWindow: (() -> Void)?

    let tabBar = TabBarView()
    let sidebar = SidebarView()
    private var stacks: [String: NavigationView] = [:]
    private(set) var current: NavigationView?
    private var currentID = "home"
    private let libraryLayout: LibraryTabLayout

    init(payload: LaunchPayload) {
        self.payload = payload
        libraryLayout = LibraryTabLayout(directories: payload.sections.Directory ?? [])
        super.init()
        var tabs: [TabBarView.Tab] = [.init(id: "home", title: String(localized: "Home"), symbol: "house")]
        for directory in libraryLayout.tabs {
            guard let key = directory.key, let title = directory.title else { continue }
            tabs.append(.init(id: "library-\(key)", title: title, symbol: directory.type == "show" ? "tv" : "film"))
        }
        if libraryLayout.hasMore {
            tabs.append(.init(id: "more", title: String(localized: "More", comment: "Tab bar title"), symbol: "ellipsis"))
        }
        tabs.append(.init(id: "search", title: String(localized: "Search"), symbol: "magnifyingglass"))
        tabs.append(.init(id: "you", title: String(localized: "You"), symbol: "person.crop.circle"))
        tabBar.tabs = tabs
        tabBar.onSelect = { [weak self] tab in self?.select(tab.id) }
        tabBar.menuTitle = AppCommandCopy.menu
        tabBar.onMenu = { [weak self] anchor in self?.presentCommandMenu(anchor: anchor) }
        addSubview(tabBar)
        installSidebar()
        select("home")
    }

    /// Whether the Desktop layout's sidebar stands in for the tab bar.
    var usesSidebar: Bool { Theme.current.density == .desk }

    /// Every library, the tab bar's and More's, each its own destination in the sidebar.
    private var allLibraries: [PlexDirectory] { libraryLayout.tabs + libraryLayout.overflow }

    /// The destinations in the order the layout shows them, which Ctrl with a number and the shoulder buttons follow:
    /// the tab bar's, or the sidebar's (Home, Search, the libraries, You).
    var destinations: [TabBarView.Tab] {
        guard usesSidebar else { return tabBar.tabs }
        return sidebar.sections.flatMap(\.items).map { TabBarView.Tab(id: $0.id, title: $0.title, symbol: $0.symbol) }
    }

    private func installSidebar() {
        var libraries: [SidebarView.Item] = []
        for directory in allLibraries {
            guard let key = directory.key, let title = directory.title else { continue }
            libraries.append(.init(id: "library-\(key)", title: title, symbol: directory.type == "show" ? "tv" : "film"))
        }
        let top: [SidebarView.Item] = [
            .init(id: "home", title: String(localized: "Home"), symbol: "house"),
            .init(id: "search", title: String(localized: "Search"), symbol: "magnifyingglass"),
        ]
        var sections = [SidebarView.Section(items: top)]
        if !libraries.isEmpty { sections.append(.init(title: String(localized: "Libraries"), items: libraries)) }
        sections.append(.init(items: [.init(id: "you", title: String(localized: "You"), symbol: "person.crop.circle")]))
        var numbered = 0
        sidebar.sections = sections.map { section in
            var section = section
            section.items = section.items.map { item in
                numbered += 1
                var item = item
                var keys = numbered <= 9 ? [KeyName.chord(KeyName.ctrl, "\(numbered)")] : []
                if item.id == "search" { keys.append(KeyName.chord(KeyName.ctrl, "F")) }
                item.shortcut = keys.isEmpty ? nil : keys.joined(separator: ", ")
                return item
            }
            return section
        }
        sidebar.footer = [
            .init(id: "settings", title: String(localized: "Settings"), symbol: "gearshape", shortcut: KeyName.chord(KeyName.ctrl, ",")),
            .init(id: "menu", title: AppCommandCopy.menu, symbol: "line.3.horizontal", shortcut: "F10"),
        ]
        sidebar.isCollapsed = UserDefaults.standard.bool(forKey: Self.sidebarCollapsedKey)
        sidebar.onSelect = { [weak self] item, rect in
            guard let self else { return }
            switch item.id {
            case "settings": self.openSettings()
            case "menu": self.presentCommandMenu(anchor: rect)
            default:
                if item.id == self.currentID, let stack = self.current, stack.screens.count > 1 { stack.popToRoot() } else { self.select(item.id) }
            }
        }
        sidebar.onBack = { [weak self] in _ = self?.handleBack() }
        sidebar.onForward = { [weak self] in _ = self?.handleForward() }
        addSubview(sidebar)
    }

    private static let sidebarCollapsedKey = "linux.sidebarCollapsed"

    /// A window this narrow keeps the sidebar a rail whatever the viewer chose.
    private var isTooNarrowForSidebar: Bool { frame.width < Theme.current.metrics.tv(1900) }

    /// Narrows the sidebar to its rail or widens it again (Ctrl+B), and keeps the choice.
    func toggleSidebar() {
        guard usesSidebar, player == nil, !isTooNarrowForSidebar else { return }
        let collapsed = !UserDefaults.standard.bool(forKey: Self.sidebarCollapsedKey)
        UserDefaults.standard.set(collapsed, forKey: Self.sidebarCollapsedKey)
        setNeedsLayout()
    }

    /// The sidebar's Back and Forward follow the current stack, and its selection the destination (Settings while a
    /// settings page is on top of You).
    private func updateSidebar() {
        guard usesSidebar else { return }
        sidebar.canGoBack = (current?.screens.count ?? 0) > 1
        sidebar.canGoForward = current?.canGoForward ?? false
        let inSettings = currentID == "you" && (current?.screens.contains { $0 is SettingsScreen } ?? false)
        sidebar.select(inSettings ? "settings" : currentID)
    }

    /// Opens the tab and title `state` kept (the window's when Crucible last ran on this server), then starts remembering
    /// what this window shows; the demo keeps nothing.
    func restoreWindow(_ state: WindowRestoration.State?) {
        defer {
            remembersWindow = true
            if !DemoMode.shared.isActive { WindowRestoration.track(self) }
        }
        guard !DemoMode.shared.isActive, let state, (tabBar.tabs + destinations).contains(where: { $0.id == state.tab }) else { return }
        select(state.tab)
        if let route = state.route { push(DetailScreen.make(api: payload.api, route: route)) }
    }

    /// Off until the last launch's window is back, so opening on Home does not overwrite it first.
    private var remembersWindow = false

    /// The tab and the title on top of it.
    var restorationState: WindowRestoration.State? {
        WindowRestoration.State(tab: currentID, route: (current?.top as? DetailScreen)?.route)
    }

    /// Remembers what every window shows for the next launch.
    private func rememberWindow() {
        guard remembersWindow, !DemoMode.shared.isActive else { return }
        WindowRestoration.saveAll()
    }

    /// The keys a window's app leaves to its main UI: F11, the frame-time HUD, Back and Forward, then the app's commands.
    /// Escape with nothing left to go back from takes the window out of full screen.
    func handleWindowKey(_ event: KeyEvent, in window: Window) -> Bool {
        if event.key == .f11 {
            window.setFullscreen(!window.isFullscreen)
            return true
        }
        if event.key == Key.character("p") && event.modifiers == [.control, .shift] {
            window.showsPerformanceHUD.toggle()
            return true
        }
        if event.key == .escape || event.key == .back || (event.key == .left && event.modifiers == .alt) {
            return handleBack() || (event.key == .escape && LinuxDisplay.leaveFullscreen(window))
        }
        if event.key == .forward || (event.key == .right && event.modifiers == .alt) { return handleForward() }
        return handleCommand(event)
    }

    override var preferredFocusView: View? { current }

    private func makeStack(for id: String) -> NavigationView {
        if let existing = stacks[id] { return existing }
        let screen: ScreenView
        if id.hasPrefix("library-"), let directory = allLibraries.first(where: { "library-\($0.key ?? "")" == id }) {
            screen = LibraryScreen(api: payload.api, directory: directory)
        } else if id == "more" {
            screen = MoreScreen(api: payload.api, libraries: libraryLayout.overflow)
        } else if id == "search" {
            screen = SearchScreen(api: payload.api)
        } else if id == "you" {
            let you = YouScreen(payload: payload)
            you.onSignOut = { [weak self] in self?.onSignOut?() }
            you.onLeaveDemo = { [weak self] in self?.onLeaveDemo?() }
            screen = you
        } else {
            screen = HomeScreen(payload: payload)
        }
        let stack = NavigationView(root: screen)
        stack.onChange = { [weak self] in self?.navigationChanged() }
        stacks[id] = stack
        return stack
    }

    /// Opens `id`'s tab: its stack keeps the screens it had, and focus goes where it was in it.
    func select(_ id: String) {
        let existed = stacks[id] != nil
        let stack = makeStack(for: id)
        tabBar.select(id, animated: true)
        guard stack !== current else { return }
        current?.top?.screenWillDisappear()
        current?.removeFromSuperview()
        currentID = id
        current = stack
        insertSubview(stack, below: tabBar)
        stack.isHidden = player != nil
        stack.frame = contentFrame
        tabBar.setHidden(false, animated: true)
        window?.focus.focus(stack, animated: false)
        if existed { stack.top?.screenDidAppear() }
        updateSidebar()
        rememberWindow()
    }

    /// The next or the previous tab (a gamepad's shoulder buttons, Ctrl with Page Down or Page Up), stopping at the ends
    /// as the tvOS tab bar does.
    private func stepTab(forward: Bool) {
        let ids = destinations.map(\.id)
        guard let index = ids.firstIndex(of: currentID) else { return }
        let next = index + (forward ? 1 : -1)
        guard ids.indices.contains(next) else { return }
        select(ids[next])
        tabBar.setHidden(false, animated: true)
    }

    /// Opens the first library's tab, or More when every library is there (the demo tour's Browse a library).
    func selectFirstLibrary() {
        guard let tab = destinations.first(where: { $0.id.hasPrefix("library-") || $0.id == "more" }) else { return }
        select(tab.id)
    }

    private func navigationChanged() {
        tabBar.setHidden(false, animated: true)
        updateSidebar()
        rememberWindow()
    }

    /// Escape: back out of a pushed screen, or from a root screen up to the tab bar.
    func handleBack() -> Bool {
        if let player {
            player.close()
            return true
        }
        guard let current else { return false }
        if let top = current.top, top.handleBack() { return true }
        if current.pop() { return true }
        let bar: View = usesSidebar ? sidebar : tabBar
        if window?.focusedView?.isDescendant(of: bar) == false {
            tabBar.setHidden(false, animated: true)
            window?.focus.focus(bar, animated: true)
            return true
        }
        return false
    }

    /// Forward: the screen Back last popped on this tab comes back.
    func handleForward() -> Bool {
        guard player == nil else { return false }
        return current?.goForward() ?? false
    }

    /// Ctrl with the wheel or a touchpad makes the cards bigger or smaller, as Ctrl with plus and minus does; the player
    /// keeps the scroll for itself.
    func zoomScrolled(_ event: ScrollEvent) -> Bool {
        guard player == nil else { return false }
        if let step = CardZoom.step(for: event) { zoomCards(step) }
        return true
    }

    func zoomCards(_ step: CardZoom.Step) {
        CardZoom.apply(step)
        window?.relayoutEverything()
    }

    /// Opens Settings on the You tab (Ctrl+comma).
    func openSettings() {
        select("you")
        guard let stack = stacks["you"], !(stack.top is SettingsScreen) else { return }
        stack.popToRoot()
        stack.push(SettingsScreen(api: payload.api))
    }

    /// The tvOS app's commands with Ctrl for Command: Ctrl+1 to Ctrl+9 pick tabs, F10 opens the app's menu and Ctrl+? lists
    /// every shortcut.
    func handleCommand(_ event: KeyEvent) -> Bool {
        if event.key == .f10 && event.modifiers.isEmpty {
            presentCommandMenu()
            return true
        }
        if event.modifiers.contains(.control), event.key == Key.character("?") || (event.key == Key.character("/") && event.modifiers.contains(.shift)) {
            presentShortcuts()
            return true
        }
        if (event.key == Key.character("f") && event.modifiers == .control) || (event.key == Key.character("/") && event.modifiers.isEmpty) {
            select("search")
            return true
        }
        if let typed = event.typedText, player == nil, !typed.trimmingCharacters(in: .whitespaces).isEmpty {
            select("search")
            (stacks["search"]?.top as? SearchScreen)?.begin(with: typed)
            return true
        }
        if player == nil, event.modifiers.isSubset(of: [.control, .shift]), event.modifiers.contains(.control), let step = CardZoom.step(for: event.key) {
            zoomCards(step)
            return true
        }
        if event.key == Key.character(",") && event.modifiers == .control, player == nil {
            openSettings()
            return true
        }
        if event.key == Key.character("r") && event.modifiers == .control, player == nil {
            (current?.top as? Reloadable)?.reload()
            return true
        }
        if event.key == .tabPrevious || event.key == .tabNext || (event.modifiers == .control && (event.key == .pageUp || event.key == .pageDown)) {
            guard player == nil else { return false }
            stepTab(forward: event.key == .tabNext || event.key == .pageDown)
            return true
        }
        if event.key == Key.character("n") && event.modifiers == .control {
            onNewWindow?(nil)
            return true
        }
        if event.key == Key.character("w") && event.modifiers == .control {
            onCloseWindow?()
            return true
        }
        if event.key == Key.character("b") && event.modifiers == .control, usesSidebar, player == nil {
            toggleSidebar()
            return true
        }
        let digit = Int(event.key.rawValue) - 0x30
        let ordered = destinations
        if event.modifiers == .control, digit >= 1, digit <= min(9, ordered.count) {
            select(ordered[digit - 1].id)
            return true
        }
        return false
    }

    private(set) var player: PlayerScreen?

    /// Plays `item` over everything, from where the viewer left it, in the audio and subtitles a title page chose;
    /// focus returns where it was when the player closes.
    func play(item: PlexMetadata, api: APIClient, from position: Double? = nil, tracks: (audio: Int?, subtitle: Int?)? = nil,
              run: PlayerRun = PlayerRun()) {
        guard player == nil else { return }
        let returnFocus = window?.focusedView
        let screen = PlayerScreen(source: .plex(api, item, resume: position ?? item.resumeSecs))
        screen.chosenTracks = tracks
        screen.run = run
        screen.onClose = { [weak self, weak screen] in
            self?.showUnderPlayer(true)
            if let returnFocus, returnFocus.window != nil {
                self?.window?.focus.focus(returnFocus, animated: false)
            } else {
                self?.window?.focus.focus(self?.current, animated: false)
            }
            screen?.removeFromSuperview()
            self?.player = nil
            self?.current?.top?.screenDidAppear()
        }
        screen.onPlayNext = { [weak self, weak screen] episode, run in
            screen?.removeFromSuperview()
            self?.player = nil
            self?.play(item: episode, api: api, from: 0, run: run)
        }
        screen.onPlayTitle = { [weak self, weak screen] title, run in
            screen?.removeFromSuperview()
            self?.player = nil
            self?.play(item: title, api: api, run: run)
        }
        screen.onOpenTitle = { [weak self] title in
            self?.push(DetailScreen.make(api: api, item: title))
        }
        player = screen
        addSubview(screen)
        screen.frame = bounds
        window?.focus.focus(screen, animated: false)
        showUnderPlayer(false)
    }

    /// Hides the tab and the tab bar while the opaque player covers them, so every video frame draws only the player, and
    /// shows them again (their animations carry on) when it closes.
    private func showUnderPlayer(_ shown: Bool) {
        current?.isHidden = !shown
        tabBar.isHidden = !shown || usesSidebar
        sidebar.isHidden = !shown || !usesSidebar
    }

    /// Shows `item`'s page from anywhere: the player closes, Home's stack unwinds to its root and the page goes on top.
    func showDetail(_ item: PlexMetadata) {
        closePlayer()
        select("home")
        stacks["home"]?.popToRoot()
        push(DetailScreen.make(api: payload.api, item: item))
    }

    /// Whether nothing covers the tabs: no player, alert, menu, sheet or launch gate on its way out.
    var isUnobstructed: Bool {
        player == nil && subviews.allSatisfy { $0 === tabBar || $0 === sidebar || $0 === current }
    }

    /// Ends playback if a player is up; the server hears where it stopped.
    func closePlayer() {
        player?.close()
    }

    /// Pushes a screen on the current tab's stack.
    func push(_ screen: ScreenView) {
        current?.push(screen)
    }

    /// The tab bar slides away while a screen's content scrolls down, and comes back at the top or when focus reaches it.
    /// The tab bar slides away while content scrolls down, except on Search, where it stays.
    func contentScrolled(offset: Float) {
        guard !usesSidebar else { return }
        tabBar.setHidden(currentID != "search" && offset > Theme.current.metrics.tv(40), animated: true)
    }

    /// Where the current destination's screens go: beside the sidebar, or the whole window under the floating tab bar.
    private var contentFrame: Rect {
        guard usesSidebar else { return bounds }
        let width = sidebar.width
        return Rect(x: width, y: 0, width: max(frame.width - width, 0), height: frame.height)
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        sidebar.isCollapsed = UserDefaults.standard.bool(forKey: Self.sidebarCollapsedKey) || isTooNarrowForSidebar
        tabBar.isHidden = usesSidebar || player != nil
        sidebar.isHidden = !usesSidebar || player != nil
        sidebar.frame = Rect(x: 0, y: 0, width: sidebar.width, height: frame.height)
        current?.frame = contentFrame
        player?.frame = bounds
        tabBar.frame = Rect(x: 0, y: 0, width: frame.width, height: metrics.tabBarTop + metrics.tabBarHeight + metrics.tv(20))
        updateSidebar()
    }
}

/// A screen Ctrl+R refreshes.
@MainActor
protocol Reloadable: AnyObject {
    func reload()
}

extension View {
    /// The root view of the main UI this view is in.
    @MainActor var rootView: RootView? {
        var view: View? = self
        while let current = view {
            if let root = current as? RootView { return root }
            view = current.superview
        }
        return nil
    }
}

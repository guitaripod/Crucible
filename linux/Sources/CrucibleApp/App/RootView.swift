import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// The main UI: the floating glass tab bar over one navigation stack per tab, as on the Apple TV. Escape pops the current
/// stack and, at its root, moves focus up to the tab bar; Ctrl with a number picks a tab.
@MainActor
final class RootView: View {
    let payload: LaunchPayload
    var onSignOut: (() -> Void)?
    /// Leaves the demo (You's Leave the Demo, the tour).
    var onLeaveDemo: (() -> Void)?
    var onSwitchServer: (() -> Void)?
    /// Connects again from the saved server (after Add Server by Address).
    var onReconnect: (() -> Void)?
    /// Quit Crucible from the app's menu.
    var onQuit: (() -> Void)?

    let tabBar = TabBarView()
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
        select("home")
    }

    /// Opens the tab and title the window showed when Crucible last ran on this server.
    func restoreWindow() {
        defer { remembersWindow = true }
        guard !DemoMode.shared.isActive, let state = WindowRestoration.restore(), tabBar.tabs.contains(where: { $0.id == state.tab }) else { return }
        select(state.tab)
        if let route = state.route { push(DetailScreen.make(api: payload.api, route: route)) }
    }

    /// Off until the last launch's window is back, so opening on Home does not overwrite it first.
    private var remembersWindow = false

    /// Remembers the tab and the title on top of it for the next launch.
    private func rememberWindow() {
        guard remembersWindow, !DemoMode.shared.isActive else { return }
        WindowRestoration.save(.init(tab: currentID, route: (current?.top as? DetailScreen)?.route))
    }

    override var preferredFocusView: View? { current }

    private func makeStack(for id: String) -> NavigationView {
        if let existing = stacks[id] { return existing }
        let screen: ScreenView
        if id.hasPrefix("library-"), let directory = libraryLayout.tabs.first(where: { "library-\($0.key ?? "")" == id }) {
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
        stack.frame = bounds
        tabBar.setHidden(false, animated: true)
        window?.focus.focus(stack, animated: false)
        if existed { stack.top?.screenDidAppear() }
        rememberWindow()
    }

    /// Opens the first library's tab, or More when every library is there (the demo tour's Browse a library).
    func selectFirstLibrary() {
        guard let tab = tabBar.tabs.first(where: { $0.id.hasPrefix("library-") || $0.id == "more" }) else { return }
        select(tab.id)
    }

    private func navigationChanged() {
        tabBar.setHidden(false, animated: true)
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
        if window?.focusedView?.isDescendant(of: tabBar) == false {
            tabBar.setHidden(false, animated: true)
            window?.focus.focus(tabBar, animated: true)
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
        let digit = Int(event.key.rawValue) - 0x30
        if event.modifiers == .control, digit >= 1, digit <= min(9, tabBar.tabs.count) {
            select(tabBar.tabs[digit - 1].id)
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
            if let returnFocus, returnFocus.window != nil { self?.window?.focus.focus(returnFocus, animated: false) }
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
        player == nil && subviews.allSatisfy { $0 === tabBar || $0 === current }
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
        tabBar.setHidden(currentID != "search" && offset > Theme.current.metrics.tv(40), animated: true)
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        current?.frame = bounds
        player?.frame = bounds
        tabBar.frame = Rect(x: 0, y: 0, width: frame.width, height: metrics.tabBarTop + metrics.tabBarHeight + metrics.tv(20))
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

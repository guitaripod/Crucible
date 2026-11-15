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
    var onSwitchServer: (() -> Void)?

    private let tabBar = TabBarView()
    private var stacks: [String: NavigationView] = [:]
    private var current: NavigationView?
    private var currentID = "home"
    private let libraryLayout: LibraryTabLayout

    init(payload: LaunchPayload) {
        self.payload = payload
        libraryLayout = LibraryTabLayout(directories: payload.sections.Directory ?? [])
        super.init()
        var tabs: [TabBarView.Tab] = [.init(id: "home", title: String(localized: "Home"))]
        for directory in libraryLayout.tabs {
            guard let key = directory.key, let title = directory.title else { continue }
            tabs.append(.init(id: "library-\(key)", title: title))
        }
        tabBar.tabs = tabs
        tabBar.onSelect = { [weak self] tab in self?.select(tab.id) }
        addSubview(tabBar)
        select("home")
    }

    override var preferredFocusView: View? { current }

    private func makeStack(for id: String) -> NavigationView {
        if let existing = stacks[id] { return existing }
        let screen: ScreenView
        if id.hasPrefix("library-"), let directory = libraryLayout.tabs.first(where: { "library-\($0.key ?? "")" == id }) {
            screen = LibraryScreen(api: payload.api, directory: directory)
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
        let stack = makeStack(for: id)
        tabBar.select(id, animated: true)
        guard stack !== current else { return }
        current?.removeFromSuperview()
        currentID = id
        current = stack
        insertSubview(stack, below: tabBar)
        stack.frame = bounds
        tabBar.setHidden(false, animated: true)
        window?.focus.focus(stack, animated: false)
    }

    private func navigationChanged() {
        tabBar.setHidden(false, animated: true)
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

    /// The tvOS app's commands with Ctrl for Command: Ctrl+1 to Ctrl+9 pick tabs.
    func handleCommand(_ event: KeyEvent) -> Bool {
        let digit = Int(event.key.rawValue) - 0x30
        if event.modifiers == .control, digit >= 1, digit <= min(9, tabBar.tabs.count) {
            select(tabBar.tabs[digit - 1].id)
            return true
        }
        return false
    }

    private var player: PlayerScreen?

    /// Plays `item` over everything, from where the viewer left it; focus returns where it was when the player closes.
    func play(item: PlexMetadata, api: APIClient, from position: Double? = nil) {
        guard player == nil else { return }
        let returnFocus = window?.focusedView
        let screen = PlayerScreen(source: .plex(api, item, resume: position ?? item.resumeSecs))
        screen.onClose = { [weak self, weak screen] in
            screen?.removeFromSuperview()
            self?.player = nil
            if let returnFocus, returnFocus.window != nil { self?.window?.focus.focus(returnFocus, animated: false) }
        }
        player = screen
        addSubview(screen)
        screen.frame = bounds
        window?.focus.focus(screen, animated: false)
    }

    /// Pushes a screen on the current tab's stack.
    func push(_ screen: ScreenView) {
        current?.push(screen)
    }

    /// The tab bar slides away while a screen's content scrolls down, and comes back at the top or when focus reaches it.
    func contentScrolled(offset: Float) {
        tabBar.setHidden(offset > Theme.current.metrics.tv(40), animated: true)
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        current?.frame = bounds
        player?.frame = bounds
        tabBar.frame = Rect(x: 0, y: 0, width: frame.width, height: metrics.tabBarTop + metrics.tabBarHeight + metrics.tv(20))
    }
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

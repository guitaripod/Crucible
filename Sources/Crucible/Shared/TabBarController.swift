import AVKit
import CrucibleCore
import CrucibleDesign
import UIKit

final class TabBarController: UITabBarController {
    enum Tab: Int, CaseIterable {
        case home, library, downloads, you, search

        var identifier: String {
            switch self {
            case .home: return "home"
            case .library: return "library"
            case .downloads: return "downloads"
            case .you: return "you"
            case .search: return "search"
            }
        }

        init?(identifier: String) {
            guard let tab = Self.allCases.first(where: { identifier == $0.identifier || identifier.hasPrefix($0.identifier + ".") }) else {
                return nil
            }
            self = tab
        }
    }

    let api: APIClient
    private let payload: LaunchPayload
    private let libraries: [LibrarySection]
    private let homeNavigation: UINavigationController
    private var libraryScreens: [String: LibraryViewController] = [:]
    private var downloadObserver: UUID?
    private var downloadsTab: AnyObject?
    private var searchTab: AnyObject?

    /// `preloadsHome` hands Home the shelves the launch fetched; a window opened later passes false so Home loads its own.
    init(payload: LaunchPayload, preloadsHome: Bool = true) {
        self.payload = payload
        self.api = payload.api
        self.libraries = LibrarySection.sections(in: payload.sections)
        self.homeNavigation = ContentNavigationController(
            rootViewController: HomeViewController(api: payload.api, preloaded: preloadsHome ? payload.hubs : nil)
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let downloadObserver {
            Task { @MainActor in DownloadManager.shared.removeObserver(downloadObserver) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.tintColor = Theme.Color.accent
        delegate = self

        let downloads = ContentNavigationController(rootViewController: DownloadsViewController(api: api))
        let you = ContentNavigationController(rootViewController: YouViewController(api: api))
        let search = ContentNavigationController(rootViewController: SearchViewController(api: api))

        if #available(iOS 18.0, *) {
            installTabs(downloads: downloads, you: you, search: search)
        } else {
            installLegacyTabs(downloads: downloads, you: you, search: search)
        }

        downloadObserver = DownloadManager.shared.addObserver { [weak self] _ in
            self?.updateDownloadBadge()
        }
        updateDownloadBadge()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        updateWindowTitle()
    }

    private func allLibrariesNavigation() -> UINavigationController {
        ContentNavigationController(rootViewController: LibraryViewController(api: api, preloaded: payload.sections))
    }

    /// Each library keeps its grid, filters and scroll position while another one is shown.
    private func libraryScreen(for section: LibrarySection) -> LibraryViewController {
        if let library = libraryScreens[section.id] { return library }
        let library = LibraryViewController(api: api, preloaded: payload.sections, pinnedSectionID: section.id)
        library.onSelectLibrary = { [weak self] id in self?.selectLibrary(id) }
        libraryScreens[section.id] = library
        return library
    }

    /// The Library tab is a group of the server's libraries: the sidebar lists each one, the tab bar shows a single Library tab whose title
    /// menu moves between them. The group's stack starts at the selected library; the group's own screen is never shown.
    @available(iOS 18.0, *)
    private func installTabs(downloads: UINavigationController, you: UINavigationController, search: UINavigationController) {
        let home = homeNavigation
        let homeTab = UITab(title: "Home", image: UIImage(systemName: "house"), identifier: Tab.home.identifier) { _ in home }
        let libraryTab: UITab
        if libraries.isEmpty {
            let library = allLibrariesNavigation()
            libraryTab = UITab(title: "Library", image: UIImage(systemName: "rectangle.stack"), identifier: Tab.library.identifier) { _ in library }
        } else {
            let children = libraries.map { section in
                let tab = UITab(
                    title: section.title,
                    image: UIImage(systemName: section.kind == .movie ? "film" : "tv"),
                    identifier: Self.libraryIdentifier(section.id)
                ) { [unowned self] _ in libraryScreen(for: section) }
                tab.allowsHiding = true
                return tab
            }
            let sections = payload.sections
            let group = UITabGroup(
                title: "Library",
                image: UIImage(systemName: "rectangle.stack"),
                identifier: Tab.library.identifier,
                children: children
            ) { [api] _ in LibraryViewController(api: api, preloaded: sections) }
            group.managingNavigationController = ContentNavigationController()
            libraryTab = group
        }
        let downloadsTab = UITab(title: "Downloads", image: UIImage(systemName: "arrow.down.circle"), identifier: Tab.downloads.identifier) { _ in downloads }
        let youTab = UITab(title: "You", image: UIImage(systemName: "person.crop.circle"), identifier: Tab.you.identifier) { _ in you }
        let searchTab = UISearchTab { _ in search }
        searchTab.title = "Search"
        self.downloadsTab = downloadsTab
        self.searchTab = searchTab
        tabs = [homeTab, libraryTab, downloadsTab, youTab, searchTab]
        customizationIdentifier = "com.guitaripod.crucible.tabs"
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior = .onScrollDown
        }
    }

    private static func libraryIdentifier(_ sectionID: String) -> String {
        "\(Tab.library.identifier).\(sectionID)"
    }

    private func installLegacyTabs(downloads: UINavigationController, you: UINavigationController, search: UINavigationController) {
        let library = allLibrariesNavigation()
        homeNavigation.tabBarItem = UITabBarItem(title: "Home", image: UIImage(systemName: "house"), selectedImage: UIImage(systemName: "house.fill"))
        library.tabBarItem = UITabBarItem(title: "Library", image: UIImage(systemName: "rectangle.stack"), selectedImage: UIImage(systemName: "rectangle.stack.fill"))
        downloads.tabBarItem = UITabBarItem(title: "Downloads", image: UIImage(systemName: "arrow.down.circle"), selectedImage: UIImage(systemName: "arrow.down.circle.fill"))
        you.tabBarItem = UITabBarItem(title: "You", image: UIImage(systemName: "person.crop.circle"), selectedImage: UIImage(systemName: "person.crop.circle.fill"))
        search.tabBarItem = UITabBarItem(tabBarSystemItem: .search, tag: 4)
        downloadsTab = downloads.tabBarItem
        viewControllers = [homeNavigation, library, downloads, you, search]
    }

    private func updateDownloadBadge() {
        let active = DownloadManager.shared.items.filter { $0.state != .completed && $0.state != .failed }.count
        let value = active > 0 ? "\(active)" : nil
        if #available(iOS 18.0, *), let tab = downloadsTab as? UITab {
            tab.badgeValue = value
        } else if let item = downloadsTab as? UITabBarItem {
            item.badgeValue = value
        }
    }

    var homeScreen: HomeViewController? {
        homeNavigation.viewControllers.first as? HomeViewController
    }

    var currentNavigation: UINavigationController? {
        selectedViewController as? UINavigationController
    }

    // MARK: - Selection

    /// Selects `tab` and returns its navigation stack at the root, for callers that take the user somewhere on purpose.
    @discardableResult
    func open(_ tab: Tab) -> UINavigationController? {
        select(tab)
        let navigation = currentNavigation
        navigation?.popToRootViewController(animated: false)
        return navigation
    }

    /// Selects `tab` and leaves its stack where the user left it.
    func select(_ tab: Tab) {
        select(identifier: tab.identifier)
    }

    /// Leaving a tab from the keyboard also ends any typing there, so the keyboard does not stay up over the new tab.
    private func select(identifier: String) {
        view.window?.endEditing(true)
        if #available(iOS 18.0, *), !tabs.isEmpty {
            guard let tab = uiTab(for: identifier) else { return }
            if let group = tab as? UITabGroup {
                select(group)
            } else if let group = tab.parent {
                select(group, child: tab)
            } else {
                selectedTab = tab
            }
        } else if let tab = Tab(identifier: identifier) {
            selectedIndex = tab.rawValue
        }
        updateWindowTitle()
    }

    /// A group has no screen of its own: selecting it means selecting the library it was last on, or its first.
    @available(iOS 18.0, *)
    private func select(_ group: UITabGroup) {
        guard let child = group.selectedChild ?? group.children.first else {
            selectedTab = group
            return
        }
        select(group, child: child)
    }

    /// A tab inside a group is shown by selecting that child of the group, not by asking the tab bar for the child alone.
    @available(iOS 18.0, *)
    private func select(_ group: UITabGroup, child: UITab) {
        group.selectedChild = child
        selectedTab = child
    }

    /// The search tab carries a system identifier, so it is matched by reference.
    @available(iOS 18.0, *)
    private func uiTab(for identifier: String) -> UITab? {
        if identifier == Tab.search.identifier, let searchTab = searchTab as? UITab { return searchTab }
        return tab(forIdentifier: identifier)
    }

    private var selectedIdentifier: String {
        if #available(iOS 18.0, *), let selectedTab {
            return selectedTab === searchTab ? Tab.search.identifier : selectedTab.identifier
        }
        return (Tab(rawValue: selectedIndex) ?? .home).identifier
    }

    /// Switches the Library tab to another library, crossfading like the switcher always has.
    private func selectLibrary(_ sectionID: String) {
        guard #available(iOS 18.0, *),
              let tab = tab(forIdentifier: Self.libraryIdentifier(sectionID)),
              let group = tab.parent else { return }
        Haptics.selection()
        let duration = UIAccessibility.isReduceMotionEnabled ? 0 : 0.2
        UIView.transition(with: view, duration: duration, options: .transitionCrossDissolve) {
            self.select(group, child: tab)
        }
        updateWindowTitle()
    }

    func openMedia(ratingKey: String, mediaType: String) {
        if presentedViewController != nil {
            dismiss(animated: false)
        }
        open(.home)
        homeNavigation.pushViewController(Self.detail(api: api, ratingKey: ratingKey, mediaType: mediaType), animated: true)
    }

    private static func detail(api: APIClient, ratingKey: String, mediaType: String) -> UIViewController {
        mediaType == "show"
            ? ShowDetailViewController(api: api, showRatingKey: ratingKey)
            : MediaDetailViewController(api: api, ratingKey: ratingKey, mediaType: mediaType)
    }

    // MARK: - Windows

    func updateWindowTitle() {
        guard let scene = view.window?.windowScene else { return }
        let top = currentNavigation?.topViewController
        scene.title = top?.navigationItem.title ?? top?.title ?? currentNavigation?.title
    }

    /// What this window shows, so iPadOS reopens it on the same tab and title.
    func restorationActivity() -> NSUserActivity {
        let media = (currentNavigation?.topViewController as? MediaScreen)?.mediaRoute
        return WindowActivity.make(tab: selectedIdentifier, media: media)
    }

    /// Opens what `activity` points at: a title (Spotlight, Handoff, Open in New Window) or a window's saved tab and title.
    func restore(from activity: NSUserActivity) {
        if let media = MediaActivity.route(activity) {
            openMedia(ratingKey: media.ratingKey, mediaType: media.mediaType)
            return
        }
        guard let state = WindowActivity.state(from: activity) else { return }
        select(identifier: state.tab)
        guard let media = state.media, let navigation = currentNavigation else { return }
        navigation.pushViewController(Self.detail(api: api, ratingKey: media.ratingKey, mediaType: media.mediaType), animated: false)
        updateWindowTitle()
    }

    // MARK: - Commands

    /// The single entry point for every menu bar item and keyboard shortcut; see `AppCommand`.
    @objc func performCommand(_ sender: UICommand) {
        guard let command = AppCommand(sender: sender), canPerform(command) else { return }
        perform(command)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard action == #selector(performCommand(_:)) else { return super.canPerformAction(action, withSender: sender) }
        guard let command = AppCommand(sender: sender) else { return false }
        return canPerform(command)
    }

    override func validate(_ command: UICommand) {
        super.validate(command)
        guard let appCommand = AppCommand(sender: command) else { return }
        if appCommand == .skip {
            command.title = presentedPlayer?.skipTitle ?? appCommand.title
            return
        }
        command.title = contentHandler?.title(for: appCommand) ?? appCommand.title
    }

    /// The player on screen in this window, which takes the skip and next-episode keys.
    private var presentedPlayer: PlayerCoordinator? {
        (presentedViewController as? AVPlayerViewController)?.delegate as? PlayerCoordinator
    }

    /// The screen on top of the selected tab, when it acts on commands about what it shows.
    private var contentHandler: CommandHandling? {
        currentNavigation?.topViewController as? CommandHandling
    }

    private var isShowingModal: Bool {
        guard let presented = presentedViewController else { return false }
        return !presented.isBeingDismissed
    }

    private func canPerform(_ command: AppCommand) -> Bool {
        switch command {
        case .newWindow: return UIApplication.shared.supportsMultipleScenes
        case .skip: return presentedPlayer?.skipTitle != nil
        case .playNext: return presentedPlayer?.offersNextEpisode == true
        case .closePlayer: return presentedPlayer != nil
        default: break
        }
        guard !isShowingModal else { return false }
        switch command {
        case .home, .library, .downloads, .you, .search, .statistics, .history, .surpriseMe, .settings:
            return true
        case .back:
            return (currentNavigation?.viewControllers.count ?? 0) > 1
        case .switchServer:
            return !DemoMode.shared.isActive
        case .refresh, .largerPosters, .smallerPosters, .play, .toggleWatched, .download:
            return contentHandler?.canPerform(command) ?? false
        case .newWindow, .skip, .playNext, .closePlayer:
            return false
        }
    }

    private func perform(_ command: AppCommand) {
        switch command {
        case .home: select(.home)
        case .library: select(.library)
        case .downloads: select(.downloads)
        case .you: select(.you)
        case .search: activateSearch()
        case .back: currentNavigation?.popViewController(animated: true)
        case .statistics: show(StatisticsViewController(api: api), onTopOf: .you)
        case .history: show(ActivityHistoryViewController(api: api), onTopOf: .you)
        case .settings: show(SettingsViewController(api: api), onTopOf: .you)
        case .surpriseMe:
            open(.home)
            homeScreen?.surprise(.any)
        case .switchServer: presentServerSwitcher()
        case .newWindow: WindowActivity.openWindow(for: nil, from: view.window?.windowScene)
        case .skip: presentedPlayer?.performShownSkip()
        case .playNext: presentedPlayer?.playOfferedNextEpisode()
        case .closePlayer: presentedPlayer?.close()
        case .refresh, .largerPosters, .smallerPosters, .play, .toggleWatched, .download:
            contentHandler?.perform(command)
        }
    }

    /// Opens `screen` from the root of `tab`, unless that stack already shows one like it.
    private func show(_ screen: UIViewController, onTopOf tab: Tab) {
        let navigation = open(tab)
        guard type(of: navigation?.topViewController) != type(of: screen) else { return }
        navigation?.pushViewController(screen, animated: true)
    }

    private func activateSearch() {
        let navigation = open(.search)
        (navigation?.topViewController as? SearchViewController)?.activateSearchField()
    }

    private func presentServerSwitcher() {
        let setup = ServerSetupViewController()
        setup.allowsCancel = true
        setup.onConnected = { [weak self] _ in
            (self?.view.window?.windowScene?.delegate as? SceneDelegate)?.reconfigureRoot()
        }
        let navigation = UINavigationController(rootViewController: setup)
        navigation.modalPresentationStyle = .fullScreen
        present(navigation, animated: true)
    }
}

extension TabBarController: UITabBarControllerDelegate {
    /// Tapping the Library tab lands on the group itself, which has nothing of its own to show, so the tap picks its library instead.
    @available(iOS 18.0, *)
    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        guard let group = tab as? UITabGroup, group.identifier == Tab.library.identifier else { return true }
        select(group)
        return false
    }

    @available(iOS 18.0, *)
    func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
        updateWindowTitle()
    }

    @available(iOS 18.0, *)
    func tabBarController(
        _ tabBarController: UITabBarController,
        displayedViewControllersFor tab: UITab,
        proposedViewControllers: [UIViewController]
    ) -> [UIViewController] {
        guard let group = tab as? UITabGroup, group.identifier == Tab.library.identifier, !group.children.isEmpty else {
            return proposedViewControllers
        }
        return []
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        updateWindowTitle()
    }
}

/// A detail screen whose title iPadOS can reopen in a restored or new window.
@MainActor
protocol MediaScreen: AnyObject {
    var mediaRoute: (ratingKey: String, mediaType: String) { get }
}

/// The navigation stack of a tab: it names the window after the screen on top.
final class ContentNavigationController: UINavigationController, UINavigationControllerDelegate {
    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        guard let tabBar = tabBarController as? TabBarController, tabBar.selectedViewController === self else { return }
        tabBar.updateWindowTitle()
    }
}

import UIKit

final class TabBarController: UITabBarController {
    private let api: APIClient
    private let payload: LaunchPayload
    private let homeNavigation: UINavigationController
    private var downloadObserver: UUID?
    private var downloadsTab: AnyObject?

    init(payload: LaunchPayload) {
        self.payload = payload
        self.api = payload.api
        self.homeNavigation = UINavigationController(rootViewController: HomeViewController(api: payload.api, preloaded: payload.hubs))
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

        let library = UINavigationController(rootViewController: LibraryViewController(api: api, preloaded: payload.sections))
        let downloads = UINavigationController(rootViewController: DownloadsViewController(api: api))
        let you = UINavigationController(rootViewController: YouViewController(api: api))
        let search = UINavigationController(rootViewController: SearchViewController(api: api))

        if #available(iOS 18.0, *) {
            installTabs(library: library, downloads: downloads, you: you, search: search)
        } else {
            installLegacyTabs(library: library, downloads: downloads, you: you, search: search)
        }

        downloadObserver = DownloadManager.shared.addObserver { [weak self] _ in
            self?.updateDownloadBadge()
        }
        updateDownloadBadge()
    }

    @available(iOS 18.0, *)
    private func installTabs(
        library: UINavigationController,
        downloads: UINavigationController,
        you: UINavigationController,
        search: UINavigationController
    ) {
        let home = homeNavigation
        let homeTab = UITab(title: "Home", image: UIImage(systemName: "house"), identifier: "home") { _ in home }
        let libraryTab = UITab(title: "Library", image: UIImage(systemName: "rectangle.stack"), identifier: "library") { _ in library }
        let downloadsTab = UITab(title: "Downloads", image: UIImage(systemName: "arrow.down.circle"), identifier: "downloads") { _ in downloads }
        let youTab = UITab(title: "You", image: UIImage(systemName: "person.crop.circle"), identifier: "you") { _ in you }
        let searchTab = UISearchTab { _ in search }
        searchTab.title = "Search"
        self.downloadsTab = downloadsTab
        tabs = [homeTab, libraryTab, downloadsTab, youTab, searchTab]
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior = .onScrollDown
        }
    }

    private func installLegacyTabs(
        library: UINavigationController,
        downloads: UINavigationController,
        you: UINavigationController,
        search: UINavigationController
    ) {
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

    func openMedia(ratingKey: String, mediaType: String) {
        if presentedViewController != nil {
            dismiss(animated: false)
        }
        selectedIndex = 0
        let destination: UIViewController = mediaType == "show"
            ? ShowDetailViewController(api: api, showRatingKey: ratingKey)
            : MediaDetailViewController(api: api, ratingKey: ratingKey, mediaType: mediaType)
        homeNavigation.popToRootViewController(animated: false)
        homeNavigation.pushViewController(destination, animated: true)
    }
}

import UIKit

final class TabBarController: UITabBarController {
    private let api: APIClient

    private let payload: LaunchPayload

    init(payload: LaunchPayload) {
        self.payload = payload
        self.api = payload.api
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.tintColor = .systemOrange

        let home = UINavigationController(rootViewController: HomeViewController(api: api, preloaded: payload.hubs))
        home.tabBarItem = UITabBarItem(title: "Home", image: UIImage(systemName: "house"), selectedImage: UIImage(systemName: "house.fill"))

        let library = UINavigationController(rootViewController: LibraryViewController(api: api, preloaded: payload.sections))
        library.tabBarItem = UITabBarItem(title: "Library", image: UIImage(systemName: "rectangle.stack"), selectedImage: UIImage(systemName: "rectangle.stack.fill"))

        let search = UINavigationController(rootViewController: SearchViewController(api: api))
        search.tabBarItem = UITabBarItem(title: "Search", image: UIImage(systemName: "magnifyingglass"), tag: 2)

        let downloads = UINavigationController(rootViewController: DownloadsViewController(api: api))
        downloads.tabBarItem = UITabBarItem(title: "Downloads", image: UIImage(systemName: "arrow.down.circle"), selectedImage: UIImage(systemName: "arrow.down.circle.fill"))

        let settings = UINavigationController(rootViewController: SettingsViewController(api: api))
        settings.tabBarItem = UITabBarItem(title: "Settings", image: UIImage(systemName: "gearshape"), selectedImage: UIImage(systemName: "gearshape.fill"))

        viewControllers = [home, library, search, downloads, settings]
    }

    func openMedia(ratingKey: String, mediaType: String) {
        if presentedViewController != nil {
            dismiss(animated: false)
        }
        selectedIndex = 0
        guard let nav = viewControllers?.first as? UINavigationController else { return }
        let destination: UIViewController = mediaType == "show"
            ? ShowDetailViewController(api: api, showRatingKey: ratingKey)
            : MediaDetailViewController(api: api, ratingKey: ratingKey, mediaType: mediaType)
        nav.popToRootViewController(animated: false)
        nav.pushViewController(destination, animated: true)
    }
}

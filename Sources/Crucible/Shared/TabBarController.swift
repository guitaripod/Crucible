import UIKit

final class TabBarController: UITabBarController {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.tintColor = .systemOrange

        let home = UINavigationController(rootViewController: HomeViewController(api: api))
        home.tabBarItem = UITabBarItem(title: "Home", image: UIImage(systemName: "house"), selectedImage: UIImage(systemName: "house.fill"))

        let library = UINavigationController(rootViewController: LibraryViewController(api: api))
        library.tabBarItem = UITabBarItem(title: "Library", image: UIImage(systemName: "rectangle.stack"), selectedImage: UIImage(systemName: "rectangle.stack.fill"))

        let search = UINavigationController(rootViewController: SearchViewController(api: api))
        search.tabBarItem = UITabBarItem(title: "Search", image: UIImage(systemName: "magnifyingglass"), tag: 2)

        let settings = UINavigationController(rootViewController: SettingsViewController(api: api))
        settings.tabBarItem = UITabBarItem(title: "Settings", image: UIImage(systemName: "gearshape"), selectedImage: UIImage(systemName: "gearshape.fill"))

        viewControllers = [home, library, search, settings]
    }

    func openMedia(ratingKey: String, mediaType: String) {
        selectedIndex = 0
        guard let nav = viewControllers?.first as? UINavigationController else { return }
        let destination: UIViewController = mediaType == "show"
            ? ShowDetailViewController(api: api, showRatingKey: ratingKey)
            : MediaDetailViewController(api: api, ratingKey: ratingKey, mediaType: mediaType)
        nav.popToRootViewController(animated: false)
        nav.pushViewController(destination, animated: true)
    }
}

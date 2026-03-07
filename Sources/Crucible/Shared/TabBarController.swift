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

        let home = UINavigationController(rootViewController: HomeViewController(api: api))
        home.tabBarItem = UITabBarItem(title: "Home", image: UIImage(systemName: "house"), tag: 0)

        let library = UINavigationController(rootViewController: LibraryViewController(api: api))
        library.tabBarItem = UITabBarItem(title: "Library", image: UIImage(systemName: "rectangle.grid.2x2"), tag: 1)

        let search = UINavigationController(rootViewController: SearchViewController(api: api))
        search.tabBarItem = UITabBarItem(title: "Search", image: UIImage(systemName: "magnifyingglass"), tag: 2)

        let settings = UINavigationController(rootViewController: SettingsViewController(api: api))
        settings.tabBarItem = UITabBarItem(title: "Settings", image: UIImage(systemName: "gear"), tag: 3)

        viewControllers = [home, library, search, settings]
    }
}

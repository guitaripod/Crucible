import CrucibleCore
import CrucibleDesign
import UIKit

/// `Home | one tab per library (or three plus More) | Search | You`. Each tab hosts its own
/// navigation controller with the bar hidden. Every movie and show library gets a tab, whether or
/// not it counts toward Home and Statistics.
@MainActor
final class TVRootTabBarController: UITabBarController {
    private struct Entry {
        let identifier: String
        let title: String
        let symbol: String
        let makeRoot: @MainActor () -> UIViewController
    }

    private static let homeIdentifier = "home"
    private static let searchIdentifier = "search"

    let environment: TVAppEnvironment

    private var entries: [Entry] = []
    private var navigations: [String: UINavigationController] = [:]

    init(environment: TVAppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.tintColor = Theme.Color.accent
        installTabs()
    }

    /// Selects Home and returns its navigation controller.
    func showHome() -> UINavigationController {
        loadViewIfNeeded()
        selectedIndex = 0
        return navigation(for: entries[0])
    }

    /// Selects the tab for `destination` (the first library, or More when every library sits behind it) and returns its navigation
    /// controller; nil when the server has no such tab.
    func select(_ destination: TVTabDestination) -> UINavigationController? {
        loadViewIfNeeded()
        guard let index = entries.firstIndex(where: { Self.matches($0.identifier, destination) }) else { return nil }
        selectedIndex = index
        return navigation(for: entries[index])
    }

    private static func matches(_ identifier: String, _ destination: TVTabDestination) -> Bool {
        switch destination {
        case .library: identifier.hasPrefix("library.") || identifier == "more"
        case .search: identifier == searchIdentifier
        }
    }

    private func installTabs() {
        entries = makeEntries()
        if #available(tvOS 18.0, *) {
            tabs = entries.map(tab(for:))
        } else {
            viewControllers = entries.map(legacyRoot(for:))
        }
        selectedIndex = 0
    }

    private func makeEntries() -> [Entry] {
        let env = environment
        let layout = env.libraryLayout
        var result = [
            Entry(identifier: Self.homeIdentifier, title: "Home", symbol: "house") { TVScreens.home(env) }
        ]
        for section in layout.tabs {
            result.append(
                Entry(
                    identifier: "library.\(section.key ?? "")",
                    title: section.title ?? "Library",
                    symbol: section.type == "show" ? "tv" : "film"
                ) { TVScreens.library(env, section: section) }
            )
        }
        if layout.hasMore {
            result.append(Entry(identifier: "more", title: "More", symbol: "ellipsis") { TVScreens.more(env) })
        }
        result.append(Entry(identifier: Self.searchIdentifier, title: "Search", symbol: "magnifyingglass") { TVScreens.search(env) })
        result.append(Entry(identifier: "you", title: "You", symbol: "person.crop.circle") { TVScreens.you(env) })
        return result
    }

    private func navigation(for entry: Entry) -> UINavigationController {
        if let existing = navigations[entry.identifier] { return existing }
        let navigation = TVNavigation.makeNavigationController(root: entry.makeRoot())
        navigations[entry.identifier] = navigation
        return navigation
    }

    @available(tvOS 18.0, *)
    private func tab(for entry: Entry) -> UITab {
        let navigation = navigation(for: entry)
        guard entry.identifier == Self.searchIdentifier else {
            return UITab(title: entry.title, image: UIImage(systemName: entry.symbol), identifier: entry.identifier) { _ in navigation }
        }
        let search = UISearchTab { _ in navigation }
        search.title = entry.title
        return search
    }

    private func legacyRoot(for entry: Entry) -> UINavigationController {
        let navigation = navigation(for: entry)
        if entry.identifier == Self.searchIdentifier {
            navigation.tabBarItem = UITabBarItem(tabBarSystemItem: .search, tag: 0)
        } else {
            navigation.tabBarItem = UITabBarItem(title: entry.title, image: UIImage(systemName: entry.symbol), selectedImage: nil)
        }
        return navigation
    }
}

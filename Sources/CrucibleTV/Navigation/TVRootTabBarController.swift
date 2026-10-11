import CrucibleCore
import CrucibleDesign
import UIKit

/// `Home | one tab per visible library (or three plus More) | Search | You`. Each tab hosts its own
/// navigation controller with the bar hidden. The tab set follows `LibraryVisibility`: a change
/// rebuilds the tabs and keeps the selection, and tabs that survive keep their navigation stack.
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
    private var tabObjects: [String: AnyObject] = [:]
    private var visibilityObserver: UUID?

    init(environment: TVAppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let visibilityObserver {
            Task { @MainActor in LibraryVisibility.removeObserver(visibilityObserver) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.tintColor = Theme.Color.accent
        installTabs(selecting: Self.homeIdentifier)
        visibilityObserver = LibraryVisibility.addObserver { [weak self] in
            self?.visibilityChanged()
        }
    }

    /// Selects Home and returns its navigation controller.
    func showHome() -> UINavigationController {
        loadViewIfNeeded()
        selectedIndex = 0
        return navigation(for: entries[0])
    }

    private func visibilityChanged() {
        installTabs(selecting: selectedIdentifier ?? Self.homeIdentifier)
    }

    private var selectedIdentifier: String? {
        entries.indices.contains(selectedIndex) ? entries[selectedIndex].identifier : nil
    }

    private func installTabs(selecting identifier: String) {
        let fresh = makeEntries()
        guard fresh.map(\.identifier) != entries.map(\.identifier) else { return }
        entries = fresh
        let live = Set(fresh.map(\.identifier))
        navigations = navigations.filter { live.contains($0.key) }
        tabObjects = tabObjects.filter { live.contains($0.key) }

        if #available(tvOS 18.0, *) {
            tabs = fresh.map(tab(for:))
        } else {
            viewControllers = fresh.map(legacyRoot(for:))
        }
        selectedIndex = fresh.firstIndex { $0.identifier == identifier } ?? 0
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
        if let cached = tabObjects[entry.identifier] as? UITab { return cached }
        let navigation = navigation(for: entry)
        let tab: UITab
        if entry.identifier == Self.searchIdentifier {
            let search = UISearchTab { _ in navigation }
            search.title = entry.title
            tab = search
        } else {
            tab = UITab(title: entry.title, image: UIImage(systemName: entry.symbol), identifier: entry.identifier) { _ in navigation }
        }
        tabObjects[entry.identifier] = tab
        return tab
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

import CrucibleCore
import UIKit

extension TVScreens {
    static func search(_ env: TVAppEnvironment) -> UIViewController {
        let results = TVSearchResultsViewController(env: env)
        let searchController = UISearchController(searchResultsController: results)
        searchController.searchResultsUpdater = results
        searchController.searchBar.placeholder = SearchCopy.placeholder
        searchController.searchBar.autocapitalizationType = .none
        searchController.searchBar.autocorrectionType = .no
        searchController.searchBar.accessibilityIdentifier = "search.field"
        let container = UISearchContainerViewController(searchController: searchController)
        container.title = "Search"
        results.searchController = searchController
        results.host = container
        return container
    }
}

import UIKit
@testable import Crucible
@testable import CrucibleCore
@testable import CrucibleStats

/// The screens the store images are made from and nothing else, in one launch: Home, a library, a title, the
/// Essentials offer, a search that finds what the server lacks, Downloads, What to Watch, Previously On, Statistics
/// and its poster, and the player's Skip buttons. A third of the whole tour's time, which matters when every app
/// language is shot on every Duo display.
@MainActor
enum StoreShotScript {
    static func run() async {
        guard let tabBar = await ShotHarness.waitForTabBar() else { return }
        let api = APIClient(baseURL: ServerBootstrap.connection()!.serverURI, token: "mock-token")
        await ShotHarness.settle(4)
        await ShotHarness.capture("01-home")

        tabBar.select(.library)
        await ShotHarness.settle(8.5)
        await ShotHarness.capture("02b-library-settled")

        tabBar.select(.home)
        await ShotHarness.settle(1)
        let home = ShotScript.navigation(tabBar)
        home?.pushViewController(MediaDetailViewController(api: api, ratingKey: "1001", mediaType: "movie"), animated: false)
        await ShotHarness.settle(4)
        await ShotHarness.capture("03-detail")
        home?.popToRootViewController(animated: false)
        await essentialsOffer(api: api, home: home)

        tabBar.select(.search)
        await ShotHarness.settle(1.5)
        if let search = ShotScript.navigation(tabBar)?.topViewController as? SearchViewController {
            let controller = search.navigationItem.searchController
            controller?.searchBar.text = "orchard"
            if let controller { search.updateSearchResults(for: controller) }
            await ShotHarness.settle(3)
            await ShotHarness.capture("05b-search-request")
        }

        tabBar.select(.downloads)
        await ShotHarness.settle(2.5)
        await ShotHarness.capture("06-downloads")

        await WatchShotScript.scenes(tabBar: tabBar, api: api)
        await statistics(tabBar: tabBar, api: api)
        await ShotScript.playRecap(api: api, tabBar: tabBar)
        await ShotHarness.capture("done")
    }

    /// Statistics and its poster once the counting has settled, so the hours are the same on every display and in
    /// every language instead of an estimate caught partway.
    private static func statistics(tabBar: TabBarController, api: APIClient) async {
        tabBar.select(.you)
        await ShotHarness.settle(2)
        let you = ShotScript.navigation(tabBar)
        await countedAsFarAsALaunchGoes()
        let statistics = StatisticsViewController(api: api)
        you?.pushViewController(statistics, animated: false)
        await ShotHarness.settle(8)
        await ShotHarness.capture("07-stats")
        statistics.shareWrapped(from: nil)
        await ShotHarness.settle(3)
        await ShotHarness.capture("07c-share-preview")
        statistics.dismiss(animated: false)
        await ShotHarness.settle(1)
        you?.popToRootViewController(animated: false)
    }

    /// Waits until Statistics has counted every play, or as many as one launch counts: the share that is counted
    /// stops rising when the launch's allowance of titles is used up, at the same point on every run.
    private static func countedAsFarAsALaunchGoes() async {
        var last = -1.0
        var unchanged = 0
        for _ in 0..<120 {
            let snapshot = try? await StatsManager.shared.store?.snapshot(range: .year, source: .everything)
            let counted = snapshot?.overview.coverage ?? 0
            if counted >= 0.99, snapshot?.traktImportPending == false { return }
            unchanged = counted == last && counted > 0.5 ? unchanged + 1 : 0
            if unchanged >= 6 { return }
            last = counted
            await ShotHarness.settle(2)
        }
    }

    /// Paper Lanterns with its demo guide, showing the one-time offer to skip its anime-only episodes.
    private static func essentialsOffer(api: APIClient, home: UINavigationController?) async {
        UserDefaults.standard.set(true, forKey: DemoMode.activeKey)
        home?.pushViewController(ShowDetailViewController(api: api, showRatingKey: "2005"), animated: false)
        await ShotHarness.settle(4)
        await ShotHarness.capture("04c-essentials-offer")
        home?.popToRootViewController(animated: false)
        UserDefaults.standard.set(false, forKey: DemoMode.activeKey)
    }
}

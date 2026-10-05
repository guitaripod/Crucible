import AVKit
import UIKit
@testable import Crucible

@MainActor
enum ShotScript {
    static func run() async {
        guard let tabBar = await ShotHarness.waitForTabBar() else { return }
        let api = APIClient(baseURL: ServerBootstrap.connection()!.serverURI, token: "mock-token")
        await ShotHarness.settle(4)
        await ShotHarness.capture("01-home")

        tabBar.selectedIndex = 1
        await ShotHarness.settle(3.5)
        await ShotHarness.capture("02-library")

        tabBar.selectedIndex = 0
        await ShotHarness.settle(1)
        let home = navigation(tabBar)
        home?.pushViewController(MediaDetailViewController(api: api, ratingKey: "1001", mediaType: "movie"), animated: false)
        await ShotHarness.settle(4)
        await ShotHarness.capture("03-detail")
        scroll(home?.topViewController, to: 560)
        await ShotHarness.settle(1)
        await ShotHarness.capture("03b-detail-scrolled")
        home?.popToRootViewController(animated: false)

        home?.pushViewController(ShowDetailViewController(api: api, showRatingKey: "2001"), animated: false)
        await ShotHarness.settle(4)
        await ShotHarness.capture("04-show")
        scroll(home?.topViewController, to: 470)
        await ShotHarness.settle(1.5)
        await ShotHarness.capture("04b-show-episodes")
        home?.popToRootViewController(animated: false)

        tabBar.selectedIndex = 4
        await ShotHarness.settle(1.5)
        if let search = navigation(tabBar)?.topViewController as? SearchViewController {
            await ShotHarness.capture("05a-search-idle")
            let controller = search.navigationItem.searchController
            controller?.searchBar.text = "hal"
            if let controller { search.updateSearchResults(for: controller) }
            await ShotHarness.settle(2.5)
            await ShotHarness.capture("05-search")
        }

        tabBar.selectedIndex = 2
        await ShotHarness.settle(2.5)
        await ShotHarness.capture("06-downloads")

        tabBar.selectedIndex = 3
        await ShotHarness.settle(2)
        let you = navigation(tabBar)
        await ShotHarness.capture("08-you")

        you?.pushViewController(StatisticsViewController(api: api), animated: false)
        await ShotHarness.settle(14)
        await ShotHarness.capture("07-stats")
        scroll(you?.topViewController, to: 620)
        await ShotHarness.settle(1.5)
        await ShotHarness.capture("07b-stats-scrolled")
        you?.popToRootViewController(animated: false)

        you?.pushViewController(ActivityHistoryViewController(api: api), animated: false)
        await ShotHarness.settle(3.5)
        await ShotHarness.capture("10-history")
        you?.popToRootViewController(animated: false)

        you?.pushViewController(SettingsViewController(api: api), animated: false)
        await ShotHarness.settle(2.5)
        await ShotHarness.capture("11-settings")
        you?.popToRootViewController(animated: false)

        you?.pushViewController(ServerDetailViewController(api: api), animated: false)
        await ShotHarness.settle(3)
        await ShotHarness.capture("12-server")
        you?.popToRootViewController(animated: false)

        await playEpisode(api: api, tabBar: tabBar)

        await ShotHarness.capture("done")
    }

    private static func navigation(_ tabBar: TabBarController) -> UINavigationController? {
        tabBar.selectedViewController as? UINavigationController
    }

    private static func scroll(_ viewController: UIViewController?, to offset: CGFloat) {
        guard let collection = (viewController as? UICollectionViewController)?.collectionView else { return }
        collection.setContentOffset(CGPoint(x: 0, y: offset - collection.adjustedContentInset.top), animated: false)
    }

    private static func playEpisode(api: APIClient, tabBar: TabBarController) async {
        guard let container = try? await api.requestContainer(.metadata(ratingKey: "4013")),
              let item = container.Metadata?.first else { return }
        tabBar.selectedIndex = 0
        await ShotHarness.settle(1)
        let coordinator = Theme.quickPlay(api: api, item: item, from: tabBar)
        _ = coordinator
        await ShotHarness.settle(5)
        let debugPath = "\(ShotHarness.signalDirectory)/player-debug.txt"
        var debug = "presented: \(String(describing: tabBar.presentedViewController))\n"
        if let scene = tabBar.view.window?.windowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
                try? "geometry error: \(error)".write(toFile: debugPath + ".err", atomically: true, encoding: .utf8)
            }
            debug += "scene orientation: \(scene.interfaceOrientation.rawValue)\n"
        }
        tabBar.presentedViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        tabBar.setNeedsUpdateOfSupportedInterfaceOrientations()
        await ShotHarness.settle(26)
        if let player = tabBar.presentedViewController as? AVPlayerViewController {
            player.player?.pause()
            player.showsPlaybackControls = false
            player.showsPlaybackControls = true
        }
        debug += "after: \(tabBar.view.window?.windowScene?.interfaceOrientation.rawValue ?? -1) bounds \(tabBar.view.window?.bounds ?? .zero)\n"
        try? debug.write(toFile: debugPath, atomically: true, encoding: .utf8)
        await ShotHarness.settle(1.5)
        await ShotHarness.capture("09-player")
        withExtendedLifetime(coordinator) {}
    }
}

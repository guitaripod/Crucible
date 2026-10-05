import UIKit
@testable import Crucible

@MainActor
enum ShotScript {
    static func run() async {
        guard let tabBar = await ShotHarness.waitForTabBar() else { return }
        await ShotHarness.settle(4)
        await ShotHarness.capture("01-home")

        tabBar.selectedIndex = 1
        await ShotHarness.settle(3.5)
        await ShotHarness.capture("02-library")

        tabBar.selectedIndex = 2
        await ShotHarness.settle(2.5)
        await ShotHarness.capture("03-downloads")

        tabBar.selectedIndex = 3
        await ShotHarness.settle(3)
        await ShotHarness.capture("04-you")

        await ShotHarness.capture("done")
    }
}

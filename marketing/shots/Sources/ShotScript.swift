import UIKit
@testable import Crucible

@MainActor
enum ShotScript {
    static func run() async {
        guard let tabBar = await ShotHarness.waitForTabBar() else { return }
        await ShotHarness.settle(3)
        await ShotHarness.capture("home")
        _ = tabBar
    }
}

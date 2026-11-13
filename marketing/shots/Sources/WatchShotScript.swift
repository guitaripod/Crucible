import UIKit
@testable import Crucible
@testable import CrucibleCore
import CrucibleDemo

/// The store's What to Watch and Previously On scenes, for capturing them in every app language without the whole
/// tour: picks for the second example request, and Paper Lanterns' last episodes written into a recap. The answers
/// are the ones the live model wrote for the demo library, which the mock server also serves, so each language shows
/// its own real answer and no capture calls the service.
@MainActor
enum WatchShotScript {
    private static let exampleShown = 1
    private static let show = "2005"

    /// Answers the harness's requests from the demo's prepared answers.
    static func prepare() {
        HostedBrain.install(DemoBrain())
    }

    static func run() async {
        guard let tabBar = await ShotHarness.waitForTabBar() else { return }
        let api = APIClient(baseURL: ServerBootstrap.connection()!.serverURI, token: "mock-token")
        await ShotHarness.settle(3)
        tabBar.select(.home)
        await ShotHarness.settle(1)
        let home = tabBar.selectedViewController as? UINavigationController
        let watch = WhatToWatchViewController(api: api)
        home?.pushViewController(watch, animated: false)
        await ShotHarness.settle(1.5)
        watch.view.endEditing(true)
        await ShotHarness.settle(0.8)
        await ShotHarness.capture("15a-what-to-watch-asking")
        button("watch.example.\(exampleShown)", in: watch.view)?.sendActions(for: .primaryActionTriggered)
        await ShotHarness.settle(7)
        await ShotHarness.capture("15-what-to-watch")
        home?.popToRootViewController(animated: false)
        await ShotHarness.settle(1)

        let model = try? await ShowDetailLoader.load(api: api, showRatingKey: show, initialSeasonKey: nil, selectedSeasonKey: { nil }, onShow: { _ in })
        if let model {
            home?.pushViewController(ShowDetailViewController(api: api, showRatingKey: show), animated: false)
            await ShotHarness.settle(4)
            PreviouslyOnViewController.present(for: model, from: tabBar)
            await ShotHarness.settle(2)
            await ShotHarness.capture("16a-previously-on-descriptions")
            if let sheet = tabBar.presentedViewController {
                button("previouslyOn.write", in: sheet.view)?.sendActions(for: .primaryActionTriggered)
            }
            await ShotHarness.settle(4)
            await ShotHarness.capture("16-previously-on")
        }
        await ShotHarness.capture("done")
    }

    private static func button(_ identifier: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier { return button }
        for subview in view.subviews {
            if let found = button(identifier, in: subview) { return found }
        }
        return nil
    }
}

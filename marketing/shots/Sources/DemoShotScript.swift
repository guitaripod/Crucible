import AVKit
import UIKit
@testable import Crucible
@testable import CrucibleCore
import CrucibleDesign
#if canImport(CrucibleDemo)
import CrucibleDemo
#endif

/// A demo library that starts slowly and fails its first start, so the capture can show the progress state and the failure alert before
/// the demo opens.
actor ScriptedDemoProvider: DemoProviding {
    private let base: any DemoProviding
    private let startDelay: Duration
    private var failuresLeft: Int

    init(base: any DemoProviding, startDelay: Duration, failures: Int) {
        self.base = base
        self.startDelay = startDelay
        self.failuresLeft = failures
    }

    func start() async throws -> DemoEndpoint {
        try await Task.sleep(for: startDelay)
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw DemoError.unavailable
        }
        return try await base.start()
    }

    func stop() async {
        await base.stop()
    }
}

/// Walks the demo from the Welcome screen to leaving it and back, capturing every state a reviewer or a new user sees. Run it twice in
/// the same simulator (the second time with CRUCIBLE_SHOT_SCRIPT=demo-resume and the install kept) to see the demo come back after a relaunch.
@MainActor
enum DemoShotScript {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static func prepare(mock: URL) {
        let base: any DemoProviding
        #if canImport(CrucibleDemo)
        if environment["CRUCIBLE_SHOT_DEMO_LIBRARY"] == "real" {
            base = DemoLibraryProvider()
        } else {
            base = DemoMockProvider(environment: [DemoMockProvider.environmentVariable: mock.absoluteString])!
        }
        #else
        base = DemoMockProvider(environment: [DemoMockProvider.environmentVariable: mock.absoluteString])!
        #endif
        let resuming = environment["CRUCIBLE_SHOT_SCRIPT"] == "demo-resume"
        DemoMode.shared.install(ScriptedDemoProvider(base: base, startDelay: resuming ? .milliseconds(1500) : .seconds(2.5), failures: resuming ? 0 : 1))
    }

    static func run() async {
        if environment["CRUCIBLE_SHOT_SCRIPT"] == "demo-resume" {
            await resumeAfterRelaunch()
        } else {
            await enterAndTour()
        }
        await ShotHarness.capture("done")
    }

    private static func enterAndTour() async {
        guard await waitForWelcome() != nil else { return }
        await ShotHarness.settle(1.5)
        await ShotHarness.capture("d00-welcome")

        press("Try the demo", in: welcome())
        await ShotHarness.settle(0.9)
        await ShotHarness.capture("d01-starting")
        await ShotHarness.settle(2.6)
        await ShotHarness.capture("d02-failure")
        invoke("Try Again", on: topPresented() as? UIAlertController)
        await ShotHarness.settle(0.4)

        guard let tabBar = await ShotHarness.waitForTabBar() else { return }
        await ShotHarness.settle(3.5)
        await ShotHarness.capture("d03-intro")
        if let intro = topPresented() as? DemoIntroViewController {
            await extraLargeText(on: intro, name: "d03b-intro-xl")
        }
        press("Start exploring", in: topPresented())
        await ShotHarness.settle(1.2)
        await ShotHarness.capture("d04-home")

        let you = tabBar.open(.you)
        await ShotHarness.settle(1.5)
        await ShotHarness.capture("d05-you")
        openTour(you)
        await ShotHarness.settle(1)
        await ShotHarness.capture("d06-tour-0")

        DemoCoordinator.shared.show(.play)
        await ShotHarness.settle(5)
        await ShotHarness.capture("d07-playing")
        await dismissEverything(tabBar)

        DemoCoordinator.shared.show(.browse)
        await ShotHarness.settle(5)
        await ShotHarness.capture("d08-library")

        openTour(tabBar.open(.you))
        await ShotHarness.settle(1)
        await ShotHarness.capture("d09-tour-partial")

        DemoCoordinator.shared.show(.search)
        await ShotHarness.settle(3)
        await ShotHarness.capture("d10-search")

        DemoCoordinator.shared.show(.statistics)
        await ShotHarness.settle(14)
        await ShotHarness.capture("d11-stats")
        await ShotHarness.settle(3)
        await ShotHarness.capture("d12-finale")
        if let finale = topPresented() as? DemoFinaleViewController {
            await extraLargeText(on: finale, name: "d12b-finale-xl")
            press("See Crucible Pro", in: finale.view)
            await ShotHarness.settle(3)
            await ShotHarness.capture("d13-paywall-from-finale")
            press("Close", in: topPresented(), accessibilityLabel: true)
            await ShotHarness.settle(1.5)
            press("Keep exploring", in: topPresented())
            await ShotHarness.settle(1.5)
        }

        DemoCoordinator.shared.show(.poster)
        await ShotHarness.settle(16)
        await ShotHarness.capture("d14-poster")
        await dismissEverything(tabBar)

        DemoCoordinator.shared.show(.download)
        await ShotHarness.settle(4)
        await ShotHarness.capture("d15-downloads")

        let youAgain = tabBar.open(.you)
        openTour(youAgain)
        await ShotHarness.settle(1.2)
        await ShotHarness.capture("d16-tour-done")
        await extraLargeTextOnTour(youAgain, name: "d16b-tour-xl")

        let api = tabBar.api
        youAgain?.popToRootViewController(animated: false)
        youAgain?.pushViewController(SettingsViewController(api: api), animated: false)
        await ShotHarness.settle(2)
        await ShotHarness.capture("d17-settings")
        scrollToBottom(youAgain?.topViewController)
        await ShotHarness.settle(1)
        await ShotHarness.capture("d17b-settings-bottom")
        guard environment["CRUCIBLE_DEMO_STAY"] != "1" else { return }
        await leaveFromTour(tabBar)
    }

    /// Closes whatever sits over the tab bar, the player included, until nothing does.
    private static func dismissEverything(_ tabBar: UIViewController) async {
        for _ in 0..<6 {
            guard let presented = tabBar.presentedViewController else { return }
            (presented as? AVPlayerViewController)?.player?.pause()
            tabBar.dismiss(animated: false)
            await ShotHarness.settle(1)
        }
    }

    private static func resumeAfterRelaunch() async {
        guard let tabBar = await ShotHarness.waitForTabBar() else { return }
        await ShotHarness.settle(3)
        await ShotHarness.capture("r00-resumed-home")
        let you = tabBar.open(.you)
        await ShotHarness.settle(1.5)
        openTour(you)
        await ShotHarness.settle(1)
        await ShotHarness.capture("r01-resumed-tour")
        await leaveFromTour(tabBar)
    }

    private static func leaveFromTour(_ tabBar: TabBarController) async {
        let you = tabBar.open(.you)
        openTour(you)
        await ShotHarness.settle(1)
        guard let tour = you?.topViewController as? DemoTourViewController else { return }
        DemoCoordinator.shared.confirmLeaving(from: tour)
        await ShotHarness.settle(1)
        await ShotHarness.capture("d18-leave-confirm")
        invoke("Leave the demo", on: topPresented() as? UIAlertController)
        await ShotHarness.settle(3)
        await ShotHarness.capture("d19-welcome-again")
    }

    private static func extraLargeTextOnTour(_ you: UINavigationController?, name: String) async {
        guard let tour = you?.topViewController else { return }
        await extraLargeText(on: tour, name: name)
    }

    private static func extraLargeText(on controller: UIViewController, name: String) async {
        let window = controller.view.window
        window?.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
        await ShotHarness.settle(1.2)
        await ShotHarness.capture(name)
        window?.traitOverrides.preferredContentSizeCategory = .large
        await ShotHarness.settle(0.8)
    }

    private static func openTour(_ you: UINavigationController?) {
        guard let root = you?.viewControllers.first as? YouViewController else { return }
        root.collectionView(root.collectionView, didSelectItemAt: IndexPath(item: 0, section: 0))
    }

    private static func welcome() -> UIView? {
        ((ShotHarness.rootWindow?.rootViewController as? UINavigationController)?.topViewController as? ServerSetupViewController)?.view
    }

    private static func waitForWelcome() async -> UIView? {
        for _ in 0..<300 {
            if let view = welcome(), view.window != nil { return view }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    private static func topPresented() -> UIViewController? {
        var top = ShotHarness.rootWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private static func all<T: UIView>(_ type: T.Type, in view: UIView?) -> [T] {
        guard let view else { return [] }
        let own: [T] = (view as? T).map { [$0] } ?? []
        return own + view.subviews.flatMap { all(type, in: $0) }
    }

    private static func press(_ title: String, in view: UIView?, accessibilityLabel: Bool = false) {
        let button = all(UIButton.self, in: view).first {
            accessibilityLabel ? $0.accessibilityLabel == title : ($0.configuration?.title ?? "").contains(title)
        }
        button?.sendActions(for: .primaryActionTriggered)
    }

    private static func press(_ title: String, in controller: UIViewController?, accessibilityLabel: Bool = false) {
        press(title, in: controller?.view, accessibilityLabel: accessibilityLabel)
    }

    private static func invoke(_ title: String, on alert: UIAlertController?) {
        guard let alert, let action = alert.actions.first(where: { $0.title == title }) else { return }
        let handler = action.value(forKey: "handler")
        alert.dismiss(animated: false) {
            typealias Handler = @convention(block) (UIAlertAction) -> Void
            if let handler { unsafeBitCast(handler as AnyObject, to: Handler.self)(action) }
        }
    }

    private static func scrollToBottom(_ controller: UIViewController?) {
        guard let collection = (controller as? UICollectionViewController)?.collectionView else { return }
        collection.layoutIfNeeded()
        let bottom = collection.contentSize.height - collection.bounds.height + collection.adjustedContentInset.bottom
        collection.setContentOffset(CGPoint(x: 0, y: max(-collection.adjustedContentInset.top, bottom)), animated: false)
    }
}

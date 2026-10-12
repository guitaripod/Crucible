import UIKit
@testable import Crucible
@testable import CrucibleCore
import CrucibleDesign
@testable import CrucibleStats

/// A store that loads offers but fails every purchase, which the scripted store cannot do (its `fail` mode fails the offers too).
actor FailingPurchaseAccess: ProAccessProviding {
    nonisolated let isStoreBacked = true
    private let base = ScriptedProAccess(status: .free, store: .ok, delay: .milliseconds(300))

    func cachedStatus() async -> ProStatus { .free }
    func refreshStatus() async -> ProStatus? { .free }
    nonisolated func statusUpdates() -> AsyncStream<ProStatus> { AsyncStream { _ in } }
    func loadOffers() async throws -> [ProOffer] { try await base.loadOffers() }
    func purchase(offerID: String) async -> ProPurchaseOutcome {
        try? await Task.sleep(for: .milliseconds(300))
        return .failed(ProStoreFailure(.unknown))
    }
    func restore() async -> ProRestoreOutcome { .failed(ProStoreFailure(.storeUnavailable)) }
    func managementURL() async -> URL? { nil }
}

/// Drives the Crucible Pro screens through every state with the scripted store and captures each one.
@MainActor
enum ProShotScript {
    private static var access: ProAccess { .shared }

    static func run() async {
        guard let tabBar = await ShotHarness.waitForTabBar() else { return }
        let api = APIClient(baseURL: ServerBootstrap.connection()!.serverURI, token: "mock-token")
        await ShotHarness.settle(5)
        tabBar.selectedIndex = 3
        await ShotHarness.settle(1.5)
        let you = tabBar.selectedViewController as? UINavigationController

        await paywallStates(tabBar: tabBar)
        await settingsAndStatus(you: you, api: api)
        await statisticsLocks(you: you, api: api, tabBar: tabBar)
        await downloadLocks(you: you, api: api, tabBar: tabBar)
        await ShotHarness.capture("done")
    }

    private static func install(_ provider: any ProAccessProviding) async {
        access.install(provider)
        access.start()
        await ShotHarness.settle(0.8)
    }

    private static func scripted(_ status: ProStatus = .free, store: ScriptedProAccess.StoreBehavior = .ok, restore: ScriptedProAccess.RestoreBehavior = .none, trial: Bool = true, delayMs: Int = 300) -> ScriptedProAccess {
        ScriptedProAccess(status: status, store: store, restore: restore, trialEligible: trial, delay: .milliseconds(delayMs))
    }

    private static var lifetime: ProStatus { .pro(ProEntitlement(kind: .lifetime, productIdentifier: ScriptedProAccess.lifetimeID)) }
    private static var annual: ProStatus {
        .pro(ProEntitlement(kind: .subscription, productIdentifier: ScriptedProAccess.annualID, expiresAt: Date().addingTimeInterval(86_400 * 300), willRenew: true))
    }
    private static var trialing: ProStatus {
        .pro(ProEntitlement(kind: .subscription, productIdentifier: ScriptedProAccess.annualID, expiresAt: Date().addingTimeInterval(86_400 * 12), willRenew: true, isTrial: true))
    }

    private static func topPresented(_ root: UIViewController?) -> UIViewController? {
        var top = root
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private static func paywall(_ tabBar: UIViewController) -> PaywallViewController? {
        topPresented(tabBar) as? PaywallViewController
    }

    private static func all<T: UIView>(_ type: T.Type, in view: UIView?) -> [T] {
        guard let view else { return [] }
        let own: [T] = (view as? T).map { [$0] } ?? []
        return own + view.subviews.flatMap { all(type, in: $0) }
    }

    private static func closePaywall(_ tabBar: UIViewController) async {
        if let paywall = paywall(tabBar) {
            if let close = all(UIButton.self, in: paywall.view).first(where: { $0.accessibilityLabel == "Close" }) {
                close.sendActions(for: .primaryActionTriggered)
            }
        }
        await ShotHarness.settle(1.2)
    }

    private static func selectOffer(_ kind: ProOffer.Kind, tabBar: UIViewController) async {
        guard let paywall = paywall(tabBar),
              let card = all(PaywallOfferCardView.self, in: paywall.view).first(where: { $0.offer.kind == kind }) else { return }
        card.sendActions(for: .primaryActionTriggered)
        await ShotHarness.settle(0.6)
    }

    private static func press(_ title: String, tabBar: UIViewController) {
        guard let paywall = paywall(tabBar) else { return }
        let button = all(UIButton.self, in: paywall.view).first { ($0.configuration?.title ?? "").contains(title) }
        button?.sendActions(for: .primaryActionTriggered)
    }

    private static func paywallStates(tabBar: TabBarController) async {
        access.requestUnlock(.fullStatistics)
        await ShotHarness.settle(0.7)
        await ShotHarness.capture("p00-loading")
        await ShotHarness.settle(3.2)
        await ShotHarness.capture("p01-ready-lifetime")
        await selectOffer(.annual, tabBar: tabBar)
        await ShotHarness.capture("p01b-ready-annual")
        await selectOffer(.lifetime, tabBar: tabBar)
        await ShotHarness.capture("iap-review-lifetime")
        await selectOffer(.annual, tabBar: tabBar)
        await ShotHarness.capture("iap-review-annual")
        if let paywall = paywall(tabBar) {
            paywall.view.window?.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
            await ShotHarness.settle(1.2)
            await ShotHarness.capture("p01c-accessibility-xl")
            paywall.view.window?.traitOverrides.preferredContentSizeCategory = .large
            await ShotHarness.settle(0.8)
        }
        await closePaywall(tabBar)

        await install(scripted(trial: false))
        access.requestUnlock(.unlimitedDownloads)
        await ShotHarness.settle(2)
        await selectOffer(.annual, tabBar: tabBar)
        await ShotHarness.capture("p02-ready-notrial-annual")
        await closePaywall(tabBar)

        await install(scripted(store: .cancel, delayMs: 3500))
        access.requestUnlock(nil)
        await ShotHarness.settle(4.2)
        press("Unlock for", tabBar: tabBar)
        await ShotHarness.settle(1)
        await ShotHarness.capture("p03-purchasing")
        await ShotHarness.settle(3.5)
        await closePaywall(tabBar)

        await install(scripted(store: .pending))
        access.requestUnlock(.yearInReviewPoster)
        await ShotHarness.settle(1.6)
        press("Unlock for", tabBar: tabBar)
        await ShotHarness.settle(1.4)
        await ShotHarness.capture("p04-pending")
        await closePaywall(tabBar)

        await install(FailingPurchaseAccess())
        access.requestUnlock(.fullStatistics)
        await ShotHarness.settle(1.6)
        press("Unlock for", tabBar: tabBar)
        await ShotHarness.settle(1.4)
        await ShotHarness.capture("p05-failure")
        press("Restore Purchases", tabBar: tabBar)
        await ShotHarness.settle(1.4)
        await ShotHarness.capture("p05b-restore-failed")
        await closePaywall(tabBar)

        await install(scripted(restore: .none))
        access.requestUnlock(.fullStatistics)
        await ShotHarness.settle(1.6)
        press("Restore Purchases", tabBar: tabBar)
        await ShotHarness.settle(0.6)
        await ShotHarness.capture("p06a-restoring")
        await ShotHarness.settle(1)
        await ShotHarness.capture("p06-nothing-to-restore")
        await closePaywall(tabBar)

        await install(scripted(store: .offline))
        access.requestUnlock(.fullStatistics)
        await ShotHarness.settle(1.8)
        await ShotHarness.capture("p07-unavailable-offline")
        await closePaywall(tabBar)

        await install(scripted(store: .empty))
        access.requestUnlock(nil)
        await ShotHarness.settle(1.8)
        await ShotHarness.capture("p07b-unavailable-region")
        await closePaywall(tabBar)
    }

    private static func settingsAndStatus(you: UINavigationController?, api: APIClient) async {
        await install(scripted())
        let settings = SettingsViewController(api: api)
        you?.pushViewController(settings, animated: false)
        await ShotHarness.settle(2)
        await ShotHarness.capture("p08-settings-free")

        await install(scripted(annual))
        await ShotHarness.settle(1)
        await ShotHarness.capture("p08b-settings-pro")
        you?.pushViewController(ProStatusViewController(), animated: false)
        await ShotHarness.settle(1.5)
        await ShotHarness.capture("p09-pro-status-annual")
        you?.popToRootViewController(animated: false)

        await install(scripted(lifetime))
        you?.pushViewController(ProStatusViewController(), animated: false)
        await ShotHarness.settle(1.5)
        await ShotHarness.capture("p09b-pro-status-lifetime")
        you?.popToRootViewController(animated: false)

        await install(scripted(trialing))
        you?.pushViewController(ProStatusViewController(), animated: false)
        await ShotHarness.settle(1.5)
        await ShotHarness.capture("p09c-pro-status-trial")
        you?.popToRootViewController(animated: false)
    }

    private static func statisticsLocks(you: UINavigationController?, api: APIClient, tabBar: TabBarController) async {
        await install(scripted())
        you?.pushViewController(StatisticsViewController(api: api), animated: false)
        await ShotHarness.settle(14)
        await ShotHarness.capture("p10-stats-locked")
        let stats = you?.topViewController as? StatisticsViewController
        stats?.selectRange(.month)
        await ShotHarness.settle(2.2)
        await ShotHarness.capture("p11-paywall-from-stats")
        press("Unlock for", tabBar: tabBar)
        await ShotHarness.settle(1.2)
        await ShotHarness.capture("p11b-purchasing-from-stats")
        await ShotHarness.settle(3)
        await ShotHarness.capture("p12-stats-after-unlock")
        you?.popToRootViewController(animated: false)
        await ShotHarness.settle(0.5)
    }

    private static func downloadLocks(you: UINavigationController?, api: APIClient, tabBar: TabBarController) async {
        await install(scripted())
        tabBar.selectedIndex = 0
        await ShotHarness.settle(1)
        let home = tabBar.selectedViewController as? UINavigationController
        home?.pushViewController(ShowDetailViewController(api: api, showRatingKey: "2001"), animated: false)
        await ShotHarness.settle(4)
        var episodes = [PlexMetadata]()
        for key in ["4001", "4002", "4003"] {
            if let item = try? await api.requestContainer(.metadata(ratingKey: key)).Metadata?.first { episodes.append(item) }
        }
        DownloadManager.shared.requestDownloads(episodes)
        await ShotHarness.settle(2.2)
        await ShotHarness.capture("p13-download-batch-paywall")
        press("Restore Purchases", tabBar: tabBar)
        await ShotHarness.settle(1.6)
        await closePaywall(tabBar)

        let context = DownloadOptionsSheetViewController.Context(
            showRatingKey: "2001", showTitle: "Show", seasonTitle: "Season 1", posterPath: nil, episodes: episodes
        )
        let sheet = DownloadOptionsSheetViewController(context: context) {}
        home?.present(sheet, animated: false)
        await ShotHarness.settle(1.5)
        await ShotHarness.capture("p14-download-options-locked")
        if let keep = all(UISwitch.self, in: sheet.view).first(where: { $0.accessibilityLabel?.hasPrefix("Keep next") == true }) {
            keep.isOn = true
            keep.sendActions(for: .valueChanged)
        }
        await ShotHarness.settle(2)
        await ShotHarness.capture("p14b-download-options-paywall")
        await closePaywall(tabBar)
        sheet.dismiss(animated: false)
        await ShotHarness.settle(0.5)
        home?.popToRootViewController(animated: false)
    }
}

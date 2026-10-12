import CrucibleCore
import CrucibleDesign
import UIKit

/// The Crucible Pro screen of a Pro user: the plan on the left with how to manage or cancel a subscription (Apple TV cannot
/// open the subscriptions page) and the legal pages as text, what Pro unlocks and Restore Purchases on the right. Free users
/// never see it: their row in You opens the paywall.
final class TVProViewController: TVSettingsScaffold {
    private enum RowID {
        static let restore = "pro.restore"

        static func feature(_ feature: ProFeature) -> String {
            "pro.feature.\(feature.rawValue)"
        }
    }

    private let heading = TVSettingsHeading(title: "Crucible Pro")
    private let managePanel = TVProViewController.makeManagePanel()
    private lazy var restoreSlot = makeTaskSlot()
    private var isRestoring = false
    private var proObserver: UUID?

    override init() {
        super.init()
        title = "Crucible Pro"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let proObserver {
            Task { @MainActor in ProAccess.shared.stopObserving(proObserver) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installContext(makeContext())
        proObserver = ProAccess.shared.observe { [weak self] _ in self?.statusChanged() }
        refresh()
    }

    override func rowDidSelect(_ id: String) {
        guard id == RowID.restore else { return }
        restore()
    }

    private func statusChanged() {
        guard ProAccess.shared.isPro else {
            TVNavigation.pop(from: self)
            return
        }
        refresh()
    }

    private func refresh() {
        let entitlement = ProAccess.shared.status.entitlement
        heading.setBody(entitlement?.summary())
        managePanel.isHidden = entitlement?.kind != .subscription
        var rows = ProFeature.listed(isTV: true).map { feature in
            TVRowItem(id: RowID.feature(feature), title: feature.title, subtitle: feature.summary, symbol: feature.symbol, accessory: .checkmark)
        }
        rows.insert(
            TVRowItem(id: RowID.restore, title: "Restore Purchases", value: isRestoring ? "Restoring\u{2026}" : nil, symbol: "arrow.clockwise"),
            at: 0
        )
        setRows(rows)
    }

    /// Asks the store for the purchases of this Apple Account and says how it ended; a second press while it runs does nothing.
    private func restore() {
        guard !isRestoring else { return }
        isRestoring = true
        refresh()
        restoreSlot.run { [weak self] in
            let access = ProAccess.shared
            let outcome = await access.provider.restore()
            if outcome == .restored { await access.refreshNow() }
            guard !Task.isCancelled, let self else { return }
            isRestoring = false
            refresh()
            let alert = ProTVPresentation.restoreAlert(for: outcome, isPro: access.isPro)
            presentAlert(title: alert.title, message: alert.message)
        }
    }

    private func makeContext() -> UIView {
        let stack = UIStackView(arrangedSubviews: [heading, managePanel, TVPaywallInfoColumn.legalPanel()])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = Theme.Space.l
        return stack
    }

    private static func makeManagePanel() -> TVReadOnlyPanel {
        let label = UILabel()
        label.text = ProTVPresentation.manageSubscriptionText
        label.font = TVFont.cardSubtitle
        label.textColor = Theme.Color.labelSecondary
        label.numberOfLines = 0
        let panel = TVReadOnlyPanel(wrapping: label) { ProTVPresentation.manageSubscriptionText }
        panel.accessibilityIdentifier = "pro.manage"
        return panel
    }
}

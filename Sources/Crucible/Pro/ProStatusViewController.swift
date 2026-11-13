import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// What a Pro install sees under Settings > Crucible Pro: the plan and when it renews or ends, what Pro gives them, told with
/// their own numbers where the app has enough of them, the way to manage a subscription, restoring purchases and the legal
/// pages. It follows `ProAccess` live and steps back when Pro ends.
final class ProStatusViewController: UICollectionViewController {
    enum Section: Hashable {
        case plan, included, manage, legal
    }

    enum Item: Hashable {
        case plan, feature(ProFeature), manageSubscription, restore, terms, privacy
    }

    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var observation: ProObservation?
    private var restoreModel: PaywallModel?
    private var isRestoring = false
    private var details: [ProFeature: String] = [:]

    init() {
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Crucible Pro"
        navigationItem.largeTitleDisplayMode = .never
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.allowsKeyboardFocus()
        collectionView.showsVerticalScrollIndicator = false
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { _, environment in
            let listSection = NSCollectionLayoutSection.list(using: UICollectionLayoutListConfiguration.wellRows(), layoutEnvironment: environment)
            Theme.centerReadable(listSection, environment)
            return listSection
        }
        configureDataSource()
        applySnapshot()
        observation = ProObservation { [weak self] in self?.statusChanged() }
    }

    private var entitlement: ProEntitlement? { ProAccess.shared.status.entitlement }

    private func statusChanged() {
        guard ProAccess.shared.isPro else {
            navigationController?.popViewController(animated: true)
            return
        }
        applySnapshot()
    }

    private func applySnapshot() {
        details = ProPersonalDetails.make(.live)
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.plan])
        snapshot.appendItems([.plan], toSection: .plan)
        snapshot.appendSections([.included])
        snapshot.appendItems(ProFeature.listed(isTV: false, includingRequests: SeerrAccount.shared.managesRequests).map(Item.feature), toSection: .included)
        snapshot.appendSections([.manage])
        var manage: [Item] = []
        if entitlement?.kind == .subscription { manage.append(.manageSubscription) }
        manage.append(.restore)
        snapshot.appendItems(manage, toSection: .manage)
        snapshot.appendSections([.legal])
        snapshot.appendItems([.terms, .privacy], toSection: .legal)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { dataSource.snapshot().itemIdentifiers.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            cell.accessories = []
            cell.applyThemedBackground()
            switch item {
            case .plan:
                let productName = "Crucible Pro"
                cell.contentConfiguration = IconRowContentConfiguration(
                    symbol: "sparkles", title: productName, subtitle: self?.entitlement?.summary(), value: String(localized: "Active")
                )
            case .feature(let feature):
                cell.contentConfiguration = IconRowContentConfiguration(
                    symbol: feature.symbol, title: feature.title, subtitle: feature.summary(in: self?.details ?? [:])
                )
                cell.accessories = [.checkmark()]
            case .manageSubscription:
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "creditcard", title: String(localized: "Manage Subscription"))
            case .restore:
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "arrow.clockwise", title: String(localized: "Restore Purchases"))
                if self?.isRestoring == true {
                    let spinner = UIActivityIndicatorView(style: .medium)
                    spinner.startAnimating()
                    cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .trailing()))]
                }
            case .terms:
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "doc.text", title: String(localized: "Terms of Use"))
            case .privacy:
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "hand.raised", title: String(localized: "Privacy Policy"))
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return false }
        switch item {
        case .plan, .feature: return false
        case .restore: return !isRestoring
        case .manageSubscription, .terms, .privacy: return true
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .plan, .feature: break
        case .manageSubscription: UIApplication.shared.open(ProLinks.manageSubscriptions)
        case .restore: restorePurchases()
        case .terms: UIApplication.shared.open(ProLinks.termsOfUse)
        case .privacy: UIApplication.shared.open(ProLinks.privacyPolicy)
        }
    }

    private func restorePurchases() {
        guard restoreModel == nil else { return }
        Haptics.selection()
        let model = PaywallModel()
        restoreModel = model
        model.onChange = { [weak self] state in
            self?.setRestoring(state.busy == .restoring)
            if let notice = state.notice { self?.showRestoreResult(notice: notice) }
        }
        model.onFinish = { [weak self] unlocked in
            guard unlocked else { return }
            self?.showRestoreSucceeded()
        }
        model.restore()
    }

    private func setRestoring(_ restoring: Bool) {
        guard restoring != isRestoring else { return }
        isRestoring = restoring
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([.restore])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func showRestoreSucceeded() {
        restoreModel = nil
        Haptics.success()
        presentAlert(title: String(localized: "Purchases Restored"), message: String(localized: "Crucible Pro is active on this device."))
    }

    private func showRestoreResult(notice: PaywallModel.Notice) {
        restoreModel = nil
        let title: String
        switch notice {
        case .nothingToRestore: title = String(localized: "Nothing to Restore")
        case .pending: title = String(localized: "Waiting for Approval")
        case .failure: title = String(localized: "Restore Failed")
        }
        if case .failure = notice { Haptics.error() }
        presentAlert(title: title, message: PaywallModel.message(for: notice))
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }
}

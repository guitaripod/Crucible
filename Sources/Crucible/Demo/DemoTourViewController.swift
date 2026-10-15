import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// The demo tour: the things worth trying with a check on each one done, a "Show me" that jumps to the right place for every step, and
/// the ways out of the demo (a real server, the Crucible Pro offer, or leaving).
final class DemoTourViewController: UICollectionViewController {
    enum Section: Int, CaseIterable {
        case progress, steps, actions, leave

        var title: String? {
            self == .steps ? DemoPhoneCopy.thingsToTry : nil
        }
    }

    enum Item: Hashable {
        case progress
        case step(DemoTourStep)
        case connect
        case pro
        case leave
    }

    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var observation: DemoObservation?

    init() {
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = DemoCopy.tourTitle
        navigationItem.largeTitleDisplayMode = .always
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.showsVerticalScrollIndicator = false
        collectionView.collectionViewLayout = makeLayout()
        configureDataSource()
        applySnapshot()
        observation = DemoObservation { [weak self] in self?.demoChanged() }
    }

    private func demoChanged() {
        guard DemoMode.shared.isActive else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            var config = UICollectionLayoutListConfiguration.wellRows()
            let section = self?.dataSource?.sectionIdentifier(for: index)
            config.headerMode = section?.title == nil ? .none : .supplementary
            if section == .leave {
                config.itemSeparatorHandler = nil
            }
            if section == .progress {
                config.itemSeparatorHandler = { _, separator in
                    var separator = separator
                    separator.bottomSeparatorVisibility = .hidden
                    return separator
                }
            }
            return NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems([.progress], toSection: .progress)
        snapshot.appendItems(DemoTour.shared.steps.map { .step($0) }, toSection: .steps)
        snapshot.appendItems([.connect, .pro], toSection: .actions)
        snapshot.appendItems([.leave], toSection: .leave)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func row(for step: DemoTourStep) -> DemoPhoneTourRow? {
        DemoPhoneTourPlan.rows(steps: DemoTour.shared.steps, completed: DemoTour.shared.completed).first { $0.step == step }
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            cell.accessories = []
            cell.applyThemedBackground()
            cell.isAccessibilityElement = false
            switch item {
            case .progress:
                let steps = DemoTour.shared.steps
                let completed = DemoTour.shared.completed
                cell.contentConfiguration = DemoProgressContentConfiguration(
                    progressText: DemoPhoneTourPlan.progress(steps: steps, completed: completed),
                    fraction: steps.isEmpty ? 0 : Double(completed.count) / Double(steps.count),
                    caption: DemoPhoneCopy.tourFooter
                )
            case .step(let step):
                guard let row = row(for: step) else { return }
                cell.contentConfiguration = DemoStepContentConfiguration(row: row)
                cell.isAccessibilityElement = true
                cell.accessibilityLabel = row.accessibilityLabel
                cell.accessibilityHint = DemoPhoneCopy.showMe
                cell.accessibilityTraits = .button
                cell.accessibilityIdentifier = "demo.step.\(step.rawValue)"
            case .connect:
                cell.contentConfiguration = IconRowContentConfiguration(
                    symbol: "server.rack", title: DemoCopy.connectTitle, subtitle: DemoCopy.connectBody
                )
                cell.accessories = [.disclosureIndicator()]
            case .pro:
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "sparkles", title: DemoCopy.finalePro)
                cell.accessories = [.disclosureIndicator()]
                cell.accessibilityIdentifier = "demo.pro"
            case .leave:
                var content = UIListContentConfiguration.cell()
                content.text = DemoPhoneCopy.leaveTitle
                content.textProperties.color = Theme.Color.destructive
                content.textProperties.font = Theme.Font.headline
                content.textProperties.alignment = .center
                content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
                cell.contentConfiguration = content
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section)?.title
            content.textProperties.transform = .uppercase
            content.textProperties.font = Theme.Font.footnoteSemibold
            content.textProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
            cell.accessibilityTraits = .header
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) != .progress
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .progress:
            break
        case .step(let step):
            Haptics.selection()
            DemoCoordinator.shared.show(step)
        case .connect, .leave:
            DemoCoordinator.shared.confirmLeaving(from: self)
        case .pro:
            PaywallPresenter.showOffer(from: self)
        }
    }
}

/// Keeps a screen in step with the demo: the tour moving on, or the demo starting and ending. It stops listening when the screen goes.
@MainActor
final class DemoObservation {
    private var tourToken: UUID?
    private var modeToken: UUID?

    init(_ handler: @escaping @MainActor () -> Void) {
        tourToken = DemoTour.shared.observe { handler() }
        modeToken = DemoMode.shared.observe { _ in handler() }
    }

    deinit {
        let tourToken = tourToken
        let modeToken = modeToken
        Task { @MainActor in
            if let tourToken { DemoTour.shared.stopObserving(tourToken) }
            if let modeToken { DemoMode.shared.stopObserving(modeToken) }
        }
    }
}

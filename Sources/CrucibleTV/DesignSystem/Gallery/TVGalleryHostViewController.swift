#if DEBUG
import CrucibleDesign
import UIKit

/// `CRUCIBLE_GALLERY=host`: a navigation stack of `TVScreenViewController`s that exercises the shared
/// host. The root lists scenarios; each pushes a demo screen (loading forever, an error that recovers
/// through Retry, plain content) so UI tests can check that Menu pops while loading, that focus
/// returns to the same card after the list shifts, and that two quick pushes make one screen.
final class TVGalleryHostRootViewController: TVScreenViewController {
    private enum Scenario: String, CaseIterable {
        case loading
        case error
        case content
        case doublePush

        var title: String {
            switch self {
            case .loading: "Loading screen"
            case .error: "Error screen"
            case .content: "Content screen"
            case .doublePush: "Double push"
            }
        }

        var subtitle: String {
            switch self {
            case .loading: "Menu must pop it"
            case .error: "Try Again recovers"
            case .content: "Focus survives a reload"
            case .doublePush: "Two pushes, one screen"
            }
        }
    }

    private var dataSource: UICollectionViewDiffableDataSource<Int, TVRowItem>!

    init() {
        super.init(layout: UICollectionViewLayout())
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { _, environment in
            let section = TVRowList.section(environment: environment)
            let trailing = max(0, environment.container.effectiveContentSize.width - TVMetrics.Column.form)
            section.contentInsets = NSDirectionalEdgeInsets(top: TVMetrics.tabBarClearance, leading: 0, bottom: TVMetrics.shelfBottomInset, trailing: trailing)
            return section
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let row = TVRowCell.registration()
        dataSource = UICollectionViewDiffableDataSource<Int, TVRowItem>(collectionView: collectionView) { collectionView, indexPath, item in
            let cell = collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: item)
            cell.accessibilityIdentifier = "host.row.\(item.id)"
            return cell
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, TVRowItem>()
        snapshot.appendSections([0])
        snapshot.appendItems(Scenario.allCases.map {
            TVRowItem(id: $0.rawValue, title: $0.title, subtitle: $0.subtitle, accessory: .chevron)
        })
        dataSource.apply(snapshot, animatingDifferences: false)
        adopt(dataSource)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath), let scenario = Scenario(rawValue: item.id) else { return }
        switch scenario {
        case .loading: TVNavigation.push(TVGalleryHostDemoViewController(mode: .loading), from: self)
        case .error: TVNavigation.push(TVGalleryHostDemoViewController(mode: .error), from: self)
        case .content: TVNavigation.push(TVGalleryHostDemoViewController(mode: .content), from: self)
        case .doublePush:
            TVNavigation.push(TVGalleryDepthViewController(), from: self)
            TVNavigation.push(TVGalleryDepthViewController(), from: self)
        }
    }
}

final class TVGalleryHostDemoViewController: TVScreenViewController {
    enum Mode {
        case loading
        case error
        case content
    }

    private let mode: Mode
    private var dataSource: UICollectionViewDiffableDataSource<Int, TVCardItem>!
    private var items = (0..<10).map { TVGalleryHostDemoViewController.item(id: "item.\($0)", title: "Item \($0)") }
    private lazy var loadSlot = makeTaskSlot()

    init(mode: Mode) {
        self.mode = mode
        super.init(layout: UICollectionViewLayout())
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { _, _ in
            let section = TVShelf.poster(header: false)
            section.contentInsets = NSDirectionalEdgeInsets(top: TVMetrics.tabBarClearance, leading: 0, bottom: TVMetrics.shelfBottomInset, trailing: 0)
            return section
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    fileprivate static func item(id: String, title: String) -> TVCardItem {
        TVCardItem(id: id, artworkPath: TVGalleryFixtures.art("poster", id), title: title, subtitle: id)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        TVImagePipeline.provider = TVGalleryArt.provider
        let poster = TVPosterCell.registration()
        dataSource = UICollectionViewDiffableDataSource<Int, TVCardItem>(collectionView: collectionView) { collectionView, indexPath, item in
            let cell = collectionView.dequeueConfiguredReusableCell(using: poster, for: indexPath, item: item)
            cell.accessibilityIdentifier = "host.\(item.id)"
            return cell
        }
        adopt(dataSource)
        switch mode {
        case .loading: show(state: .loading(title: "Loading Items"))
        case .error: showError()
        case .content: showItems()
        }
    }

    override func playFocused(at indexPath: IndexPath) -> Bool {
        items.insert(contentsOf: [Self.item(id: "new.0", title: "New 0"), Self.item(id: "new.1", title: "New 1")], at: 0)
        applyItems()
        return true
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        TVNavigation.push(TVGalleryDepthViewController(), from: self)
    }

    private func showError() {
        show(state: .error(
            title: "Couldn’t Load Items",
            message: "Try again in a moment.",
            retryTitle: "Try Again",
            retry: { [weak self] in self?.retry() },
            secondary: TVStateView.Action(title: "Go Back") { [weak self] in
                guard let self else { return }
                TVNavigation.pop(from: self)
            }
        ))
    }

    private func retry() {
        show(state: .loading(title: "Loading Items"))
        loadSlot.run { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            self.showItems()
        }
    }

    private func showItems() {
        applyItems()
        showContent()
    }

    private func applyItems() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, TVCardItem>()
        snapshot.appendSections([0])
        snapshot.appendItems(items)
        dataSource.applyReconfiguringExisting(snapshot)
    }
}

final class TVGalleryDepthViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        let label = UILabel()
        label.font = Theme.Font.title2
        label.textColor = Theme.Color.label
        label.text = "Depth \(navigationController?.viewControllers.count ?? 0)"
        label.accessibilityIdentifier = "host.depth"
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override var canBecomeFirstResponder: Bool { true }
}
#endif

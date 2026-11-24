import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// The titles the app left out because the server's copy cannot play here, and the way back: each row puts its title
/// back into Home, search and the libraries, on every device that reads the same Plex server.
final class IncompatibleTitlesViewController: UICollectionViewController {
    private enum Section: Hashable {
        case titles
    }

    private enum Item: Hashable {
        case title(String)
    }

    private let api: APIClient
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var reloadTask: Task<Void, Never>?
    private var changeObserver: NSObjectProtocol?
    private var working = Set<String>()

    init(api: APIClient) {
        self.api = api
        super.init(collectionViewLayout: UICollectionViewLayout())
        title = IncompatibleCopy.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        reloadTask?.cancel()
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .always
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.allowsKeyboardFocus()
        collectionView.showsVerticalScrollIndicator = false
        collectionView.collectionViewLayout = makeLayout()
        configureDataSource()
        applySnapshot()
        changeObserver = NotificationCenter.default.addObserver(
            forName: IncompatibleTitles.changed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySnapshot() }
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        reconcile()
    }

    /// Reads the labels the server carries now, so a title marked on another device is in the list too and one whose
    /// label was taken off in Plex has left it.
    private func reconcile() {
        reloadTask?.cancel()
        reloadTask = Task { [api] in
            await IncompatibleTitles.reconcile(api: api)
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            var config = UICollectionLayoutListConfiguration.wellRows()
            config.footerMode = .supplementary
            config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.swipeActions(at: indexPath)
            }
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            Theme.centerReadable(section, environment)
            return section
        }
    }

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard case .title(let ratingKey) = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let action = UIContextualAction(style: .normal, title: IncompatibleCopy.unmark) { [weak self] _, _, done in
            self?.show(ratingKey, done: done)
        }
        action.backgroundColor = Theme.Color.accent
        return UISwipeActionsConfiguration(actions: [action])
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.titles])
        snapshot.appendItems(IncompatibleTitles.marks.map { .title($0.ratingKey) }, toSection: .titles)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: view.window != nil && !UIAccessibility.isReduceMotionEnabled)
        updateEmptyState()
    }

    private func updateEmptyState() {
        guard IncompatibleTitles.count == 0 else {
            contentUnavailableConfiguration = nil
            return
        }
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "exclamationmark.triangle")
        config.text = IncompatibleCopy.emptyTitle
        config.secondaryText = IncompatibleCopy.emptyExplanation
        contentUnavailableConfiguration = config
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            cell.applyThemedBackground()
            cell.accessories = []
            guard case .title(let ratingKey) = item, let mark = IncompatibleTitles.marks.first(where: { $0.ratingKey == ratingKey }) else { return }
            var subtitle = mark.subtitle
            if !mark.shared { subtitle += " · " + IncompatibleCopy.thisDeviceOnly }
            var content = IconRowContentConfiguration(
                symbol: mark.type == "episode" ? "tv" : "exclamationmark.triangle",
                title: mark.title,
                subtitle: subtitle
            )
            content.isActionable = true
            content.value = self?.working.contains(ratingKey) == true ? nil : IncompatibleCopy.unmark
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { cell, _, _ in
            var content = UIListContentConfiguration.groupedFooter().textSized()
            content.text = IncompatibleCopy.footer
            content.textProperties.font = Theme.Font.caption1Regular
            content.textProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .title(let ratingKey) = dataSource.itemIdentifier(for: indexPath) else { return }
        show(ratingKey, done: nil)
    }

    /// Takes the label off the server, which puts the title back everywhere. The row stays while the server answers,
    /// and the swipe stays put when the server refuses.
    private func show(_ ratingKey: String, done: ((Bool) -> Void)?) {
        guard !working.contains(ratingKey), let mark = IncompatibleTitles.marks.first(where: { $0.ratingKey == ratingKey }) else {
            done?(false)
            return
        }
        working.insert(ratingKey)
        Haptics.light()
        Task { [api] in
            defer {
                working.remove(ratingKey)
                if done == nil { applySnapshot() }
            }
            do {
                try await IncompatibleTitles.unmark(mark, api: api)
                done?(true)
            } catch {
                Haptics.error()
                done?(false)
                presentFailure(error)
            }
        }
    }

    private func presentFailure(_ error: Error) {
        let alert = UIAlertController(
            title: IncompatibleCopy.unmark,
            message: ConnectionError.message(for: error),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }
}

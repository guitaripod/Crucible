import CrucibleCore
import CrucibleDesign
import MidgarCore
import UIKit

/// A poster grid of whatever `load` brings: a library's collections, a collection's titles, the viewer's playlists, a playlist's entries.
/// The screen owns loading, the empty and failed states and the focus rules; its owner says what a card shows, what Select does and what
/// a long press offers.
final class TVMediaGridViewController: TVScreenViewController {
    struct Empty {
        var symbol = "rectangle.stack"
        var title = String(localized: "Nothing Here")
        var message = String(localized: "This list is empty right now.")
    }

    var onSelect: ((PlexMetadata) -> Void)?
    var contextMenu: ((PlexMetadata) -> UIMenu?)?
    var summary: (([PlexMetadata]) -> String?) = { items in
        items.count == 1 ? String(localized: "1 title") : String(localized: "\(items.count) titles")
    }
    var onLoaded: (([PlexMetadata]) -> Void)?
    var onPlayPause: ((PlexMetadata) -> Bool)?
    var refreshInterval: Duration?

    private let screenTitle: String
    private let empty: Empty
    private let card: (PlexMetadata) -> TVCardItem
    private let load: () async throws -> [PlexMetadata]
    private var items: [PlexMetadata] = []
    private var mediaByID: [String: PlexMetadata] = [:]
    private var hasLoaded = false
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private lazy var loadSlot = makeTaskSlot()
    private lazy var refreshSlot = makeTaskSlot()

    init(title: String, empty: Empty = Empty(), card: @escaping (PlexMetadata) -> TVCardItem, load: @escaping () async throws -> [PlexMetadata]) {
        screenTitle = title
        self.empty = empty
        self.card = card
        self.load = load
        super.init(layout: UICollectionViewLayout())
        self.title = title
        collectionView.collectionViewLayout = makeLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureDataSource()
        show(state: .loading(title: nil))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
        startRefreshing()
    }

    private func startRefreshing() {
        guard let interval = refreshInterval else { return }
        refreshSlot.run { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.reload()
            }
        }
    }

    func reload() {
        loadSlot.run { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await load()
                guard !Task.isCancelled else { return }
                hasLoaded = true
                display(loaded)
            } catch {
                guard !Task.isCancelled else { return }
                MidgarLog.error("Grid load failed for \(screenTitle): \(error.localizedDescription)", category: .networking)
                if !hasLoaded {
                    show(state: .error(title: String(localized: "Couldn\u{2019}t Load"), message: error.localizedDescription, retryTitle: String(localized: "Retry")) { [weak self] in
                        self?.show(state: .loading(title: nil))
                        self?.reload()
                    })
                }
            }
        }
    }

    private func display(_ loaded: [PlexMetadata]) {
        items = loaded
        onLoaded?(loaded)
        mediaByID = Dictionary(loaded.map { ($0.entryID, $0) }, uniquingKeysWith: { _, latest in latest })
        var seen = Set<String>()
        let ids = loaded.map(\.entryID).filter { seen.insert($0).inserted }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids, toSection: 0)
        dataSource.applyReconfiguringExisting(snapshot, animated: view.window != nil)
        if ids.isEmpty {
            show(state: .empty(
                title: empty.title,
                message: empty.message,
                symbol: empty.symbol,
                action: TVStateView.Action(title: String(localized: "Back")) { [weak self] in
                    guard let self else { return }
                    TVNavigation.pop(from: self)
                }
            ))
        } else {
            showContent()
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, _ in
            let section = TVShelf.grid(columns: 6, itemHeight: TVCardStyle.poster.itemSize.height, header: false)
            section.boundarySupplementaryItems = [TVScreenTitleView.headerItem()]
            return section
        }
    }

    private func configureDataSource() {
        let poster = TVPosterCell.registration()
        let header = TVScreenTitleView.headerRegistration { [weak self] _ in
            guard let self else { return nil }
            return TVScreenTitleContent(title: screenTitle, summary: items.isEmpty ? nil : summary(items))
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
            let data = self?.mediaByID[id].map { self?.card($0) } ?? nil
            let cell = collectionView.dequeueConfiguredReusableCell(using: poster, for: indexPath, item: data ?? TVCardItem(id: id, title: ""))
            cell.accessibilityIdentifier = "grid.\(id)"
            return cell
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        adopt(dataSource)
    }

    override func playFocused(at indexPath: IndexPath) -> Bool {
        guard let media = media(at: indexPath) else { return false }
        return onPlayPause?(media) ?? false
    }

    private func media(at indexPath: IndexPath) -> PlexMetadata? {
        dataSource.itemIdentifier(for: indexPath).flatMap { mediaByID[$0] }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let media = media(at: indexPath) else { return }
        onSelect?(media)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let media = media(at: indexPath) else { return nil }
        return TVContextMenu.configuration(menu: contextMenu?(media))
    }
}

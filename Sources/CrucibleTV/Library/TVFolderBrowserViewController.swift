import CrucibleCore
import CrucibleDesign
import UIKit

/// One level of a library's folder tree: the sub-folders as a list, then the media directly inside as
/// a poster grid. Folders push another level; media opens its detail.
final class TVFolderBrowserViewController: TVScreenViewController {
    enum Section: Hashable {
        case title, folders, media
    }

    enum Item: Hashable {
        case title(TVScreenTitleContent)
        case folder(String)
        case media(String)
    }

    private let env: TVAppEnvironment
    private let source: LibraryFolderListing.Source
    private let screenTitle: String
    private let kind: LibraryGridKind
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var listing: LibraryFolderListing?
    private var mediaById: [String: PlexMetadata] = [:]
    private var needsRefresh = false
    private lazy var loadSlot = makeTaskSlot()
    private lazy var refreshSlot = makeTaskSlot()
    private lazy var actions = TVLibraryItemActions(env: env, kind: kind, presenter: self)

    init(env: TVAppEnvironment, source: LibraryFolderListing.Source, title: String, kind: LibraryGridKind) {
        self.env = env
        self.source = source
        self.kind = kind
        screenTitle = title
        super.init(layout: UICollectionViewLayout())
        self.title = title
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureDataSource()
        collectionView.collectionViewLayout = makeLayout()
        applySnapshot()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if listing == nil {
            load()
        } else if needsRefresh {
            needsRefresh = false
            refresh()
        }
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self, dataSource.snapshot().sectionIdentifiers.indices.contains(index) else { return TVShelf.grid() }
            switch dataSource.snapshot().sectionIdentifiers[index] {
            case .title:
                return TVScreenTitleView.section()
            case .folders:
                return TVRowList.section(environment: environment)
            case .media:
                return TVShelf.grid()
            }
        }
    }

    private func configureDataSource() {
        let titleRegistration = TVScreenTitleView.registration()
        let rowRegistration = TVRowCell.registration()
        let posterRegistration = TVPosterCell.registration()
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
            switch item {
            case .title(let content):
                return collectionView.dequeueConfiguredReusableCell(using: titleRegistration, for: indexPath, item: content)
            case .folder(let key):
                let folder = self?.listing?.folders.first { $0.key == key }
                let row = TVRowItem(id: key, title: folder?.title ?? key, symbol: "folder.fill", accessory: .chevron)
                let cell = collectionView.dequeueConfiguredReusableCell(using: rowRegistration, for: indexPath, item: row)
                cell.accessibilityIdentifier = "tv.folder.row.\(folder?.title ?? key)"
                return cell
            case .media(let id):
                let card = self?.mediaById[id].map { TVCardItem(folderItem: $0) } ?? TVCardItem(id: id, title: "")
                let cell = collectionView.dequeueConfiguredReusableCell(using: posterRegistration, for: indexPath, item: card)
                cell.accessibilityIdentifier = "tv.folder.media.\(id)"
                return cell
            }
        }
        adopt(dataSource)
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.title])
        snapshot.appendItems([.title(TVScreenTitleContent(title: screenTitle))], toSection: .title)
        if let listing {
            if !listing.folders.isEmpty {
                snapshot.appendSections([.folders])
                snapshot.appendItems(listing.folders.map { Item.folder($0.key) }, toSection: .folders)
            }
            if !listing.media.isEmpty {
                snapshot.appendSections([.media])
                snapshot.appendItems(listing.media.map { Item.media($0.id) }, toSection: .media)
            }
        }
        dataSource.applyReconfiguringExisting(snapshot)
    }

    /// Re-reads the folder after the user played or opened something, and redraws only what changed.
    /// A failure keeps what is on screen.
    private func refresh() {
        refreshSlot.run { [weak self] in
            guard let self else { return }
            do {
                let fresh = try await LibraryFolderListing.load(source, api: env.api)
                guard !Task.isCancelled, let current = listing else { return }
                let unchanged = fresh.media.map(\.id) == current.media.map(\.id)
                    && fresh.media.map(Self.watchedState) == current.media.map(Self.watchedState)
                guard !unchanged else { return }
                listing = fresh
                mediaById = Dictionary(fresh.media.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
                applySnapshot()
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("Folder refresh failed: \(error.localizedDescription)", .networking)
            }
        }
    }

    private static func watchedState(_ item: PlexMetadata) -> [Int] {
        [item.viewCount ?? 0, item.viewOffset ?? 0]
    }

    private func load() {
        show(state: .loading(title: nil))
        loadSlot.run { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await LibraryFolderListing.load(source, api: env.api)
                guard !Task.isCancelled else { return }
                listing = loaded
                mediaById = Dictionary(loaded.media.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
                applySnapshot()
                if loaded.isEmpty {
                    show(state: .empty(
                        title: "Empty Folder",
                        message: "Nothing is stored in this folder.",
                        symbol: "folder",
                        action: .init(title: "Go Back") { [weak self] in
                            guard let self else { return }
                            TVNavigation.pop(from: self)
                        }
                    ))
                } else {
                    showContent()
                }
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("Folder listing failed: \(error.localizedDescription)", .networking)
                show(state: .error(title: "Couldn’t Load Folder", message: ConnectionError.message(for: error), retryTitle: "Try Again", retry: { [weak self] in
                    self?.load()
                }))
            }
        }
    }

    override func playFocused(at indexPath: IndexPath) -> Bool {
        guard case .media(let id) = dataSource.itemIdentifier(for: indexPath), let item = mediaById[id] else { return false }
        needsRefresh = true
        return actions.play(item, isRecent: false)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .folder(let key):
            guard let folder = listing?.folders.first(where: { $0.key == key }) else { return }
            TVNavigation.push(TVFolderBrowserViewController(env: env, source: .folder(folder.key), title: folder.title, kind: kind), from: self)
        case .media(let id):
            guard let item = mediaById[id] else { return }
            needsRefresh = true
            actions.select(item, isRecent: false)
        case .title, nil:
            return
        }
    }
}

import CrucibleCore
import CrucibleDesign
import UIKit

/// One level of a library's folder tree: the sub-folders as a list, then the media directly inside as
/// a poster grid. Folders push another level; media opens its detail.
final class TVFolderBrowserViewController: UIViewController {
    enum Section: Hashable {
        case title, folders, media
    }

    enum Item: Hashable {
        case title(TVScreenTitle.Content)
        case folder(String)
        case media(String)
    }

    private let env: TVAppEnvironment
    private let source: LibraryFolderListing.Source
    private let screenTitle: String
    private let kind: LibraryGridKind
    private let collectionView: TVCollectionView
    private let stateView = TVStateView()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var listing: LibraryFolderListing?
    private var mediaById: [String: PlexMetadata] = [:]
    private var loadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var needsRefresh = false
    private lazy var actions = TVLibraryItemActions(env: env, kind: kind, presenter: self)

    init(env: TVAppEnvironment, source: LibraryFolderListing.Source, title: String, kind: LibraryGridKind) {
        self.env = env
        self.source = source
        self.kind = kind
        screenTitle = title
        collectionView = TVCollectionView(frame: .zero, collectionViewLayout: UICollectionViewLayout())
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        loadTask?.cancel()
        refreshTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.onPlayPause = { [weak self] indexPath in
            self?.playItem(at: indexPath)
        }
        stateView.isHidden = true
        stateView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        view.addSubview(stateView)
        for pinned in [collectionView, stateView] as [UIView] {
            NSLayoutConstraint.activate([
                pinned.topAnchor.constraint(equalTo: view.topAnchor),
                pinned.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                pinned.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                pinned.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
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

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTask?.cancel()
        if listing == nil { loadTask?.cancel() }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        stateView.isHidden ? [collectionView] : [stateView]
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self, dataSource.snapshot().sectionIdentifiers.indices.contains(index) else { return TVShelf.grid() }
            switch dataSource.snapshot().sectionIdentifiers[index] {
            case .title:
                return TVScreenTitle.section()
            case .folders:
                return TVRowList.section(environment: environment)
            case .media:
                return TVShelf.grid()
            }
        }
    }

    private func configureDataSource() {
        let titleRegistration = TVScreenTitle.registration()
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
    }

    private func applySnapshot() {
        let previous = Set(dataSource.snapshot().itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.title])
        snapshot.appendItems([.title(TVScreenTitle.Content(title: screenTitle))], toSection: .title)
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
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { previous.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Re-reads the folder after the user played or opened something, and redraws only what changed.
    /// A failure keeps what is on screen.
    private func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
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
        loadTask?.cancel()
        showState(.loading(title: nil))
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await LibraryFolderListing.load(source, api: env.api)
                guard !Task.isCancelled else { return }
                listing = loaded
                mediaById = Dictionary(loaded.media.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
                applySnapshot()
                if loaded.isEmpty {
                    showState(.empty(
                        title: "Empty Folder",
                        message: "Nothing is stored in this folder.",
                        symbol: "folder",
                        action: .init(title: "Go Back") { [weak self] in self?.navigationController?.popViewController(animated: true) }
                    ))
                } else {
                    showState(nil)
                }
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("Folder listing failed: \(error.localizedDescription)", .networking)
                showState(.error(title: "Couldn’t Load Folder", message: ConnectionError.message(for: error), retryTitle: "Try Again") { [weak self] in
                    self?.load()
                })
            }
        }
    }

    private func showState(_ state: TVStateView.State?) {
        let changedVisibility = stateView.isHidden != (state == nil)
        if let state { stateView.show(state) }
        stateView.isHidden = state == nil
        collectionView.isHidden = state != nil
        if changedVisibility { setNeedsFocusUpdate() }
    }

    private func playItem(at indexPath: IndexPath) {
        guard case .media(let id) = dataSource.itemIdentifier(for: indexPath), let item = mediaById[id] else { return }
        needsRefresh = true
        actions.play(item, isRecent: false)
    }
}

extension TVFolderBrowserViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        if case .title = dataSource.itemIdentifier(for: indexPath) { return false }
        return true
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .folder(let key):
            guard let folder = listing?.folders.first(where: { $0.key == key }) else { return }
            let next = TVFolderBrowserViewController(env: env, source: .folder(folder.key), title: folder.title, kind: kind)
            navigationController?.pushViewController(next, animated: true)
        case .media(let id):
            guard let item = mediaById[id] else { return }
            needsRefresh = true
            actions.select(item, isRecent: false)
        case .title, nil:
            return
        }
    }
}

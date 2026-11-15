import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// One level of a library's folder tree (`TVFolderBrowserViewController`): the sub-folders as rows, then the media directly
/// inside as a poster grid in the shape most of its artwork has. Folders push another level; media opens its page. Coming
/// back after playing or opening something re-reads the folder and redraws only what changed.
@MainActor
final class FolderBrowserScreen: ScreenView {
    private let api: APIClient
    private let source: LibraryFolderListing.Source
    private let kind: LibraryGridKind
    private let page = PageView()
    private let heading: ScreenTitleView
    private let folders = RowListView()
    private let grid = CardGridView()
    private let state = StateView()
    private var listing: LibraryFolderListing?
    private var mediaById: [String: PlexMetadata] = [:]
    private var needsRefresh = false
    private var loadTask: Task<Void, Never>?
    private lazy var actions = LibraryActions(api: api, kind: kind, host: self) { [weak self] item, watched in
        self?.markWatched(item, watched)
    }
    private lazy var artworkShape = ArtworkShapeTracker { [weak self] in
        LibraryCards.samples((self?.listing?.media ?? []).map { LibraryPoster(folderItem: $0) })
    } onChange: { [weak self] in
        self?.applyArtworkShape()
    }

    init(api: APIClient, source: LibraryFolderListing.Source, title: String, kind: LibraryGridKind) {
        self.api = api
        self.source = source
        self.kind = kind
        heading = ScreenTitleView(title: title)
        super.init()
        [page, state].forEach(addSubview)
        page.setSections([heading])
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        folders.isLeadingAligned = true
        folders.onSelect = { [weak self] row in self?.openFolder(key: row.id) }
        grid.onActivate = { [weak self] card in
            guard let self, let item = self.mediaById[card.id] else { return }
            self.needsRefresh = true
            self.actions.select(item, isRecent: false)
        }
        grid.onPlay = { [weak self] card in
            guard let self, let item = self.mediaById[card.id] else { return false }
            self.needsRefresh = true
            return self.actions.play(item, isRecent: false)
        }
        grid.onContextMenu = { [weak self] card, point in
            guard let self, let item = self.mediaById[card.id] else { return }
            self.needsRefresh = true
            self.actions.presentMenu(for: item, isRecent: false, at: point)
        }
        state.isHidden = true
    }

    override var preferredFocusView: View? { state.isHidden ? page : state }
    override var remembersFocus: Bool { true }

    override func screenDidAppear() {
        if listing == nil {
            load()
        } else if needsRefresh {
            needsRefresh = false
            refresh()
        }
    }

    override func screenWillDisappear() {
        loadTask?.cancel()
    }

    private func load() {
        showState(.loading(title: nil))
        loadTask?.cancel()
        let api = api
        let source = source
        loadTask = Task { [weak self] in
            do {
                let loaded = try await LibraryFolderListing.load(source, api: api)
                guard !Task.isCancelled, let self else { return }
                self.display(loaded)
                if loaded.isEmpty {
                    self.showState(.empty(title: String(localized: "Empty Folder"), message: String(localized: "Nothing is stored in this folder."),
                                          symbol: "folder", action: StateView.Action(title: String(localized: "Go Back")) { [weak self] in
                                              _ = self?.navigation?.pop()
                                          }))
                } else {
                    self.showContent()
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                MidgarLog.error("Folder listing failed: \(error.localizedDescription)", category: .networking)
                self.showState(.error(title: String(localized: "Couldn’t Load Folder"), message: ConnectionError.message(for: error),
                                      retryTitle: String(localized: "Try Again"), retry: { [weak self] in self?.load() }))
            }
        }
    }

    /// Re-reads the folder after the viewer played or opened something and redraws only what changed; a failure keeps what
    /// is on screen.
    private func refresh() {
        loadTask?.cancel()
        let api = api
        let source = source
        loadTask = Task { [weak self] in
            do {
                let fresh = try await LibraryFolderListing.load(source, api: api)
                guard !Task.isCancelled, let self, let current = self.listing else { return }
                let unchanged = fresh.folders == current.folders && fresh.media.map(\.id) == current.media.map(\.id)
                    && fresh.media.map(Self.watchedState) == current.media.map(Self.watchedState)
                guard !unchanged else { return }
                self.display(fresh)
            } catch {
                guard !Task.isCancelled else { return }
                MidgarLog.error("Folder refresh failed: \(error.localizedDescription)", category: .networking)
            }
        }
    }

    private static func watchedState(_ item: PlexMetadata) -> [Int] {
        [item.viewCount ?? 0, item.viewOffset ?? 0]
    }

    private func markWatched(_ item: PlexMetadata, _ watched: Bool) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await WatchedService.setWatched(watched, ratingKey: item.id, api: self.api)
            } catch {
                MidgarLog.error("Mark watched failed ratingKey=\(item.id): \(error)", category: .networking)
            }
            self.refresh()
        }
    }

    private func display(_ loaded: LibraryFolderListing) {
        listing = loaded
        mediaById = Dictionary(loaded.media.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        folders.setItems(loaded.folders.map { RowItem(id: $0.key, title: $0.title, symbol: "folder.fill", accessory: .chevron) })
        artworkShape.update()
        grid.aspect = Float(artworkShape.aspect)
        grid.setItems(loaded.media.map(LibraryCards.folder))
        var sections: [View] = [heading]
        if !loaded.folders.isEmpty { sections.append(folders) }
        if !loaded.media.isEmpty { sections.append(grid) }
        page.setSections(sections)
        setNeedsLayout()
    }

    private func applyArtworkShape() {
        grid.aspect = Float(artworkShape.aspect)
        page.setNeedsLayout()
    }

    private func openFolder(key: String) {
        guard let folder = listing?.folders.first(where: { $0.key == key }) else { return }
        rootView?.push(FolderBrowserScreen(api: api, source: .folder(folder.key), title: folder.title, kind: kind))
    }

    private func showState(_ newState: StateView.State) {
        let hadFocus = containsFocus
        state.show(newState)
        state.isHidden = false
        page.isHidden = true
        if hadFocus { window?.focus.focus(state, animated: false) }
    }

    private func showContent() {
        let hadFocus = containsFocus
        state.isHidden = true
        page.isHidden = false
        if hadFocus { window?.focus.focus(page, animated: false) }
    }

    override func layoutSubviews() {
        page.topInset = Theme.current.metrics.tabBarClearance
        page.frame = bounds
        state.frame = bounds
        page.setNeedsLayout()
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

extension FolderBrowserScreen: Reloadable {
    func reload() {
        listing == nil ? load() : refresh()
    }
}

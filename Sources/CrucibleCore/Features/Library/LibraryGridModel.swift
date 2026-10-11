import Foundation

/// Everything one library grid does apart from drawing: it reads the section page by page, tracks
/// the filter and sort options, the Continue item, Recently Watched, genres and the A–Z index, and
/// reports each change through `onUpdate` so the screen can redraw. Both the iPhone and the Apple TV
/// grids drive their UI from it.
@MainActor
package final class LibraryGridModel {
    package typealias PageCompletion = @MainActor @Sendable () -> Void
    package typealias PageIndexAction = @MainActor @Sendable (Int) -> Void

    package enum ContentState: Equatable, Sendable {
        case content
        case loading
        case failed(message: String)
        case noMatches
        case empty
    }

    package enum Update: Sendable {
        case optionsChanged
        case contentState
        case pageLoaded
        case pageFailed
        case continueItem
        case recents
        case genres
        case alphabet
    }

    package let kind: LibraryGridKind
    package let sectionId: String
    package var onUpdate: (@MainActor (Update) -> Void)?

    package private(set) var options = LibraryGridOptions()
    package private(set) var genres: [LibraryGenre] = []
    package private(set) var pager = LibraryGridPager()
    package private(set) var contentState = ContentState.content
    package private(set) var continueItem: PlexMetadata?
    package private(set) var recentItems: [PlexMetadata] = []
    package private(set) var alphabet: LibraryAlphabetIndex?

    private let api: APIClient
    private var loadTask: Task<Void, Never>?
    private var hubsTask: Task<Void, Never>?
    private var recentTask: Task<Void, Never>?
    private var alphabetTask: Task<Void, Never>?
    private var genresTask: Task<Void, Never>?

    package init(api: APIClient, sectionId: String, kind: LibraryGridKind) {
        self.api = api
        self.sectionId = sectionId
        self.kind = kind
    }

    deinit {
        loadTask?.cancel()
        hubsTask?.cancel()
        recentTask?.cancel()
        alphabetTask?.cancel()
        genresTask?.cancel()
    }

    package var gridIds: [String] { pager.ids }

    package func item(withId id: String) -> PlexMetadata? {
        pager.item(withId: id)
    }

    package func recentItem(withId id: String) -> PlexMetadata? {
        recentItems.first { $0.id == id }
    }

    /// Hidden while a filter narrows the grid, and without whatever the Continue banner already offers.
    package var visibleRecents: [PlexMetadata] {
        RecentlyWatched.visible(recentItems, continueItem: continueItem, kind: kind, isFiltering: options.isFiltering)
    }

    /// Whether the A–Z index lines up with what is loaded: title-ascending, unfiltered, and the
    /// server's letter counts are usable.
    package var offersAlphabetJump: Bool {
        options.allowsAlphabetJump && alphabet?.isUsable == true && !pager.ids.isEmpty
    }

    package func letter(atGridIndex index: Int) -> String? {
        alphabet?.letter(atOffset: index)
    }

    package func appear() {
        loadHubs()
        loadRecentlyWatched()
        if alphabet == nil { loadAlphabet() }
        if pager.hasLoaded {
            reloadLoadedPages()
        } else {
            loadPage(offset: 0)
        }
    }

    package func disappear() {
        loadTask?.cancel()
        pager.endFetch()
    }

    package func refreshAll() {
        loadHubs()
        loadRecentlyWatched()
        loadAlphabet()
        loadPage(offset: 0)
    }

    package func loadPage(offset: Int) {
        fetchPage(offset: offset, size: LibraryGridPager.pageSize, then: nil)
    }

    package func fetchPage(offset: Int, size: Int, then completion: PageCompletion?) {
        loadTask?.cancel()
        pager.beginFetch()
        if offset == 0 { showLoadingState() }
        let endpoint = options.endpoint(sectionId: sectionId, start: offset, size: size)
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await api.requestContainer(endpoint)
                guard !Task.isCancelled else { return }
                pager.apply(items: container.Metadata ?? [], offset: offset, totalSize: container.totalSize ?? 0)
                contentState = settledContentState
                onUpdate?(.pageLoaded)
                completion?()
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("\(kind.logName) page fetch failed section=\(sectionId) offset=\(offset): \(error.localizedDescription)", .networking)
                pager.endFetch()
                if pager.ids.isEmpty { contentState = .failed(message: ConnectionError.message(for: error)) }
                onUpdate?(.pageFailed)
            }
        }
    }

    /// Refetches every page already loaded in one request so the grid picks up watched/progress
    /// changes on return without collapsing pagination or scroll position.
    package func reloadLoadedPages() {
        fetchPage(offset: 0, size: pager.reloadSize, then: nil)
    }

    package func loadNextPageIfNeeded(near index: Int) {
        guard pager.shouldLoadNextPage(near: index) else { return }
        loadPage(offset: pager.serverOffset)
    }

    package func loadGenres() {
        genresTask?.cancel()
        genresTask = Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await api.requestContainer(.sectionGenres(sectionId: sectionId))
                guard !Task.isCancelled else { return }
                genres = (container.Directory ?? []).compactMap { directory in
                    guard let key = directory.key, let title = directory.title else { return nil }
                    return LibraryGenre(key: key, title: title)
                }
                onUpdate?(.genres)
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("\(kind.logName) genres fetch failed section=\(sectionId): \(error.localizedDescription)", .networking)
            }
        }
    }

    package func selectChip(_ filter: LibraryWatchFilter) {
        update { $0 = $0.selectingChip(filter) }
    }

    package func setWatch(_ filter: LibraryWatchFilter) {
        update { $0.watch = filter }
    }

    package func setSort(_ key: String) {
        update { $0.sort = key }
    }

    package func setGenre(_ key: String?) {
        update { $0.genre = key }
    }

    package func clearFilters() {
        update { $0 = $0.clearingFilters() }
    }

    /// Brings the item at `letter`'s offset into reach. `scrollTo` receives the grid index to show;
    /// when that part of the section is not loaded yet it is called once the pages up to it have arrived.
    package func jump(to letter: String, scrollTo: @escaping PageIndexAction) {
        guard let alphabet, let offset = alphabet.offset(for: letter) else { return }
        switch pager.jumpPlan(toOffset: offset) {
        case .scroll(let index):
            scrollTo(index)
        case .loadThenScroll(let size):
            AppLogger.info("\(kind.logName) A–Z jump letter=\(letter) offset=\(offset) loading \(size)", .ui)
            fetchPage(offset: pager.serverOffset, size: size) {
                scrollTo(offset)
            }
        }
    }

    package func setWatched(ratingKey: String, watched: Bool) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if watched {
                    try await api.requestVoid(.scrobble(ratingKey: ratingKey))
                } else {
                    try await api.requestVoid(.unscrobble(ratingKey: ratingKey))
                }
            } catch {
                AppLogger.error("\(kind.logName) mark watched=\(watched) failed ratingKey=\(ratingKey): \(error.localizedDescription)", .networking)
            }
            await api.invalidateCache()
            reloadLoadedPages()
            loadHubs()
        }
    }

    private var settledContentState: ContentState {
        guard pager.ids.isEmpty else { return .content }
        return options.isFiltering ? .noMatches : .empty
    }

    private func showLoadingState() {
        guard pager.ids.isEmpty else { return }
        contentState = .loading
        onUpdate?(.contentState)
    }

    private func update(_ change: (inout LibraryGridOptions) -> Void) {
        var next = options
        change(&next)
        guard next != options else { return }
        options = next
        AppLogger.info("\(kind.logName) options sort=\(next.sort) genre=\(next.genre ?? "-") filter=\(next.watch.rawValue)", .ui)
        onUpdate?(.optionsChanged)
        loadPage(offset: 0)
    }

    private func loadHubs() {
        hubsTask?.cancel()
        hubsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await api.requestContainer(.sectionHubs(sectionId: sectionId))
                guard !Task.isCancelled else { return }
                let next = LibraryContinue.select(from: container.Hub ?? [])
                guard LibraryContinue.differs(next, from: continueItem) else { return }
                continueItem = next
                onUpdate?(.continueItem)
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("\(kind.logName) hubs fetch failed section=\(sectionId): \(error.localizedDescription)", .networking)
            }
        }
    }

    private func loadRecentlyWatched() {
        recentTask?.cancel()
        recentTask = Task { [weak self] in
            guard let self else { return }
            let items = await RecentlyWatched.load(api: api, sectionId: sectionId, groupingByShow: kind.groupsHistoryByShow)
            guard !Task.isCancelled, RecentlyWatched.differs(items, from: recentItems) else { return }
            recentItems = items
            onUpdate?(.recents)
        }
    }

    private func loadAlphabet() {
        alphabetTask?.cancel()
        alphabetTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response: LibraryFirstCharacterResponse = try await api.request(.sectionFirstCharacter(sectionId: sectionId))
                guard !Task.isCancelled else { return }
                alphabet = LibraryAlphabetIndex(entries: response.MediaContainer.Directory ?? [])
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("\(kind.logName) firstCharacter fetch failed section=\(sectionId): \(error.localizedDescription)", .networking)
                alphabet = LibraryAlphabetIndex(entries: [])
            }
            onUpdate?(.alphabet)
        }
    }
}

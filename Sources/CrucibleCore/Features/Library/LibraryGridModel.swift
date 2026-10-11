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
    package let offersContinueBanner: Bool
    package var onUpdate: (@MainActor (Update) -> Void)?

    package private(set) var options = LibraryGridOptions()
    package private(set) var genres: [LibraryGenre] = []
    package private(set) var pager = LibraryGridPager()
    package private(set) var contentState = ContentState.content
    package private(set) var continueItem: PlexMetadata?
    package private(set) var recentItems: [PlexMetadata] = []
    package private(set) var hasLoadedRecents = false
    package private(set) var alphabet: LibraryAlphabetIndex?

    private let api: APIClient
    private var loadTask: Task<Void, Never>?
    private var hubsTask: Task<Void, Never>?
    private var recentTask: Task<Void, Never>?
    private var alphabetTask: Task<Void, Never>?
    private var genresTask: Task<Void, Never>?
    private var isLoadingGenres = false

    /// `offersContinueBanner` is false for a screen that draws no Continue banner, so Recently Watched
    /// keeps the in-progress title instead of leaving it out.
    package init(api: APIClient, sectionId: String, kind: LibraryGridKind, offersContinueBanner: Bool = true) {
        self.api = api
        self.sectionId = sectionId
        self.kind = kind
        self.offersContinueBanner = offersContinueBanner
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
        RecentlyWatched.visible(
            recentItems,
            continueItem: offersContinueBanner ? continueItem : nil,
            kind: kind,
            isFiltering: options.isFiltering
        )
    }

    /// Whether the A–Z index lines up with what is loaded: title-ascending, unfiltered, and the
    /// server's letter counts are usable.
    package var offersAlphabetJump: Bool {
        options.allowsAlphabetJump && alphabet?.isUsable == true && !pager.ids.isEmpty
    }

    package func letter(atGridIndex index: Int) -> String? {
        alphabet?.letter(atOffset: index)
    }

    /// `visibleGridIndex` is where the user is in the grid; a deeply scrolled grid refreshes around it.
    package func appear(visibleGridIndex: Int = 0) {
        if genres.isEmpty { loadGenres() }
        loadHubs()
        loadRecentlyWatched()
        if alphabet == nil { loadAlphabet() }
        if pager.hasLoaded {
            reloadLoadedPages(anchor: visibleGridIndex)
        } else {
            loadPage(offset: 0)
        }
    }

    /// Cancels the page fetch in flight. A first page that never arrived leaves nothing to show, so
    /// the loading state is dropped rather than left spinning until the next `appear()`.
    package func disappear() {
        loadTask?.cancel()
        pager.endFetch()
        if contentState == .loading { contentState = .content }
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

    /// Brings watched and progress state up to date on return without collapsing pagination or the
    /// scroll position: see `LibraryGridPager.reloadPlan(anchor:)`.
    package func reloadLoadedPages(anchor: Int = 0) {
        switch pager.reloadPlan(anchor: anchor) {
        case .refetchLoaded(let size):
            fetchPage(offset: 0, size: size, then: nil)
        case .refreshWindow(let offset, let size):
            refreshWindow(offset: offset, size: size)
        }
    }

    private func refreshWindow(offset: Int, size: Int) {
        loadTask?.cancel()
        pager.beginFetch()
        let endpoint = options.endpoint(sectionId: sectionId, start: offset, size: size)
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await api.requestContainer(endpoint)
                guard !Task.isCancelled else { return }
                pager.merge(items: container.Metadata ?? [])
                onUpdate?(.pageLoaded)
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("\(kind.logName) window refresh failed section=\(sectionId) offset=\(offset): \(error.localizedDescription)", .networking)
                pager.endFetch()
                onUpdate?(.pageFailed)
            }
        }
    }

    package func loadNextPageIfNeeded(near index: Int) {
        guard pager.shouldLoadNextPage(near: index) else { return }
        loadPage(offset: pager.serverOffset)
    }

    /// Reads the section's genres unless a read is already in flight; `appear()` retries it while the list is empty.
    package func loadGenres() {
        guard !isLoadingGenres else { return }
        isLoadingGenres = true
        genresTask = Task { [weak self] in
            guard let self else { return }
            defer { isLoadingGenres = false }
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
        let anchor = pager.ids.firstIndex(of: ratingKey) ?? 0
        Task { [weak self] in
            guard let self else { return }
            do {
                try await WatchedService.setWatched(watched, ratingKey: ratingKey, api: api)
            } catch {
                await api.invalidateCache()
            }
            reloadLoadedPages(anchor: anchor)
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
            guard !Task.isCancelled else { return }
            let isFirstLoad = !hasLoadedRecents
            hasLoadedRecents = true
            guard isFirstLoad || RecentlyWatched.differs(items, from: recentItems) else { return }
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

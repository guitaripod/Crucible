import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// A movie or show library (`TVLibraryViewController`): its title and count, the watch filter chips, and the poster grid,
/// paged from the server as focus or scrolling nears the end of what is loaded.
@MainActor
final class LibraryScreen: ScreenView {
    private let api: APIClient
    private let directory: PlexDirectory
    private let kind: LibraryGridKind
    private let model: LibraryGridModel
    private let page = PageView()
    private let title: ScreenTitleView
    private let chips = ChipRowView()
    private let grid = CardGridView()
    private let state = StateView()

    init(api: APIClient, directory: PlexDirectory) {
        self.api = api
        self.directory = directory
        kind = LibraryGridKind(sectionType: directory.type) ?? .movie
        model = LibraryGridModel(api: api, sectionId: directory.key ?? "", kind: kind, offersContinueBanner: false)
        title = ScreenTitleView(title: directory.title ?? "")
        super.init()
        [page, state].forEach(addSubview)
        page.setSections([title, chips, grid])
        page.onScroll = { [weak self] offset in
            self?.rootView?.contentScrolled(offset: offset)
            self?.loadMoreIfNeeded()
        }
        state.isHidden = true
        chips.onSelect = { [weak self] chip in
            guard let self, let filter = LibraryWatchFilter.allCases.first(where: { "\($0)" == chip.id }) else { return }
            self.model.selectChip(filter)
        }
        grid.onActivate = { [weak self] item in
            guard let self, let media = self.model.item(withId: item.id) else { return }
            self.rootView?.push(DetailScreen(api: self.api, item: media))
        }
        grid.onFocus = { [weak self] item in
            guard let self, let index = self.model.gridIds.firstIndex(of: item.id) else { return }
            self.model.loadNextPageIfNeeded(near: index)
        }
        model.onUpdate = { [weak self] update in self?.updated(update) }
        updateChips()
    }

    override var preferredFocusView: View? { state.isHidden ? grid : state }

    override func screenDidAppear() {
        model.appear()
    }

    override func screenWillDisappear() {
        model.disappear()
    }

    private func updated(_ update: LibraryGridModel.Update) {
        switch update {
        case .optionsChanged, .genres, .facets:
            updateChips()
        case .contentState, .pageFailed:
            applyState()
        case .pageLoaded:
            grid.setItems(model.gridIds.compactMap { id in model.item(withId: id).map(card) })
            title.summary = countText()
            applyState()
            page.setNeedsLayout()
        case .recents, .continueItem, .alphabet:
            break
        }
    }

    private func card(_ item: PlexMetadata) -> CardItem {
        let poster = LibraryPoster(grid: item, kind: kind)
        return CardItem(
            id: item.id,
            artwork: poster.posterPath.map { .path($0, .poster) },
            title: poster.title,
            subtitle: poster.subtitle,
            progress: poster.progress,
            isUnwatched: poster.isUnwatched,
            isWatched: kind == .movie && item.isWatched,
            badgeText: poster.unwatchedCount.map { String(localized: "\($0) unwatched") },
            placeholderSymbol: Symbol(poster.placeholderIcon)
        )
    }

    private func countText() -> String? {
        guard model.pager.hasLoaded else { return nil }
        let total = model.pager.totalSize
        let count = String(total)
        let summary: String
        switch (kind == .movie, total == 1) {
        case (true, true): summary = String(localized: "\(count) movie")
        case (true, false): summary = String(localized: "\(count) movies")
        case (false, true): summary = String(localized: "\(count) show")
        case (false, false): summary = String(localized: "\(count) shows")
        }
        return model.options.isFiltering ? String(localized: "\(summary) · Filtered") : summary
    }

    private func updateChips() {
        chips.setChips(LibraryWatchFilter.allCases.map { filter in
            ChipRowView.Chip(id: "\(filter)", title: filter.title, isSelected: model.options.watch == filter)
        })
    }

    private func applyState() {
        switch model.contentState {
        case .content:
            state.isHidden = true
            page.isHidden = false
        case .loading:
            if model.gridIds.isEmpty {
                state.isHidden = false
                state.show(.loading(title: nil))
            }
        case .failed(let message):
            state.isHidden = false
            state.show(.error(title: String(localized: "Couldn’t Load This Library"), message: message, retryTitle: String(localized: "Try Again"),
                              retry: { [weak self] in self?.model.refreshAll() }))
        case .noMatches:
            state.isHidden = false
            state.show(.empty(title: String(localized: "No Matches"), message: String(localized: "Nothing in this library matches the filter."),
                              symbol: "line.3.horizontal.decrease.circle", action: nil))
        case .empty:
            state.isHidden = false
            state.show(.empty(title: String(localized: "Nothing Here Yet"), message: nil, symbol: kind == .movie ? "film" : "tv", action: nil))
        }
    }

    /// Scrolling near the end of the loaded posters asks for the next page.
    private func loadMoreIfNeeded() {
        let visibleBottom = page.offset + page.frame.height
        guard grid.frame.maxY - visibleBottom < page.frame.height else { return }
        model.loadNextPageIfNeeded(near: max(0, model.gridIds.count - 1))
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        page.topInset = metrics.tabBarClearance
        page.frame = bounds
        state.frame = bounds
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

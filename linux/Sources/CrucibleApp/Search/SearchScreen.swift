import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// Search (`Features/Search`): a real text field (typing anywhere outside one starts here with that letter), recent
/// searches and Recently Added while it is empty, and the server's matches as a top result and shelves of movies, shows
/// and episodes, as the shared search session decides them.
@MainActor
final class SearchScreen: ScreenView {
    private let api: APIClient
    private let session: SearchSession
    private let field = TextFieldView(placeholder: String(localized: "Movies, Shows, People and More"))
    private let page = PageView()
    private let recents = ChipRowView()
    private let state = StateView()
    private var shelves: [String: ShelfView] = [:]
    private var items: [String: PlexMetadata] = [:]

    init(api: APIClient) {
        self.api = api
        session = SearchSession(loader: SearchLoader(api: api))
        super.init()
        [page, state, field].forEach(addSubview)
        state.isHidden = true
        field.onChange = { [weak self] text in self?.session.update(query: text, scope: .all) }
        field.onSubmit = { [weak self] _ in self?.session.rememberCurrentQuery() }
        recents.onSelect = { [weak self] chip in
            self?.field.setText(chip.title, notify: false)
            self?.session.select(recent: chip.title)
        }
        session.onChange = { [weak self] state in self?.render(state) }
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        session.start()
    }

    override var preferredFocusView: View? { field }

    override func screenDidAppear() { session.resume() }
    override func screenWillDisappear() { session.suspend() }

    /// Starts a search with `text` typed somewhere else.
    func begin(with text: String) {
        window?.focus.focus(field, animated: false)
        field.setText(field.text + text)
    }

    override func handleBack() -> Bool {
        guard !field.text.isEmpty else { return false }
        field.setText("")
        window?.focus.focus(field, animated: false)
        return true
    }

    private func shelf(_ id: String, title: String, style: CardStyle) -> ShelfView {
        let shelf = shelves[id] ?? ShelfView(header: nil, style: style)
        shelf.header = SectionHeader(title: title)
        shelf.style = style
        shelf.onActivate = { [weak self] card in
            guard let self, let media = self.items[card.id] else { return }
            self.session.rememberCurrentQuery()
            self.rootView?.push(DetailScreen(api: self.api, item: media))
        }
        shelves[id] = shelf
        return shelf
    }

    private func cards(_ media: [PlexMetadata], landscape: Bool = false) -> [CardItem] {
        media.map { item in
            items[item.id] = item
            let poster = SearchPosterModel(item: item)
            let path = landscape ? (item.thumb ?? poster.posterPath) : poster.posterPath
            return CardItem(id: item.id, artwork: path.map { .path($0, landscape ? .backdrop : .poster) }, title: poster.title,
                            subtitle: poster.subtitle, progress: poster.progress, isUnwatched: poster.isUnwatched,
                            badgeText: poster.unwatchedCount.map { String(localized: "\($0) unwatched") }, placeholderSymbol: Symbol(poster.placeholderIcon))
        }
    }

    private func render(_ searchState: SearchState) {
        state.isHidden = true
        page.isHidden = false
        var sections: [View] = []
        switch searchState {
        case .idle(let content):
            if !content.recents.isEmpty {
                recents.setChips(content.recents.map { ChipRowView.Chip(id: $0, title: $0, symbol: "clock") })
                sections.append(recents)
            }
            if !content.recentlyAdded.isEmpty {
                let recent = shelf("recent", title: String(localized: "Recently Added"), style: .poster)
                recent.setItems(cards(content.recentlyAdded))
                sections.append(recent)
            }
        case .loading:
            state.isHidden = false
            state.show(.loading(title: nil))
        case .results(_, let parts):
            let top = [parts.top].compactMap { $0 }
            if !parts.movies.isEmpty || top.first?.mediaType == "movie" {
                let movies = shelf("movies", title: String(localized: "Movies"), style: .poster)
                movies.setItems(cards(dedupe(top.filter { $0.mediaType == "movie" } + parts.movies)))
                sections.append(movies)
            }
            if !parts.shows.isEmpty || top.first?.mediaType == "show" {
                let shows = shelf("shows", title: String(localized: "TV Shows"), style: .poster)
                shows.setItems(cards(dedupe(top.filter { $0.mediaType == "show" } + parts.shows)))
                sections.append(shows)
            }
            if !parts.episodes.isEmpty {
                let episodes = shelf("episodes", title: String(localized: "Episodes"), style: .landscape)
                episodes.setItems(cards(parts.episodes, landscape: true))
                sections.append(episodes)
            }
        case .empty(let query, _):
            state.isHidden = false
            state.show(.empty(title: String(localized: "No Results"), message: String(localized: "Nothing on your server matches “\(query)”."),
                              symbol: "magnifyingglass", action: nil))
        case .failed(let query, let message):
            state.isHidden = false
            state.show(.error(title: String(localized: "Couldn’t Search"), message: message, retryTitle: String(localized: "Try Again"),
                              retry: { [weak self] in self?.session.retry(query) }))
        }
        page.setSections(sections)
        setNeedsLayout()
    }

    private func dedupe(_ media: [PlexMetadata]) -> [PlexMetadata] {
        var seen = Set<String>()
        return media.filter { seen.insert($0.id).inserted }
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let width = min(frame.width - metrics.sideMargin * 2, metrics.tv(1200))
        field.frame = Rect(x: ((frame.width - width) / 2).rounded(), y: metrics.tabBarClearance, width: width, height: metrics.primaryControlHeight)
        page.topInset = field.frame.maxY + metrics.tv(24)
        page.frame = bounds
        state.frame = Rect(x: 0, y: field.frame.maxY, width: frame.width, height: frame.height - field.frame.maxY)
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

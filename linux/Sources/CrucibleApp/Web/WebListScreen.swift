import CrucibleCore
import CrucibleUI
import CrucibleWeb
import Foundation
import Kiln
import MidgarCore

/// A screen of web videos in a grid: a playlist, a search, the whole subscriptions feed, Watch Later, the history. It
/// loads when it appears, keeps what it showed while a reload runs, plays a video on select and offers every card's
/// menu on a right click.
@MainActor
final class WebListScreen: ScreenView, Reloadable {
    struct Empty {
        var symbol: Symbol = "play.rectangle"
        var title = String(localized: "Nothing Here")
        var message = String(localized: "This list is empty right now.")
    }

    /// Whether selecting a video queues the ones after it (a playlist plays on; a search does not).
    var playsOn = false
    /// Whether the cards name their channel (off on a list that is all one channel's).
    var showsChannel = true

    private let empty: Empty
    private let load: (_ fresh: Bool) async throws -> [WebEntry]
    private let page = PageView()
    private let heading: ScreenTitleView
    private let grid = CardGridView()
    private let state = StateView()
    private var shown: [WebEntry] = []
    private var hasLoaded = false
    private var loadTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    init(title: String, empty: Empty = Empty(), initial: [WebEntry] = [], load: @escaping (_ fresh: Bool) async throws -> [WebEntry]) {
        self.empty = empty
        self.load = load
        heading = ScreenTitleView(title: title)
        super.init()
        [page, state].forEach(addSubview)
        page.setSections([heading, grid])
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        grid.aspect = 9.0 / 16.0
        grid.titleLines = 2
        grid.onActivate = { [weak self] card in
            guard let self, let index = self.shown.firstIndex(where: { WebCards.prefix + $0.id == card.id }) else { return }
            let queue = self.playsOn ? Array(self.shown[(index + 1)...].filter { $0.kind == .video }) : []
            WebActions.open(self.shown[index], queue: queue, from: self)
        }
        grid.onPlay = { [weak self] card in
            guard let self, let entry = self.shown.first(where: { WebCards.prefix + $0.id == card.id }), entry.kind == .video else { return false }
            WebActions.play(entry, from: self)
            return true
        }
        grid.onContextMenu = { [weak self] card, point in
            guard let self, let entry = self.shown.first(where: { WebCards.prefix + $0.id == card.id }) else { return }
            WebActions.presentMenu(for: entry, at: point, in: self, showsChannel: self.showsChannel) { [weak self] in self?.reload() }
        }
        state.show(.loading(title: nil))
        if !initial.isEmpty {
            hasLoaded = true
            display(initial)
        }
        observer = NotificationCenter.default.addObserver(forName: WebLibrary.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCards() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        loadTask?.cancel()
    }

    /// The videos of the playlist `entry` stands for, which play on one after another.
    static func playlist(_ entry: WebEntry) -> WebListScreen {
        let screen = WebListScreen(title: entry.title) { fresh in
            try await WebService.shared.listing(entry.url, limit: 200, fresh: fresh).entries
        }
        screen.playsOn = true
        return screen
    }

    override var preferredFocusView: View? { state.isHidden ? grid : state }

    override func screenDidAppear() {
        reload(fresh: false)
    }

    override func screenWillDisappear() {
        loadTask?.cancel()
    }

    func reload() {
        reload(fresh: true)
    }

    private func reload(fresh: Bool) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.load(fresh)
                guard !Task.isCancelled else { return }
                self.hasLoaded = true
                self.display(loaded)
            } catch {
                guard !Task.isCancelled, !self.hasLoaded else { return }
                MidgarLog.error("A web list failed to load: \(error)", category: .networking)
                self.state.isHidden = false
                self.state.show(.error(title: String(localized: "Couldn’t Load"), message: WebService.message(for: error),
                                       retryTitle: String(localized: "Retry"), retry: { [weak self] in
                                           self?.state.show(.loading(title: nil))
                                           self?.reload()
                                       }))
            }
        }
    }

    private func display(_ all: [WebEntry]) {
        var seen = Set<String>()
        shown = all.filter { seen.insert($0.id).inserted }
        refreshCards()
        let videos = shown.count
        heading.summary = videos == 0 ? nil : (videos == 1 ? String(localized: "1 video", comment: "Count under a web list's title")
                                                           : String(localized: "\(videos) videos", comment: "Count under a web list's title"))
        if shown.isEmpty {
            state.isHidden = false
            state.show(.empty(title: empty.title, message: empty.message, symbol: empty.symbol, action: nil))
        } else {
            if !state.isHidden { page.fadeIn() }
            state.isHidden = true
        }
        page.setNeedsLayout()
    }

    /// Draws the cards again, as after the viewer's progress in one of them moved.
    private func refreshCards() {
        grid.setItems(shown.map { WebCards.card($0, showsChannel: showsChannel, inGrid: true) })
    }

    override func layoutSubviews() {
        page.topInset = Theme.current.metrics.tabBarClearance
        page.frame = bounds
        state.frame = bounds
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

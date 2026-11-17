import CrucibleCore
import CrucibleUI
import CrucibleWeb
import Foundation
import Kiln
import MidgarCore

/// The YouTube destination: what the viewer began and did not finish, the newest videos of the channels they follow,
/// what they saved for later and those channels themselves, with Open Link, History and Settings as chips above. All of
/// it is the viewer's own library on this machine; with a browser's cookies set in Settings, the account's own
/// recommendations join as a row.
@MainActor
final class WebHomeScreen: ScreenView, Reloadable {
    private let page = PageView()
    private let heading = ScreenTitleView(title: WebCopy.destination)
    private let chips = ChipRowView()
    private let continueShelf = ShelfView(header: SectionHeader(title: String(localized: "Continue Watching")), style: .episode)
    private let feedShelf = ShelfView(header: SectionHeader(title: WebCopy.feed, hasSeeAll: true), style: .episode)
    private let recommendedShelf = ShelfView(header: SectionHeader(title: WebCopy.recommended, hasSeeAll: true), style: .episode)
    private let laterShelf = ShelfView(header: SectionHeader(title: WebCopy.watchLater, hasSeeAll: true), style: .episode)
    private let channelShelf = ShelfView(header: SectionHeader(title: WebCopy.channels), style: .person)
    private let state = StateView()
    private var entries: [String: WebEntry] = [:]
    private var feed: [WebEntry] = []
    private var recommended: [WebEntry] = []
    private var loadTask: Task<Void, Never>?
    private var recommendedTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var refreshQueued = false

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        [page, state].forEach(addSubview)
        state.isHidden = true
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        chips.onSelect = { [weak self] chip in self?.choose(chip.id) }
        for shelf in [continueShelf, feedShelf, recommendedShelf, laterShelf] {
            shelf.onActivate = { [weak self] card in
                guard let self, let entry = self.entries[card.id] else { return }
                WebActions.open(entry, from: self)
            }
            shelf.onPlay = { [weak self] card in
                guard let self, let entry = self.entries[card.id], entry.kind == .video else { return false }
                WebActions.play(entry, from: self)
                return true
            }
            shelf.onContextMenu = { [weak self] card, point in
                guard let self, let entry = self.entries[card.id] else { return }
                WebActions.presentMenu(for: entry, at: point, in: self)
            }
        }
        feedShelf.onSeeAll = { [weak self] in self?.rootView?.push(WebScreens.feed()) }
        laterShelf.onSeeAll = { [weak self] in self?.rootView?.push(WebScreens.watchLater()) }
        recommendedShelf.onSeeAll = { [weak self] in self?.rootView?.push(WebScreens.account(":ytrec", title: WebCopy.recommended)) }
        channelShelf.onActivate = { [weak self] card in
            guard let self, let channel = self.channel(for: card) else { return }
            self.rootView?.push(WebChannelScreen(address: channel.url, title: channel.title))
        }
        channelShelf.onContextMenu = { [weak self] card, point in
            guard let self, let channel = self.channel(for: card) else { return }
            self.presentChannelMenu(channel, at: point)
        }
        feed = WebService.shared.subscriptionsFeedAtHand
        render()
        observer = NotificationCenter.default.addObserver(forName: WebLibrary.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.libraryChanged() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        loadTask?.cancel()
        recommendedTask?.cancel()
    }

    private func channel(for card: CardItem) -> WebChannel? {
        let id = String(card.id.dropFirst((WebCards.prefix + "channel.").count))
        return WebService.shared.library.subscriptions.first { $0.id == id }
    }

    override var preferredFocusView: View? {
        if !state.isHidden { return state }
        return [continueShelf, feedShelf, recommendedShelf, laterShelf, channelShelf].first { $0.superview != nil && !$0.items.isEmpty } ?? chips
    }

    override func screenDidAppear() {
        load(fresh: false)
    }

    override func screenWillDisappear() {
        loadTask?.cancel()
        recommendedTask?.cancel()
    }

    func reload() {
        load(fresh: true)
    }

    private func load(fresh: Bool) {
        guard WebService.shared.isAvailable || WebService.shared.locateTool() else {
            render()
            return
        }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let loaded = await WebService.shared.subscriptionsFeed(fresh: fresh)
            guard let self, !Task.isCancelled else { return }
            self.feed = loaded
            self.render()
        }
        guard WebSettings.cookiesBrowser != nil else {
            recommended = []
            return
        }
        recommendedTask?.cancel()
        recommendedTask = Task { [weak self] in
            guard let listing = try? await WebService.shared.listing(":ytrec", limit: 30, fresh: fresh) else { return }
            guard let self, !Task.isCancelled else { return }
            self.recommended = listing.entries.filter { $0.kind == .video && !(WebSettings.hidesShorts && $0.isShort) }
            self.render()
        }
    }

    /// The library changes with every ten seconds of a playing video; the rows are drawn again once after a burst.
    private func libraryChanged() {
        guard !refreshQueued else { return }
        refreshQueued = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.refreshQueued = false
            self.feed = WebService.shared.subscriptionsFeedAtHand
            self.render()
            if self.window != nil, self.feed.isEmpty, !WebService.shared.library.subscriptions.isEmpty { self.load(fresh: false) }
        }
    }

    private func render() {
        guard WebService.shared.isAvailable else {
            state.isHidden = false
            state.show(.error(title: String(localized: "yt-dlp Is Missing", comment: "Title of the alert shown when web video cannot play"),
                              message: WebService.message(for: YtDlpError.notInstalled), retryTitle: String(localized: "Retry"), retry: { [weak self] in
                                  WebService.shared.locateTool()
                                  self?.load(fresh: false)
                              }))
            return
        }
        state.isHidden = true
        let library = WebService.shared.library
        let channels = library.subscriptions
        let unfinished = library.continueWatching.prefix(20).map(\.entry)
        let later = library.watchLater
        entries = [:]
        func fill(_ shelf: ShelfView, with listed: [WebEntry]) {
            for entry in listed { entries[WebCards.prefix + entry.id] = entry }
            shelf.setItems(listed.map { WebCards.card($0) })
        }
        fill(continueShelf, with: Array(unfinished))
        fill(feedShelf, with: Array(feed.prefix(24)))
        fill(recommendedShelf, with: Array(recommended.prefix(24)))
        fill(laterShelf, with: Array(later.prefix(24)))
        channelShelf.setItems(channels.map { WebCards.card($0) })
        var listed: [ChipRowView.Chip] = [
            .init(id: "link", title: WebCopy.openLink, symbol: "link"),
            .init(id: "search", title: String(localized: "Search"), symbol: "magnifyingglass"),
            .init(id: "history", title: String(localized: "History"), symbol: "clock.arrow.circlepath"),
        ]
        if !later.isEmpty { listed.append(.init(id: "later", title: WebCopy.watchLater, symbol: "clock")) }
        if WebSettings.cookiesBrowser != nil {
            listed.append(.init(id: "account.later", title: String(localized: "Account Watch Later", comment: "YouTube chip: the signed-in account's own Watch Later list"), symbol: "person.crop.circle"))
            listed.append(.init(id: "account.liked", title: String(localized: "Liked Videos", comment: "YouTube chip: the signed-in account's liked videos"), symbol: "hand.thumbsup"))
        }
        listed.append(.init(id: "settings", title: String(localized: "Settings"), symbol: "gearshape"))
        chips.setChips(listed)
        let isNew = channels.isEmpty && unfinished.isEmpty && later.isEmpty && recommended.isEmpty
        heading.detail = isNew ? WebCopy.welcome : nil
        heading.summary = channels.isEmpty ? nil : (channels.count == 1 ? String(localized: "1 channel", comment: "Count of followed channels")
                                                                        : String(localized: "\(channels.count) channels", comment: "Count of followed channels"))
        var sections: [View] = [heading, chips]
        for shelf in [continueShelf, feedShelf, recommendedShelf, laterShelf, channelShelf] where !shelf.items.isEmpty { sections.append(shelf) }
        page.setSections(sections)
        page.setNeedsLayout()
    }

    private func choose(_ id: String) {
        switch id {
        case "link": rootView?.presentOpenLink()
        case "search": rootView?.select("search")
        case "history": rootView?.push(WebScreens.history())
        case "later": rootView?.push(WebScreens.watchLater())
        case "account.later": rootView?.push(WebScreens.account(":ytwatchlater", title: WebCopy.watchLater))
        case "account.liked": rootView?.push(WebScreens.account(":ytfav", title: String(localized: "Liked Videos", comment: "YouTube chip: the signed-in account's liked videos")))
        case "settings": rootView?.push(WebSettingsScreen())
        default: break
        }
    }

    private func presentChannelMenu(_ channel: WebChannel, at point: Point?) {
        guard let window else { return }
        let frame = window.focusedView?.frameInWindow ?? frameInWindow
        let anchor = Rect(x: point.map { $0.x } ?? frame.minX, y: point.map { $0.y } ?? frame.maxY, width: 1, height: 1)
        let menu = MenuView(title: channel.title, items: [
            .init(id: "open", title: String(localized: "Open"), symbol: "chevron.right"),
            .init(id: "unfollow", title: String(localized: "Unfollow", comment: "Channel menu: stop following the channel"), symbol: "xmark.circle"),
            .init(id: "copy", title: String(localized: "Copy Link", comment: "Web video menu"), symbol: "link"),
        ], anchor: anchor)
        menu.onSelect = { [weak self] item in
            switch item.id {
            case "open": self?.rootView?.push(WebChannelScreen(address: channel.url, title: channel.title))
            case "unfollow": WebService.shared.library.unsubscribe(from: channel.id)
            case "copy": window.copy(channel.url)
            default: break
            }
        }
        menu.present(in: window)
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

/// The words web video's screens share.
enum WebCopy {
    static let destination = "YouTube"
    static let feed = String(localized: "New from Your Channels", comment: "YouTube row: the newest videos of followed channels")
    static let recommended = String(localized: "Recommended", comment: "YouTube row: the signed-in account's recommendations")
    static let watchLater = String(localized: "Watch Later", comment: "Web video menu: save the video for later")
    static let channels = String(localized: "Your Channels", comment: "YouTube row: the channels the viewer follows")
    static let openLink = String(localized: "Open Link…", comment: "Command that asks for the address of a video to play")
    static let welcome = String(localized: "Follow channels to see their newest videos here. Search for a channel or a video, open any link with Ctrl+L, or bring your subscriptions over in Settings. What you follow and watch stays on this computer.",
                                comment: "Shown on the YouTube page before the viewer follows any channel")
}

/// The lists web video's rows and chips open.
@MainActor
enum WebScreens {
    static func feed() -> WebListScreen {
        WebListScreen(title: WebCopy.feed, empty: .init(title: String(localized: "No Videos Yet", comment: "Empty subscriptions feed"),
                                                        message: String(localized: "The channels you follow haven’t posted lately.", comment: "Empty subscriptions feed")),
                      initial: WebService.shared.subscriptionsFeedAtHand) { fresh in
            await WebService.shared.subscriptionsFeed(fresh: fresh)
        }
    }

    static func watchLater() -> WebListScreen {
        WebListScreen(title: WebCopy.watchLater, empty: .init(symbol: "clock", message: String(localized: "Save a video for later from its menu.", comment: "Empty Watch Later"))) { _ in
            WebService.shared.library.watchLater
        }
    }

    static func history() -> WebListScreen {
        WebListScreen(title: String(localized: "History"), empty: .init(symbol: "clock.arrow.circlepath", message: String(localized: "Videos you watch show up here.", comment: "Empty web history"))) { _ in
            WebService.shared.library.history.map(\.entry)
        }
    }

    /// One of the signed-in account's own feeds, by yt-dlp's name for it (":ytrec", ":ytwatchlater", ":ytfav").
    static func account(_ feed: String, title: String) -> WebListScreen {
        WebListScreen(title: title) { fresh in
            try await WebService.shared.listing(feed, limit: 120, fresh: fresh).entries.filter { !(WebSettings.hidesShorts && $0.isShort) }
        }
    }

    /// A search of YouTube for `words`.
    static func search(_ words: String) -> WebListScreen {
        WebListScreen(title: String(localized: "“\(words)” on YouTube", comment: "Title of the full list of YouTube results for a search")) { fresh in
            try await WebService.shared.listing("ytsearch60:\(words)", limit: 60, fresh: fresh).entries
        }
    }
}

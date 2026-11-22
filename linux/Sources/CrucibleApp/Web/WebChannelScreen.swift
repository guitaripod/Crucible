import CrucibleCore
import CrucibleUI
import CrucibleWeb
import Foundation
import Kiln
import MidgarCore

/// A channel's page: its picture, name and following with Follow beside them, then its videos, live streams, Shorts and
/// playlists under chips. Each tab is one yt-dlp list, read when first shown.
@MainActor
final class WebChannelScreen: ScreenView, Reloadable {
    private enum Tab: String, CaseIterable {
        case videos, streams, shorts, playlists

        var title: String {
            switch self {
            case .videos: String(localized: "Videos", comment: "Channel page tab")
            case .streams: String(localized: "Live", comment: "Channel page tab: live streams and their recordings")
            case .shorts: String(localized: "Shorts", comment: "Channel page tab: short vertical clips")
            case .playlists: String(localized: "Playlists")
            }
        }
    }

    private let address: String
    private let page = PageView()
    private let header = WebChannelHeader()
    private let chips = ChipRowView()
    private let grid = CardGridView()
    private let state = StateView()
    private let gridState = StatusLineView()
    private var tab = Tab.videos
    private var listings: [Tab: [WebEntry]] = [:]
    private var channel: WebChannel?
    private var loadTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    /// `address` is the channel's page ("https://www.youtube.com/@name" or ".../channel/UC…"); `title` shows until the
    /// page has loaded.
    init(address: String, title: String) {
        self.address = address.hasSuffix("/") ? String(address.dropLast()) : address
        super.init()
        header.title = title
        [page, state].forEach(addSubview)
        page.setSections([header, chips, gridState, grid])
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        grid.aspect = 9.0 / 16.0
        grid.titleLines = 2
        gridState.isCentered = true
        chips.onSelect = { [weak self] chip in
            guard let self, let next = Tab(rawValue: chip.id), next != self.tab else { return }
            self.tab = next
            self.showTab()
            self.load(fresh: false)
        }
        header.onFollow = { [weak self] in self?.toggleFollow() }
        grid.onActivate = { [weak self] card in
            guard let self, let entry = self.entry(for: card) else { return }
            self.open(entry)
        }
        grid.onPlay = { [weak self] card in
            guard let self, let entry = self.entry(for: card), entry.kind == .video else { return false }
            self.open(entry)
            return true
        }
        grid.onContextMenu = { [weak self] card, point in
            guard let self, let entry = self.entry(for: card) else { return }
            WebActions.presentMenu(for: entry, at: point, in: self, showsChannel: false)
        }
        state.show(.loading(title: nil))
        showTab()
        observer = NotificationCenter.default.addObserver(forName: WebLibrary.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.libraryChanged() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        loadTask?.cancel()
    }

    private func entry(for card: CardItem) -> WebEntry? {
        listings[tab]?.first { WebCards.prefix + $0.id == card.id }
    }

    /// Opens what a card stands for; a Short opens the Shorts player on the tab's clips, starting with it.
    private func open(_ entry: WebEntry) {
        if tab == .shorts, entry.kind == .video {
            WebActions.playShorts(entry, among: listings[.shorts] ?? [], source: header.title, from: self)
        } else {
            WebActions.open(entry, from: self)
        }
    }

    override var preferredFocusView: View? {
        if !state.isHidden { return state }
        return grid.items.isEmpty ? chips : grid
    }

    override func screenDidAppear() {
        load(fresh: false)
    }

    override func screenWillDisappear() {
        loadTask?.cancel()
    }

    func reload() {
        load(fresh: true)
    }

    private func load(fresh: Bool) {
        if !fresh, listings[tab] != nil {
            showTab()
            return
        }
        let tab = tab
        let address = "\(address)/\(tab.rawValue)"
        gridState.show(listings[tab] == nil ? String(localized: "Loading…") : nil, busy: true)
        page.setNeedsLayout()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            do {
                let listing = try await WebService.shared.listing(address, limit: 90, fresh: fresh)
                guard let self, !Task.isCancelled else { return }
                self.adopt(listing)
                self.listings[tab] = listing.entries
                if self.tab == tab { self.showTab() }
            } catch {
                guard let self, !Task.isCancelled else { return }
                MidgarLog.error("A channel's \(tab.rawValue) failed to load: \(error)", category: .networking)
                if self.channel == nil, tab == .videos, self.listings.isEmpty {
                    self.state.isHidden = false
                    self.state.show(.error(title: String(localized: "Couldn’t Load"), message: WebService.message(for: error),
                                           retryTitle: String(localized: "Retry"), retry: { [weak self] in
                                               self?.state.show(.loading(title: nil))
                                               self?.reload()
                                           }))
                } else {
                    self.listings[tab] = self.listings[tab] ?? []
                    if self.tab == tab { self.showTab() }
                }
            }
        }
    }

    /// Takes the channel's name, picture and following from a list of its own, and keeps them with the subscription.
    private func adopt(_ listing: WebListing) {
        guard let id = listing.channelID else { return }
        let found = WebChannel(id: id, title: listing.channel ?? header.title, url: listing.channelURL ?? address, handle: listing.channelHandle,
                               avatar: listing.avatar)
        channel = found
        header.title = found.title
        header.avatar = WebArtwork.source(found.avatar)
        header.detail = [listing.channelHandle, listing.channelFollowers.map { count in
            String(localized: "\(Formatters.compactCount(count)) subscribers", comment: "How many follow a channel on its site, as in \"25.8M subscribers\"")
        }].compactMap { $0 }.joined(separator: " · ")
        header.isFollowed = WebService.shared.library.isSubscribed(to: id)
        header.canFollow = true
        WebService.shared.library.refresh(id, title: found.title, handle: found.handle, avatar: found.avatar)
        if !state.isHidden { page.fadeIn() }
        state.isHidden = true
        page.setNeedsLayout()
    }

    private func toggleFollow() {
        guard let channel else { return }
        let library = WebService.shared.library
        if library.isSubscribed(to: channel.id) {
            library.unsubscribe(from: channel.id)
        } else {
            library.subscribe(to: channel)
        }
    }

    private func libraryChanged() {
        if let channel { header.isFollowed = WebService.shared.library.isSubscribed(to: channel.id) }
        refreshCards()
    }

    private func showTab() {
        chips.setChips(Tab.allCases.map { ChipRowView.Chip(id: $0.rawValue, title: $0.title, isSelected: $0 == tab) })
        grid.aspect = tab == .shorts ? 16.0 / 9.0 : 9.0 / 16.0
        refreshCards()
        if let entries = listings[tab] {
            gridState.show(entries.isEmpty ? String(localized: "Nothing here yet.", comment: "A channel's tab with no videos") : nil)
        }
        page.setNeedsLayout()
    }

    private func refreshCards() {
        grid.setItems((listings[tab] ?? []).map { WebCards.card($0, showsChannel: false, inGrid: true, upright: tab == .shorts) })
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

/// The head of a channel's page: its round picture, its name, its handle and following, and Follow.
@MainActor
final class WebChannelHeader: View {
    var title = "" { didSet { superview?.setNeedsLayout(); setNeedsDisplay() } }
    var detail = "" { didSet { setNeedsDisplay() } }
    var avatar: ArtworkSource? { didSet { picture.source = avatar } }
    var isFollowed = false { didSet { if isFollowed != oldValue { updateButton() } } }
    var canFollow = false { didSet { follow.isHidden = !canFollow } }
    var onFollow: (() -> Void)?

    private let picture = ArtworkView()
    private let follow = ButtonView(style: .primary, title: nil)

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        follow.isHidden = true
        follow.onPress = { [weak self] in self?.onFollow?() }
        [picture, follow].forEach(addSubview)
        updateButton()
    }

    override var preferredFocusView: View? { follow.isHidden ? nil : follow }

    private func updateButton() {
        follow.style = isFollowed ? .glass : .primary
        follow.title = isFollowed ? String(localized: "Following", comment: "Button on a followed channel's page; pressing it unfollows")
                                  : String(localized: "Follow", comment: "Button that follows a channel")
        follow.symbol = isFollowed ? "checkmark" : "plus"
        setNeedsLayout()
    }

    private var diameter: Float { Theme.current.metrics.tv(150) }

    override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: diameter + Theme.current.metrics.tv(36))
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        picture.frame = Rect(x: metrics.sideMargin, y: 0, width: diameter, height: diameter)
        picture.cornerRadius = diameter / 2
        let size = follow.sizeThatFits(Size(width: frame.width, height: metrics.primaryControlHeight))
        follow.frame = Rect(x: frame.width - metrics.sideMargin - size.width, y: ((diameter - size.height) / 2).rounded(), width: size.width, height: size.height)
    }

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let theme = Theme.current
        let metrics = theme.metrics
        let x = picture.frame.maxX + metrics.tv(36)
        let width = max(follow.frame.minX - x - metrics.tv(36), 0)
        let name = TextLayout(title, font: theme.type.screenTitle, maxWidth: width, maxLines: 1, scale: scale)
        let line = TextLayout(detail, font: theme.type.callout, maxWidth: width, maxLines: 1, scale: scale)
        let height = name.size.height + (detail.isEmpty ? 0 : metrics.tv(6) + line.size.height)
        let y = ((diameter - height) / 2).rounded()
        context.text(name, at: Point(x: x, y: y), color: theme.palette.label)
        if !detail.isEmpty { context.text(line, at: Point(x: x, y: y + name.size.height + metrics.tv(6)), color: theme.palette.labelSecondary) }
    }
}

import CrucibleCore
import CrucibleUI
import CrucibleWeb
import Foundation
import Kiln
import MidgarCore

/// The YouTube inbox: new videos from every followed channel and, when the browser is signed in, the replies, mentions
/// and likes on the viewer's own comments. Cards are grouped under the day they arrived and only a page of them is made at
/// a time, so a thousand notifications open as quickly as ten; the rest arrive with Show More.
@MainActor
final class WebNotificationsScreen: ScreenView, Reloadable {
    private enum Filter: String {
        case all, videos, shorts, comments, unread

        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .videos: String(localized: "Videos")
            case .shorts: String(localized: "Shorts")
            case .comments: String(localized: "Comments")
            case .unread: String(localized: "Unread")
            }
        }
    }

    private enum ChipID {
        static let all = "all"
        static let videos = "videos"
        static let shorts = "shorts"
        static let comments = "comments"
        static let unread = "unread"
        static let signIn = "signIn"
        static let channels = "channels"
        static let markAll = "markAll"
        static let refresh = "refresh"
    }

    private static let pageSize = 60

    private let page = PageView()
    private let heading = ScreenTitleView(title: String(localized: "Notifications"))
    private let chips = ChipRowView()
    private let status = StatusLineView()
    private let grid = InboxGridView()
    private let state = StateView()
    private var items: [WebInboxItem] = []
    private var filter: Filter = .all
    private var channelID: String?
    private var limit = WebNotificationsScreen.pageSize
    private var loadTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var hasLoaded = false
    private var isChecking = false
    private var queued = false
    private var channelLookup: [String: WebChannel] = [:]
    private var seenRevision = -1
    private var seenFeedGeneration = -1
    private var seenWatchRevision = -1

    init() {
        super.init()
        [page, state].forEach(addSubview)
        state.isHidden = true
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        chips.onSelect = { [weak self] chip in self?.choose(chip.id) }
        grid.onActivate = { [weak self] card in self?.open(card) }
        grid.onContextMenu = { [weak self] card, point in self?.presentMenu(card, at: point) ?? false }
        grid.onToggleRead = { [weak self] card in self?.toggleRead(card) }
        grid.onToggleLater = { [weak self] card in self?.toggleLater(card) }
        grid.onToggleMute = { [weak self] card in self?.toggleMute(card) }
        grid.onMore = { [weak self] in self?.showMore() }
        observers.append(NotificationCenter.default.addObserver(forName: WebLibrary.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.libraryChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: WebService.notificationsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.libraryChanged() }
        })
        page.setSections([heading, chips, status, grid])
        state.show(.loading(title: nil))
        heading.detail = WebInboxCopy.explanation
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        loadTask?.cancel()
    }

    override var preferredFocusView: View? {
        if !state.isHidden { return state }
        return grid.preferredFocusView ?? chips
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
        loadTask?.cancel()
        isChecking = true
        let kept = WebService.shared.notificationItems
        if !kept.isEmpty {
            hasLoaded = true
            adopt(kept)
        } else {
            renderChrome()
        }
        loadTask = Task { [weak self] in
            _ = await WebService.shared.notificationsFeed(fresh: fresh)
            guard let self, !Task.isCancelled else { return }
            self.isChecking = false
            self.hasLoaded = true
            self.adopt(WebService.shared.notificationItems)
            Task { [weak self] in
                await WebService.shared.refreshAccountInbox(fresh: fresh)
                guard let self else { return }
                self.adopt(WebService.shared.notificationItems)
            }
        }
    }

    /// Takes the inbox as the library now stands, keeping the filters and the page the viewer has reached.
    private func adopt(_ newItems: [WebInboxItem]) {
        items = newItems
        channelLookup = [:]
        for channel in WebService.shared.library.subscriptions { channelLookup[channel.id] = channel }
        seenRevision = WebService.shared.library.notificationRevision
        seenFeedGeneration = WebService.shared.feedGeneration
        seenWatchRevision = WebService.shared.library.watchRevision
        if let channelID, !items.contains(where: { $0.entry.channelID == channelID }) { self.channelID = nil }
        render()
    }

    /// Library changes that cannot alter the inbox — a video's progress, a download finishing — are left alone, so the
    /// grid is not rebuilt every ten seconds of playback.
    private func libraryChanged() {
        guard rootView?.isCovered != true else { return }
        guard !queued else { return }
        let revision = WebService.shared.library.notificationRevision
        let generation = WebService.shared.feedGeneration
        let watch = WebService.shared.library.watchRevision
        guard revision != seenRevision || generation != seenFeedGeneration || watch != seenWatchRevision else { return }
        queued = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self else { return }
            self.queued = false
            self.adopt(WebService.shared.notificationItems)
        }
    }

    private var hasSubscriptions: Bool { !WebService.shared.library.subscriptions.isEmpty }

    private func filteredItems() -> [WebInboxItem] {
        items.filter { item in
            switch filter {
            case .all: break
            case .videos: if item.isComment || item.entry.isShort { return false }
            case .shorts: if item.isComment || !item.entry.isShort { return false }
            case .comments: if !item.isComment { return false }
            case .unread: if !item.isUnread { return false }
            }
            if let channelID { return item.entry.channelID == channelID }
            return true
        }
    }

    private func render() {
        guard hasLoaded || !items.isEmpty else {
            state.isHidden = false
            state.show(.loading(title: nil))
            renderChrome()
            return
        }
        guard hasSubscriptions else {
            state.isHidden = false
            state.show(.empty(title: WebInboxCopy.noChannelsTitle, message: WebInboxCopy.noChannelsMessage, symbol: "bell", action: nil))
            grid.setSections([])
            grid.moreTitle = nil
            renderChrome()
            page.setNeedsLayout()
            return
        }
        let shown = filteredItems()
        let paged = Array(shown.prefix(limit))
        if items.isEmpty {
            state.isHidden = false
            state.show(.empty(title: WebInboxCopy.caughtUpTitle, message: WebInboxCopy.caughtUpMessage, symbol: "checkmark.circle", action: nil))
            grid.setSections([])
            grid.moreTitle = nil
        } else {
            state.isHidden = true
            grid.setSections(sections(of: paged))
            grid.moreTitle = shown.count > paged.count ? WebInboxCopy.showMore(min(Self.pageSize, shown.count - paged.count),
                                                                                shown.count - paged.count) : nil
        }
        renderChrome()
        if !items.isEmpty, shown.isEmpty { status.show(WebInboxCopy.noMatches, busy: false) }
        page.setNeedsLayout()
    }

    private func sections(of items: [WebInboxItem]) -> [InboxGridView.Section] {
        var sections: [InboxGridView.Section] = []
        var current: WebInboxDay?
        var bucket: [WebInboxItem] = []
        func flush() {
            guard let current, !bucket.isEmpty else { return }
            let unread = bucket.lazy.filter(\.isUnread).count
            sections.append(.init(title: title(for: current), detail: unread > 0 ? String(localized: "\(unread) New") : nil,
                                  items: bucket.map(card)))
            bucket = []
        }
        for item in items {
            let day = WebInbox.day(of: item.entry.published ?? Date())
            if day != current {
                flush()
                current = day
            }
            bucket.append(item)
        }
        flush()
        return sections
    }

    private func title(for day: WebInboxDay) -> String {
        switch day {
        case .today: return String(localized: "Today")
        case .yesterday: return String(localized: "Yesterday")
        case .weekday(let weekday):
            let formatter = DateFormatter()
            let symbols = formatter.weekdaySymbols ?? []
            let index = weekday - 1
            return symbols.indices.contains(index) ? symbols[index] : String(localized: "Earlier")
        case .earlier: return String(localized: "Earlier")
        }
    }

    private func card(_ item: WebInboxItem) -> InboxCardItem {
        let entry = item.entry
        let channel = channelLookup[entry.channelID ?? ""]
        let note = item.note
        let title: String
        let context: String?
        if let note {
            let named = noteContext(note.kind)
            title = note.title.isEmpty ? (named ?? entry.title) : note.title
            context = note.title.isEmpty ? nil : named
        } else {
            title = entry.title
            context = nil
        }
        var facts: String?
        if note != nil {
            facts = entry.published.flatMap { Formatters.unixRelativeDate(Int($0.timeIntervalSince1970)) }
        } else {
            facts = [WebFormatting.facts(entry), item.isWatched ? String(localized: "Watched") : nil]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if facts?.isEmpty == true { facts = nil }
        }
        let avatar = note?.avatar ?? channel?.avatar
        let badge = entry.isLive ? String(localized: "LIVE") : (entry.isShort ? String(localized: "Shorts") : nil)
        return InboxCardItem(id: item.id, title: title, channel: note?.channel ?? entry.channel ?? channel?.title ?? "",
                             context: context, facts: facts, thumbnail: WebArtwork.inboxSource(for: entry),
                             avatar: WebArtwork.avatar(avatar), badge: badge, isComment: item.isComment, isUnread: item.isUnread,
                             isWatched: item.isWatched, canMute: entry.channelID != nil)
    }

    private func noteContext(_ kind: WebNote.Kind) -> String? {
        switch kind {
        case .reply: String(localized: "Replied to your comment")
        case .mention: String(localized: "Mentioned you")
        case .like: String(localized: "Liked your comment")
        case .live, .upload, .notice: nil
        }
    }

    private func showMore() {
        let shown = filteredItems()
        let reached = min(limit, shown.count)
        limit += Self.pageSize
        render()
        if reached < shown.count { _ = grid.focus(id: shown[reached].id) }
    }

    private func renderChrome() {
        let all = items
        var videos = 0
        var shorts = 0
        var comments = 0
        var unread = 0
        for item in all {
            if item.isUnread { unread += 1 }
            if item.isComment { comments += 1 }
            else if item.entry.isShort { shorts += 1 }
            else { videos += 1 }
        }
        var listed: [ChipRowView.Chip] = [
            .init(id: ChipID.all, title: "\(Filter.all.title) \(all.count)", isSelected: filter == .all),
            .init(id: ChipID.videos, title: "\(Filter.videos.title) \(videos)", isSelected: filter == .videos),
            .init(id: ChipID.shorts, title: "\(Filter.shorts.title) \(shorts)", isSelected: filter == .shorts),
            .init(id: ChipID.comments, title: "\(Filter.comments.title) \(comments)", isSelected: filter == .comments),
            .init(id: ChipID.unread, title: "\(Filter.unread.title) \(unread)", isSelected: filter == .unread),
            .init(id: ChipID.channels, title: channelTitle, symbol: "person.2", isSelected: channelID != nil, opensMenu: true),
        ]
        if !WebService.shared.canReadAccountInbox || WebService.shared.accountInboxSignedOut {
            listed.append(.init(id: ChipID.signIn, title: WebInboxCopy.signIn, symbol: "person.crop.circle"))
        }
        listed.append(.init(id: ChipID.markAll, title: String(localized: "Mark All as Read"), symbol: "checkmark.circle", isDimmed: unread == 0))
        listed.append(.init(id: ChipID.refresh, title: String(localized: "Refresh"), symbol: "arrow.clockwise"))
        chips.setChips(listed)
        heading.summary = unread > 0 ? String(localized: "\(unread) New") : nil
        heading.detail = all.isEmpty ? WebInboxCopy.explanation : nil
        if isChecking {
            status.show(WebInboxCopy.checking, busy: true)
        } else if WebService.shared.accountInboxSignedOut {
            status.show(WebInboxCopy.signedOut, busy: false, tone: .error)
        } else {
            status.show(nil, busy: false)
        }
        page.setNeedsLayout()
    }

    private var channelTitle: String {
        guard let channelID else { return String(localized: "Channels") }
        return items.first { $0.entry.channelID == channelID }?.entry.channel
            ?? channelLookup[channelID]?.title
            ?? String(localized: "Channels")
    }

    private func choose(_ id: String) {
        switch id {
        case ChipID.all, ChipID.videos, ChipID.shorts, ChipID.comments, ChipID.unread:
            filter = Filter(rawValue: id) ?? .all
            limit = Self.pageSize
            render()
        case ChipID.channels:
            presentChannelMenu()
        case ChipID.signIn:
            rootView?.push(WebSettingsScreen())
        case ChipID.markAll:
            let unread = items.filter(\.isUnread).map(\.id)
            guard !unread.isEmpty else { return }
            WebService.shared.library.markNotificationsRead(unread)
        case ChipID.refresh:
            load(fresh: true)
        default:
            break
        }
    }

    private func presentChannelMenu() {
        guard let window else { return }
        let counts = Dictionary(grouping: items.compactMap(\.entry.channelID), by: { $0 }).mapValues(\.count)
        let names = items.reduce(into: [String: String]()) { names, item in
            if let id = item.entry.channelID { names[id] = item.entry.channel ?? names[id] }
        }
        let channels = counts.keys.sorted { (names[$0] ?? "").localizedCaseInsensitiveCompare(names[$1] ?? "") == .orderedAscending }
        var menuItems: [MenuView.Item] = [.init(id: "", title: String(localized: "All Channels"), isChecked: channelID == nil)]
        menuItems += channels.map { id in
            MenuView.Item(id: id, title: names[id] ?? id, detail: "\(counts[id] ?? 0)", isChecked: channelID == id)
        }
        let library = WebService.shared.library
        let muted = library.notificationState.mutedChannels.map { id in
            (id: id, name: channelLookup[id]?.title ?? id)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        menuItems += muted.map { channel in
            MenuView.Item(id: "unmute:\(channel.id)", title: String(localized: "Unmute \(channel.name)"), symbol: "bell")
        }
        let anchor = chips.frameInWindow(of: ChipID.channels) ?? frameInWindow
        let menu = MenuView(title: String(localized: "Channels"), items: menuItems, anchor: anchor)
        menu.onSelect = { [weak self] item in
            guard let self else { return }
            if item.id.hasPrefix("unmute:") {
                library.setNotificationMuted(false, channelID: String(item.id.dropFirst("unmute:".count)))
                self.render()
                return
            }
            self.channelID = item.id.isEmpty ? nil : item.id
            self.limit = Self.pageSize
            self.render()
        }
        menu.present(in: window)
    }

    private func open(_ card: InboxCardItem) {
        guard let item = items.first(where: { $0.id == card.id }) else { return }
        WebService.shared.library.markNotificationsRead([item.id])
        if item.isComment {
            if item.entry.url.contains("watch") || item.entry.url.contains("shorts") {
                rootView?.push(WebVideoScreen(entry: item.entry))
            } else if let address = URL(string: item.entry.url) {
                Browser.open(address)
            }
        } else {
            WebActions.play(item.entry, from: self)
        }
    }

    private func toggleRead(_ card: InboxCardItem) {
        guard let item = items.first(where: { $0.id == card.id }) else { return }
        if item.isUnread { WebService.shared.library.markNotificationsRead([item.id]) }
        else { WebService.shared.library.markNotificationsUnread([item.id]) }
    }

    private func toggleLater(_ card: InboxCardItem) {
        guard let item = items.first(where: { $0.id == card.id }) else { return }
        let library = WebService.shared.library
        if library.isSavedForLater(item.entry.id) { library.removeFromWatchLater(item.entry.id) }
        else { library.saveForLater(item.entry) }
    }

    private func toggleMute(_ card: InboxCardItem) {
        guard let item = items.first(where: { $0.id == card.id }), let channelID = item.entry.channelID else { return }
        let library = WebService.shared.library
        library.setNotificationMuted(!library.isNotificationMuted(channelID: channelID), channelID: channelID)
    }

    private func presentMenu(_ card: InboxCardItem, at point: Point?) -> Bool {
        guard let item = items.first(where: { $0.id == card.id }), let window else { return false }
        let library = WebService.shared.library
        let channelID = item.entry.channelID
        let notification = WebActions.NotificationMenu(
            isUnread: item.isUnread,
            isMuted: channelID.map { library.isNotificationMuted(channelID: $0) } ?? false,
            markRead: { library.markNotificationsRead([item.id]) },
            markUnread: { library.markNotificationsUnread([item.id]) },
            toggleMute: {
                guard let channelID else { return }
                library.setNotificationMuted(!library.isNotificationMuted(channelID: channelID), channelID: channelID)
            })
        let frame = window.focusedView?.frameInWindow ?? frameInWindow
        let anchor = point ?? Point(x: frame.midX, y: frame.maxY)
        WebActions.presentMenu(for: item.entry, at: anchor, in: self, showsChannel: channelID != nil, afterChange: { [weak self] in
            self?.libraryChanged()
        }, notification: notification)
        return true
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

/// The words the YouTube inbox shares.
enum WebInboxCopy {
    static let explanation = String(localized: "New videos from the channels you follow, and replies to your comments when a browser is signed in, land here. What you read and hide stays on this computer.",
                                    comment: "Description under the title of the YouTube notifications screen")
    static let checking = String(localized: "Checking for New Videos…", comment: "YouTube notifications: the feeds are being read")
    static let caughtUpTitle = String(localized: "You’re All Caught Up", comment: "YouTube notifications with nothing new")
    static let caughtUpMessage = String(localized: "There’s nothing new right now.", comment: "YouTube notifications with nothing new")
    static let noChannelsTitle = String(localized: "No Channels Yet", comment: "YouTube notifications before following any channel")
    static let noChannelsMessage = String(localized: "Follow channels to see their new videos here.", comment: "YouTube notifications before following any channel")
    static let noMatches = String(localized: "Nothing matches these filters.", comment: "YouTube notifications: the chosen filters leave nothing")
    static let signIn = String(localized: "Sign In for Comments", comment: "YouTube notifications: opens the web video settings to sign in with a browser's cookies")
    static let signedOut = String(localized: "The browser needs signing in to YouTube again for replies and comments.",
                                  comment: "YouTube notifications: the cookies set in Settings no longer sign an account in")

    static func showMore(_ count: Int, _ left: Int) -> String {
        let more = String(localized: "Show \(count) More", comment: "YouTube notifications: the next page of cards")
        let remaining = String(localized: "\(left) Left", comment: "YouTube notifications: how many are not on screen yet")
        return "\(more) · \(remaining)"
    }
}

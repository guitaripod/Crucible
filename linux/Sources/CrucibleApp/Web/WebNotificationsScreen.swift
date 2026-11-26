import CrucibleCore
import CrucibleUI
import CrucibleWeb
import Foundation
import Kiln
import MidgarCore

/// The YouTube inbox: every new video from the channels the viewer follows, newest first, under the day it arrived,
/// with what is unread, what has been watched, filters for videos and Shorts, a way to silence a channel and a way to
/// mark everything read. Its rows play on select and offer the whole web menu on a right click.
@MainActor
final class WebNotificationsScreen: ScreenView, Reloadable {
    private enum Filter: String {
        case all, videos, shorts, unread

        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .videos: String(localized: "Videos")
            case .shorts: String(localized: "Shorts")
            case .unread: String(localized: "Unread")
            }
        }
    }

    private enum ChipID {
        static let all = "all"
        static let videos = "videos"
        static let shorts = "shorts"
        static let unread = "unread"
        static let channels = "channels"
        static let markAll = "markAll"
        static let refresh = "refresh"
    }

    private let page = PageView()
    private let heading = ScreenTitleView(title: String(localized: "Notifications"))
    private let chips = ChipRowView()
    private let status = StatusLineView()
    private let list = InboxListView()
    private let state = StateView()
    private var items: [WebInboxItem] = []
    private var filter: Filter = .all
    private var channelID: String?
    private var loadTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var hasLoaded = false
    private var isChecking = false
    private var queued = false

    init() {
        super.init()
        [page, state].forEach(addSubview)
        state.isHidden = true
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        chips.onSelect = { [weak self] chip in self?.choose(chip.id) }
        list.onActivate = { [weak self] row in self?.open(row) }
        list.onContextMenu = { [weak self] row, point in self?.presentMenu(row, at: point) ?? false }
        observers.append(NotificationCenter.default.addObserver(forName: WebLibrary.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.libraryChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: WebService.notificationsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.libraryChanged() }
        })
        page.setSections([heading, chips, status, list])
        state.show(.loading(title: nil))
        heading.detail = WebInboxCopy.explanation
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        loadTask?.cancel()
    }

    override var preferredFocusView: View? {
        if !state.isHidden { return state }
        return list.preferredFocusView ?? chips
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
        renderChrome()
        loadTask = Task { [weak self] in
            _ = await WebService.shared.notificationsFeed(fresh: fresh)
            guard let self, !Task.isCancelled else { return }
            self.isChecking = false
            self.hasLoaded = true
            self.adopt(WebService.shared.notificationItems)
        }
    }

    /// Takes the inbox as the library now stands, keeping the filters when they still have something to show.
    private func adopt(_ newItems: [WebInboxItem]) {
        items = newItems
        if let channelID, !items.contains(where: { $0.entry.channelID == channelID }) { self.channelID = nil }
        render()
    }

    private func libraryChanged() {
        guard !queued else { return }
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
            case .videos: if item.entry.isShort { return false }
            case .shorts: if !item.entry.isShort { return false }
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
            renderChrome()
            page.setNeedsLayout()
            return
        }
        let shown = filteredItems()
        if items.isEmpty {
            state.isHidden = false
            state.show(.empty(title: WebInboxCopy.caughtUpTitle, message: WebInboxCopy.caughtUpMessage, symbol: "checkmark.circle", action: nil))
        } else if shown.isEmpty {
            state.isHidden = true
        } else {
            state.isHidden = true
            status.show(isChecking ? WebInboxCopy.checking : nil, busy: isChecking)
        }
        let sections = sections(of: shown)
        list.setSections(sections)
        renderChrome()
        if !items.isEmpty, shown.isEmpty { status.show(WebInboxCopy.noMatches, busy: false) }
        page.setNeedsLayout()
    }

    private func sections(of shown: [WebInboxItem]) -> [InboxListView.Section] {
        var sections: [InboxListView.Section] = []
        var current: WebInboxDay?
        var bucket: [WebInboxItem] = []
        func flush() {
            guard let current, !bucket.isEmpty else { return }
            let unread = bucket.lazy.filter(\.isUnread).count
            sections.append(.init(title: title(for: current), detail: unread > 0 ? String(localized: "\(unread) New") : nil,
                                  items: bucket.map(row)))
            bucket = []
        }
        for item in shown {
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

    private func row(_ item: WebInboxItem) -> InboxRowItem {
        let entry = item.entry
        let channel = WebService.shared.library.subscriptions.first { $0.id == entry.channelID }
        var facts = [WebFormatting.facts(entry), item.isWatched ? String(localized: "Watched") : nil].compactMap { $0 }
        if facts.isEmpty { facts = [WebFormatting.byline(entry)].compactMap { $0 } }
        return InboxRowItem(id: entry.id, title: entry.title, channel: entry.channel ?? channel?.title ?? "",
                            facts: facts.joined(separator: " · "), thumbnail: WebArtwork.source(for: entry),
                            avatar: WebArtwork.source(channel?.avatar), isUnread: item.isUnread, isWatched: item.isWatched)
    }

    private func renderChrome() {
        let all = items
        let videos = all.lazy.filter { !$0.entry.isShort }.count
        let shorts = all.count - videos
        let unread = all.lazy.filter(\.isUnread).count
        var listed: [ChipRowView.Chip] = [
            .init(id: ChipID.all, title: "\(Filter.all.title) \(all.count)", isSelected: filter == .all),
            .init(id: ChipID.videos, title: "\(Filter.videos.title) \(videos)", isSelected: filter == .videos),
            .init(id: ChipID.shorts, title: "\(Filter.shorts.title) \(shorts)", isSelected: filter == .shorts),
            .init(id: ChipID.unread, title: "\(Filter.unread.title) \(unread)", isSelected: filter == .unread),
            .init(id: ChipID.channels, title: channelTitle, symbol: "person.2", isSelected: channelID != nil, opensMenu: true),
            .init(id: ChipID.markAll, title: String(localized: "Mark All as Read"), symbol: "checkmark.circle", isDimmed: unread == 0),
            .init(id: ChipID.refresh, title: String(localized: "Refresh"), symbol: "arrow.clockwise"),
        ]
        chips.setChips(listed)
        heading.summary = unread > 0 ? String(localized: "\(unread) New") : nil
        heading.detail = all.isEmpty ? WebInboxCopy.explanation : nil
        status.show(isChecking && !all.isEmpty ? WebInboxCopy.checking : nil, busy: isChecking && !all.isEmpty)
        page.setNeedsLayout()
    }

    private var channelTitle: String {
        guard let channelID else { return String(localized: "Channels") }
        return items.first { $0.entry.channelID == channelID }?.entry.channel ?? WebService.shared.library.subscriptions.first { $0.id == channelID }?.title
            ?? String(localized: "Channels")
    }

    private func choose(_ id: String) {
        switch id {
        case ChipID.all, ChipID.videos, ChipID.shorts, ChipID.unread:
            filter = Filter(rawValue: id) ?? .all
            render()
        case ChipID.channels:
            presentChannelMenu()
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
        var menuItems: [MenuView.Item] = [
            .init(id: "", title: String(localized: "All Channels"), isChecked: channelID == nil),
        ]
        menuItems += channels.map { id in
            MenuView.Item(id: id, title: names[id] ?? id, detail: "\(counts[id] ?? 0)", isChecked: channelID == id)
        }
        let library = WebService.shared.library
        let muted = library.notificationState.mutedChannels.map { id in
            (id: id, name: library.subscriptions.first { $0.id == id }?.title ?? id)
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
            self.render()
        }
        menu.present(in: window)
    }

    private func open(_ row: InboxRowItem) {
        guard let item = items.first(where: { $0.id == row.id }) else { return }
        WebService.shared.library.markNotificationsRead([item.id])
        WebActions.play(item.entry, from: self)
    }

    private func presentMenu(_ row: InboxRowItem, at point: Point?) -> Bool {
        guard let item = items.first(where: { $0.id == row.id }), let window else { return false }
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
        let frame = window.focusedView?.frameInWindow ?? rowFrame(for: row)
        let anchor = point.map { Point(x: $0.x, y: $0.y) } ?? Point(x: frame.midX, y: frame.maxY)
        WebActions.presentMenu(for: item.entry, at: anchor, in: self, afterChange: { [weak self] in
            self?.libraryChanged()
        }, notification: notification)
        return true
    }

    private func rowFrame(for row: InboxRowItem) -> Rect {
        (list.row(id: row.id)?.frameInWindow) ?? frameInWindow
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
    static let explanation = String(localized: "New videos from the channels you follow land here. What you read and hide stays on this computer.",
                                    comment: "Description under the title of the YouTube notifications screen")
    static let checking = String(localized: "Checking for New Videos…", comment: "YouTube notifications: the feeds are being read")
    static let caughtUpTitle = String(localized: "You’re All Caught Up", comment: "YouTube notifications with nothing new")
    static let caughtUpMessage = String(localized: "There’s nothing new right now.", comment: "YouTube notifications with nothing new")
    static let noChannelsTitle = String(localized: "No Channels Yet", comment: "YouTube notifications before following any channel")
    static let noChannelsMessage = String(localized: "Follow channels to see their new videos here.", comment: "YouTube notifications before following any channel")
    static let noMatches = String(localized: "Nothing matches these filters.", comment: "YouTube notifications: the chosen filters leave nothing")
}

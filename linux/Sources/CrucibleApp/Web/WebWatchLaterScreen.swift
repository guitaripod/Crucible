import CrucibleCore
import CrucibleUI
import CrucibleWeb
import Foundation
import Kiln

/// Watch Later as a guide: what the viewer began comes first, then what is left by how long it takes, live shows, and
/// what they watched already at the foot, dimmed. Telling it how much time there is dims every video that needs more, Play
/// All queues what is left, and Clear takes out what was watched or is too long, with an Undo.
@MainActor
final class WebWatchLaterScreen: ScreenView, Reloadable {
    private enum ChipID {
        static let play = "play"
        static let shuffle = "shuffle"
        static let time = "time"
        static let order = "order"
        static let clear = "clear"
        static let undo = "undo"
    }

    private let page = PageView()
    private let heading = ScreenTitleView(title: WebCopy.watchLater)
    private let chips = ChipRowView()
    private let status = MarginedStatusView()
    private let state = StateView()
    private var shelves: [WatchLaterGuide.Part: ShelfView] = [:]
    private var guide = WatchLaterGuide(saved: [], watch: { _ in nil })
    private var entries: [String: WebEntry] = [:]
    private var budget = WebSettings.watchLaterBudget
    private var order = WebSettings.watchLaterOrder
    private var undo: [WebEntry] = []
    private var hasRendered = false
    private var observer: NSObjectProtocol?

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        [page, state].forEach(addSubview)
        state.isHidden = true
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        chips.onSelect = { [weak self] chip in self?.choose(chip.id) }
        observer = NotificationCenter.default.addObserver(forName: WebLibrary.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.libraryChanged() }
        }
        render()
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override var preferredFocusView: View? {
        if !state.isHidden { return state }
        return guide.sections.compactMap { shelves[$0.part] }.first { !$0.items.isEmpty } ?? chips
    }

    override func screenDidAppear() {
        render()
    }

    override func screenWillDisappear() {
        undo = []
    }

    func reload() {
        render()
    }

    private func libraryChanged() {
        guard rootView?.isCovered != true else { return }
        render()
    }

    private func shelf(for part: WatchLaterGuide.Part) -> ShelfView {
        if let shelf = shelves[part] { return shelf }
        let shelf = ShelfView(header: nil, style: .episode)
        shelf.wraps = true
        shelf.collapsedLines = part == .watched ? 1 : 2
        shelf.onActivate = { [weak self] card in
            guard let self, let entry = self.entries[card.id] else { return }
            WebActions.open(entry, queue: self.queue(after: entry), from: self)
        }
        shelf.onPlay = { [weak self] card in
            guard let self, let entry = self.entries[card.id], entry.kind == .video else { return false }
            WebActions.play(entry, queue: self.queue(after: entry), from: self)
            return true
        }
        shelf.onContextMenu = { [weak self] card, point in
            guard let self, let entry = self.entries[card.id] else { return }
            WebActions.presentMenu(for: entry, at: point, in: self)
        }
        shelves[part] = shelf
        return shelf
    }

    /// The videos of the queue after `entry`, which play on one after another; none for a video outside the queue.
    private func queue(after entry: WebEntry) -> [WebEntry] {
        let queue = guide.queue
        guard let index = queue.firstIndex(where: { $0.id == entry.id }) else { return [] }
        return Array(queue[(index + 1)...])
    }

    private func render() {
        let saved = WebService.shared.library.watchLater
        let library = WebService.shared.library
        let fresh = WatchLaterGuide(saved: saved, watch: { library.watch(of: $0) }, budget: budget, order: order)
        let changed = fresh.sections != guide.sections
        guide = fresh
        entries = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        renderChrome()
        guard changed || !hasRendered else { return }
        hasRendered = true
        if guide.isEmpty {
            state.isHidden = false
            state.show(.empty(title: String(localized: "Nothing Saved", comment: "Empty Watch Later"),
                              message: String(localized: "Save a video for later from its menu.", comment: "Empty Watch Later"),
                              symbol: "clock", action: nil))
            page.setSections([heading, chips])
        } else {
            state.isHidden = true
            var visible: [View] = [heading, chips, status]
            for section in guide.sections {
                let shelf = shelf(for: section.part)
                shelf.header = SectionHeader(title: Self.title(of: section.part), secondaryText: Self.detail(of: section))
                shelf.setItems(section.items.map { card($0, part: section.part) })
                visible.append(shelf)
            }
            page.setSections(visible)
        }
        page.setNeedsLayout()
    }

    private func card(_ item: WatchLaterGuide.Item, part: WatchLaterGuide.Part) -> CardItem {
        var card = WebCards.card(item.entry)
        card.isDimmed = item.isWatched || !item.fits
        if part == .resume, let left = item.remaining, let runtime = HomeFormat.runtime(left) {
            let remaining = String(localized: "\(runtime) left", comment: "A saved web video the viewer began: the time still to watch")
            card.detail = [remaining, card.detail].compactMap { $0 }.joined(separator: " · ")
        }
        return card
    }

    private func renderChrome() {
        let hasWatched = !guide.watched.isEmpty
        let queue = guide.queue
        var listed: [ChipRowView.Chip] = [
            .init(id: ChipID.play, title: budget == .any ? String(localized: "Play All", comment: "Watch Later: plays every video left in the guide's order")
                                                         : String(localized: "Play What Fits", comment: "Watch Later: plays the videos that fit the time the viewer has"),
                  symbol: "play.fill", isSelected: true, isDimmed: queue.isEmpty),
            .init(id: ChipID.shuffle, title: String(localized: "Shuffle", comment: "Watch Later: plays the videos left in a random order"),
                  symbol: "shuffle", isDimmed: queue.count < 2),
            .init(id: ChipID.time, title: Self.title(of: budget), isSelected: budget != .any, opensMenu: true),
            .init(id: ChipID.order, title: Self.title(of: order), opensMenu: true),
            .init(id: ChipID.clear, title: String(localized: "Clear", comment: "Watch Later: opens a menu of ways to take videos out"),
                  isDimmed: guide.isEmpty, opensMenu: true),
        ]
        if !undo.isEmpty {
            listed.append(.init(id: ChipID.undo, title: String(localized: "Undo Remove (\(undo.count))", comment: "Watch Later: puts back the videos just cleared"),
                                symbol: "arrow.uturn.backward"))
        }
        chips.setChips(listed)
        heading.summary = Self.summary(of: guide)
        if budget != .any, !guide.isEmpty {
            status.show(Self.budgetLine(guide), busy: false)
        } else {
            status.show(nil, busy: false)
        }
    }

    private func choose(_ id: String) {
        switch id {
        case ChipID.play: play(guide.queue)
        case ChipID.shuffle: play(guide.queue.shuffled())
        case ChipID.time: presentTimeMenu()
        case ChipID.order: presentOrderMenu()
        case ChipID.clear: presentClearMenu()
        case ChipID.undo:
            WebService.shared.library.restoreToWatchLater(undo)
            undo = []
            render()
        default: break
        }
    }

    private func play(_ queue: [WebEntry]) {
        guard let first = queue.first else { return }
        WebActions.play(first, queue: Array(queue.dropFirst()), from: self)
    }

    private func presentTimeMenu() {
        guard let window else { return }
        let items = WatchLaterBudget.allCases.map { MenuView.Item(id: String($0.rawValue), title: Self.title(of: $0), isChecked: $0 == budget) }
        let menu = MenuView(title: String(localized: "Time You Have", comment: "Watch Later: menu that dims the videos longer than the time the viewer has"),
                            items: items, anchor: chips.frameInWindow(of: ChipID.time) ?? frameInWindow)
        menu.onSelect = { [weak self] item in
            guard let self, let raw = Int(item.id), let chosen = WatchLaterBudget(rawValue: raw) else { return }
            self.budget = chosen
            WebSettings.watchLaterBudget = chosen
            self.render()
        }
        menu.present(in: window)
    }

    private func presentOrderMenu() {
        guard let window else { return }
        let items = WatchLaterOrder.allCases.map { MenuView.Item(id: $0.rawValue, title: Self.title(of: $0), isChecked: $0 == order) }
        let menu = MenuView(title: String(localized: "Sort By", comment: "Watch Later: menu that orders the videos inside each part of the guide"),
                            items: items, anchor: chips.frameInWindow(of: ChipID.order) ?? frameInWindow)
        menu.onSelect = { [weak self] item in
            guard let self, let chosen = WatchLaterOrder(rawValue: item.id) else { return }
            self.order = chosen
            WebSettings.watchLaterOrder = chosen
            self.render()
        }
        menu.present(in: window)
    }

    private func presentClearMenu() {
        guard let window, !guide.isEmpty else { return }
        var items: [MenuView.Item] = []
        let watched = guide.watched
        let tooLong = guide.overBudget
        if !watched.isEmpty {
            items.append(.init(id: "watched", title: String(localized: "Remove Watched (\(watched.count))", comment: "Watch Later: takes out the videos already watched"),
                               symbol: "checkmark.circle"))
        }
        if !tooLong.isEmpty {
            items.append(.init(id: "long", title: String(localized: "Remove Too Long (\(tooLong.count))", comment: "Watch Later: takes out the videos longer than the time the viewer has"),
                               symbol: "hourglass"))
        }
        items.append(.init(id: "all", title: String(localized: "Remove All (\(guide.items.count))…", comment: "Watch Later: takes out every video, after asking"),
                           symbol: "trash"))
        let menu = MenuView(title: String(localized: "Clear", comment: "Watch Later: menu of ways to take videos out"), items: items,
                            anchor: chips.frameInWindow(of: ChipID.clear) ?? frameInWindow)
        menu.onSelect = { [weak self] item in
            guard let self else { return }
            switch item.id {
            case "watched": self.remove(watched)
            case "long": self.remove(tooLong)
            case "all": self.confirmRemoveAll()
            default: break
            }
        }
        menu.present(in: window)
    }

    private func confirmRemoveAll() {
        guard let window else { return }
        AlertView.confirm(title: String(localized: "Remove All from Watch Later?", comment: "Watch Later: asks before taking out every video"),
                          message: String(localized: "This takes out everything you saved. You can undo it until you leave the page.",
                                          comment: "Watch Later: what removing everything does"),
                          confirm: String(localized: "Remove All", comment: "Watch Later: button that confirms taking out every video"), in: window) { [weak self] in
            guard let self else { return }
            self.remove(self.guide.items.map(\.entry))
        }
    }

    /// Takes `removed` out of Watch Later, keeping the list as it was for Undo.
    private func remove(_ removed: [WebEntry]) {
        guard !removed.isEmpty else { return }
        let library = WebService.shared.library
        undo = library.watchLater
        library.removeFromWatchLater(ids: removed.map(\.id))
        render()
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

/// A status line kept in from the screen's side margins, as tall as its text.
@MainActor
private final class MarginedStatusView: View {
    private let line = StatusLineView()

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        addSubview(line)
    }

    func show(_ text: String?, busy: Bool) {
        line.show(text, busy: busy)
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    private var margin: Float { Theme.current.metrics.sideMargin }

    override func sizeThatFits(_ size: Size) -> Size {
        let fitted = line.sizeThatFits(Size(width: max(size.width - margin * 2, 1), height: size.height))
        return Size(width: size.width, height: fitted.height > 0 ? fitted.height + Theme.current.metrics.tv(16) : 0)
    }

    override func layoutSubviews() {
        line.frame = Rect(x: margin, y: 0, width: max(bounds.width - margin * 2, 1), height: bounds.height)
    }
}

private extension WebWatchLaterScreen {
    static func title(of part: WatchLaterGuide.Part) -> String {
        switch part {
        case .resume: String(localized: "Pick Up Where You Left Off", comment: "Watch Later: videos the viewer began")
        case .underTen: String(localized: "Under 10 Minutes", comment: "Watch Later: short videos")
        case .tenToThirty: String(localized: "10 to 30 Minutes", comment: "Watch Later: medium videos")
        case .thirtyToSixty: String(localized: "30 to 60 Minutes", comment: "Watch Later: long videos")
        case .overHour: String(localized: "Over an Hour", comment: "Watch Later: the longest videos")
        case .unknown: String(localized: "Length Unknown", comment: "Watch Later: videos whose length is not known")
        case .live: String(localized: "Live and Upcoming", comment: "Watch Later: broadcasts that are on or still to come")
        case .watched: String(localized: "Watched", comment: "Watch Later: videos already watched")
        }
    }

    static func title(of budget: WatchLaterBudget) -> String {
        switch budget {
        case .any: String(localized: "Any Length", comment: "Watch Later: no limit on how long a video may be")
        case .quarterHour: String(localized: "Up to 15 min", comment: "Watch Later: dims videos longer than a quarter of an hour")
        case .halfHour: String(localized: "Up to 30 min", comment: "Watch Later: dims videos longer than half an hour")
        case .hour: String(localized: "Up to 1 hour", comment: "Watch Later: dims videos longer than an hour")
        case .twoHours: String(localized: "Up to 2 hours", comment: "Watch Later: dims videos longer than two hours")
        }
    }

    static func title(of order: WatchLaterOrder) -> String {
        switch order {
        case .recent: String(localized: "Recently Saved", comment: "Watch Later: newest saved first")
        case .oldest: String(localized: "Saved Longest Ago", comment: "Watch Later: oldest saved first")
        case .shortest: String(localized: "Shortest First", comment: "Watch Later: shortest videos first")
        case .longest: String(localized: "Longest First", comment: "Watch Later: longest videos first")
        }
    }

    static func count(_ videos: Int) -> String {
        videos == 1 ? String(localized: "1 video", comment: "Count under a web list's title")
                    : String(localized: "\(videos) videos", comment: "Count under a web list's title")
    }

    static func detail(of section: WatchLaterGuide.Section) -> String {
        guard section.part != .watched, section.part != .live, section.part != .unknown, let time = HomeFormat.runtime(section.remaining) else { return count(section.items.count) }
        return String(localized: "\(count(section.items.count)) · \(time)", comment: "A Watch Later part: how many videos and how long they take together")
    }

    static func summary(of guide: WatchLaterGuide) -> String? {
        guard !guide.isEmpty else { return nil }
        let unwatched = guide.unwatched
        guard let time = HomeFormat.runtime(guide.remaining) else { return count(unwatched) }
        return String(localized: "\(count(unwatched)) · \(time) left", comment: "Under Watch Later's title: how many videos wait and how long they take")
    }

    static func budgetLine(_ guide: WatchLaterGuide) -> String {
        let fitting = guide.fitting
        let total = guide.unwatched
        guard fitting > 0 else {
            return String(localized: "Nothing fits the time you have. Everything is dimmed.", comment: "Watch Later: no video fits the time the viewer has")
        }
        return String(localized: "\(fitting) of \(total) fit the time you have. The rest are dimmed.", comment: "Watch Later: how many videos fit the time the viewer has")
    }
}

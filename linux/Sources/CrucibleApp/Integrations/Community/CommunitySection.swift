import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// A title page's Trakt community (`TVDetailViewController`'s community sections), after Cast & Crew: the pulse, what people
/// loved and did not, and the comments rail ending in See All and Write a Review. It loads after the page, from the cache
/// at once when it is fresh, and follows likes, reactions and posts as Trakt answers them.
@MainActor
final class CommunitySection {
    /// The sections changed shape (one appeared or went), so the page lays its sections out again.
    var onReshape: (() -> Void)?
    /// The title's name, for the screens the community opens.
    var titleName = ""

    private weak var host: ScreenView?
    private let api: APIClient
    private var ratingKey: String?
    private var snapshot: TraktCommunity.Snapshot?
    private var revealed = Set<Int>()
    private var barsAnimated = false
    private var loadTask: Task<Void, Never>?
    private var observer: (any NSObjectProtocol)?
    private var shape: [String] = []

    private let heading = SectionTitleView(title: TraktCommunityCopy.title)
    private let pulse = CommunityPulseContent()
    private lazy var pulsePanel = StatsPanelView(content: pulse)
    private lazy var pulseRow = MarginRow(content: pulsePanel)
    private let aspects = ChipRowView()
    private let rail = PanelShelfView(title: TraktCommunityCopy.comments, height: CommentCardContent.size.height)
    private var cards: [Int: (panel: StatsPanelView, content: CommentCardContent)] = [:]
    private var actions: [String: (panel: StatsPanelView, content: CommunityActionContent)] = [:]

    init(api: APIClient, host: ScreenView) {
        self.api = api
        self.host = host
        pulsePanel.onSelect = { [weak self] in self?.openWatching() }
        aspects.onSelect = { [weak self] chip in self?.openAspect(chip.id) }
    }

    /// Follows the community's changes while the page shows.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .traktCommunityChanged, object: nil, queue: .main) { [weak self] note in
            guard let change = note.object as? TraktCommunity.Change else { return }
            MainActor.assumeIsolated { self?.changed(change) }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        loadTask?.cancel()
    }

    /// Loads `ratingKey`'s community, showing the cached one at once when it is fresh.
    func load(ratingKey: String) {
        self.ratingKey = ratingKey
        guard TraktCommunity.shared.isAvailable else {
            if snapshot != nil { adopt(nil) }
            return
        }
        if snapshot == nil, let cached = TraktCommunity.shared.cachedSnapshot(ratingKey: ratingKey) {
            barsAnimated = true
            adopt(cached)
        }
        let api = api
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let loaded = await TraktCommunity.shared.snapshot(ratingKey: ratingKey, api: api)
            guard let self, !Task.isCancelled, let loaded, loaded != self.snapshot else { return }
            self.adopt(loaded)
        }
    }

    /// The community's sections, each only when it has something to show.
    var views: [View] {
        guard snapshot != nil, TraktCommunity.shared.isAvailable else { return [] }
        var views: [View] = []
        if hasPulse || hasAspects { views.append(heading) }
        if hasPulse { views.append(pulseRow) }
        if hasAspects { views.append(aspects) }
        views.append(rail)
        return views
    }

    private var hasPulse: Bool {
        guard let snapshot else { return false }
        return snapshot.score != nil || snapshot.distribution != nil || !(snapshot.stats?.isEmpty ?? true) || !snapshot.watching.isEmpty
    }

    private var hasAspects: Bool { !(snapshot?.sentiments?.isEmpty ?? true) }

    private func adopt(_ loaded: TraktCommunity.Snapshot?) {
        snapshot = loaded
        refresh()
    }

    /// Puts the snapshot into the views it already has, and asks the page to lay out again only when a section came or went.
    private func refresh() {
        guard let snapshot else {
            reshapeIfNeeded()
            return
        }
        pulse.apply(snapshot, animatesBars: !barsAnimated)
        barsAnimated = true
        pulsePanel.setNeedsLayout()
        if let sentiments = snapshot.sentiments {
            let good = sentiments.good.enumerated().map { ChipRowView.Chip(id: "good.\($0.offset)", title: "👍  \($0.element.text)") }
            let bad = sentiments.bad.enumerated().map { ChipRowView.Chip(id: "bad.\($0.offset)", title: "👎  \($0.element.text)") }
            aspects.setChips(good + bad)
        }
        rail.title = hasPulse || hasAspects ? TraktCommunityCopy.comments : TraktCommunityCopy.title
        rail.setPanels(railPanels(snapshot))
        reshapeIfNeeded()
    }

    private func reshapeIfNeeded() {
        let current = views.map { String(describing: ObjectIdentifier($0)) }
        guard current != shape else { return }
        shape = current
        onReshape?()
    }

    /// The comment cards, then See All when Trakt has more than the rail shows, then Write a Review.
    private func railPanels(_ snapshot: TraktCommunity.Snapshot) -> [View] {
        let community = TraktCommunity.shared
        var panels: [View] = []
        var seen = Set<Int>()
        for comment in snapshot.comments where seen.insert(comment.id).inserted {
            let card = cards[comment.id] ?? makeCard(comment.id)
            card.content.apply(comment: comment, isRevealed: revealed.contains(comment.id), isLiked: community.isLiked(comment.id),
                               summary: community.cachedSummary(comment.id), mine: community.reactions(of: comment.id), isMine: community.isMine(comment))
            panels.append(card.panel)
            if community.cachedSummary(comment.id) == nil { loadSummary(comment.id) }
        }
        cards = cards.filter { seen.contains($0.key) }
        if snapshot.commentCount > snapshot.comments.count {
            panels.append(actionPanel("more", kind: .seeAll(snapshot.commentCount)))
        }
        panels.append(actionPanel("write", kind: .write))
        return panels
    }

    private func makeCard(_ id: Int) -> (panel: StatsPanelView, content: CommentCardContent) {
        let content = CommentCardContent(commentID: id)
        let panel = StatsPanelView(content: content, flush: true)
        panel.onSelect = { [weak self] in self?.selectComment(id) }
        panel.onContextMenu = { [weak self] point in
            guard let self, let host = self.host, let comment = self.snapshot?.comments.first(where: { $0.id == id }) else { return }
            CommunityActions.presentMenu(for: comment, at: point, from: host)
        }
        cards[id] = (panel, content)
        return (panel, content)
    }

    private func actionPanel(_ slot: String, kind: CommunityActionContent.Kind) -> View {
        if let existing = actions[slot] {
            existing.content.kind = kind
            return existing.panel
        }
        let content = CommunityActionContent(kind)
        let panel = StatsPanelView(content: content, flush: true)
        panel.onSelect = { [weak self] in self?.selectAction(slot) }
        actions[slot] = (panel, content)
        return panel
    }

    private func loadSummary(_ id: Int) {
        Task { [weak self] in
            guard await TraktCommunity.shared.summary(for: id) != nil, let self else { return }
            self.refreshCard(id)
        }
    }

    private func refreshCard(_ id: Int) {
        guard let card = cards[id], let comment = snapshot?.comments.first(where: { $0.id == id }) else { return }
        let community = TraktCommunity.shared
        card.content.apply(comment: comment, isRevealed: revealed.contains(id), isLiked: community.isLiked(id), summary: community.cachedSummary(id),
                           mine: community.reactions(of: id), isMine: community.isMine(comment))
    }

    private func changed(_ change: TraktCommunity.Change) {
        switch change {
        case .reactions(let id):
            refreshCard(id)
        case .viewerState:
            cards.keys.forEach(refreshCard)
        default:
            guard let current = snapshot, let result = current.applying(change, isBlocked: TraktCommunity.shared.isBlocked) else { return }
            snapshot = result.snapshot
            refresh()
        }
    }

    // MARK: Opening

    /// A comment that hides spoilers shows them first; a revealed one opens its thread.
    private func selectComment(_ id: Int) {
        guard let comment = snapshot?.comments.first(where: { $0.id == id }) else { return }
        if comment.isSpoiler || TraktCommentText(comment.text).hasInlineSpoilers, !revealed.contains(id) {
            revealed.insert(id)
            refreshCard(id)
            return
        }
        host?.navigation?.push(CommentThreadScreen(comment: comment, subject: snapshot?.subject, titleName: titleName))
    }

    private func selectAction(_ slot: String) {
        guard let subject = snapshot?.subject else { return }
        if slot == "more" {
            host?.navigation?.push(CommentsScreen(source: .subject(subject), titleName: titleName))
        } else {
            host?.navigation?.push(CommentComposerScreen(mode: .new(subject, titleName: titleName)))
        }
    }

    private func openWatching() {
        guard let watching = snapshot?.watching, !watching.isEmpty else { return }
        host?.navigation?.push(TraktMembersScreen(title: TraktCommunityCopy.watchingNowTitle, detail: titleName, users: watching))
    }

    private func openAspect(_ id: String) {
        guard let sentiments = snapshot?.sentiments, let subject = snapshot?.subject else { return }
        let parts = id.split(separator: ".")
        guard parts.count == 2, let index = Int(parts[1]) else { return }
        let list = parts[0] == "good" ? sentiments.good : sentiments.bad
        guard list.indices.contains(index) else { return }
        host?.navigation?.push(CommentsScreen(source: .aspect(list[index], subject), titleName: titleName))
    }
}

/// A page section that holds one view within the side margins, as tall as the view asks to be.
@MainActor
final class MarginRow: View {
    let content: View

    init(content: View) {
        self.content = content
        super.init()
        addSubview(content)
    }

    private var margin: Float { Theme.current.metrics.sideMargin }
    private var padding: Float { Theme.current.metrics.shelfTopInset }

    override func sizeThatFits(_ size: Size) -> Size {
        let inner = content.sizeThatFits(Size(width: size.width - margin * 2, height: 0))
        return Size(width: size.width, height: inner.height + padding * 2)
    }

    override func layoutSubviews() {
        let height = content.sizeThatFits(Size(width: frame.width - margin * 2, height: 0)).height
        content.frame = Rect(x: margin, y: padding, width: frame.width - margin * 2, height: height)
    }
}

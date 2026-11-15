import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

/// The Community part of a title's page on iPhone and iPad, shared by the movie, episode and show pages: it loads the title's
/// Trakt community, says which items each of its three sections holds, lays them out, draws their cells and answers their
/// taps. The page owns the collection view and asks this block what to put in it.
@MainActor
final class TraktCommunityDetailBlock {
    enum Item: Hashable, Sendable {
        case pulse
        case sentiments
        case comment(Int)
        case unlock
        case actions
    }

    enum Part: Hashable, Sendable {
        case overview
        case comments
        case actions
    }

    private(set) var snapshot: TraktCommunity.Snapshot?
    private let api: APIClient
    private var ratingKey: String
    private weak var host: UIViewController?
    var titleName: String = ""
    /// The page applies a new snapshot of its sections: parts appeared, went or changed their items.
    var onStructureChange: (() -> Void)?
    /// The page reconfigures these items in place.
    var onReconfigure: (([Item]) -> Void)?

    private var revealed = Set<Int>()
    private var loadTask: Task<Void, Never>?
    private var changeObserver: NSObjectProtocol?
    private var proObserver: UUID?
    private var accountObserver: UUID?
    private var barsAnimated = false

    init(api: APIClient, ratingKey: String, host: UIViewController) {
        self.api = api
        self.ratingKey = ratingKey
        self.host = host
        snapshot = TraktCommunity.shared.cachedSnapshot(ratingKey: ratingKey)
        barsAnimated = snapshot != nil
        changeObserver = NotificationCenter.default.addObserver(forName: .traktCommunityChanged, object: nil, queue: .main) { [weak self] note in
            guard let change = note.object as? TraktCommunity.Change else { return }
            MainActor.assumeIsolated { self?.handle(change) }
        }
        proObserver = ProAccess.shared.observe { [weak self] _ in self?.onStructureChange?() }
        accountObserver = TraktAccount.shared.observe { [weak self] in
            guard let self, !TraktAccount.shared.isConnected, self.snapshot != nil else { return }
            self.snapshot = nil
            self.onStructureChange?()
        }
    }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        let pro = proObserver, account = accountObserver
        Task { @MainActor in
            if let pro { ProAccess.shared.stopObserving(pro) }
            if let account { TraktAccount.shared.stopObserving(account) }
        }
    }

    /// Loads the community when the page loads, without holding the page up; it fades in once Trakt answers.
    func load() {
        guard TraktCommunity.shared.isAvailable else {
            if snapshot != nil {
                snapshot = nil
                onStructureChange?()
            }
            return
        }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let loaded = await TraktCommunity.shared.snapshot(ratingKey: ratingKey, api: api)
            guard !Task.isCancelled, let loaded, loaded != snapshot else { return }
            snapshot = loaded
            onStructureChange?()
        }
    }

    func cancel() {
        loadTask?.cancel()
    }

    private var isUnlocked: Bool { TraktCommunity.shared.isUnlocked }

    // MARK: - Items

    /// Whether the page shows a Community part at all.
    var isVisible: Bool {
        snapshot != nil && TraktCommunity.shared.isAvailable
    }

    func items(in part: Part) -> [Item] {
        guard isVisible, let snapshot else { return [] }
        switch part {
        case .overview:
            var items: [Item] = []
            if snapshot.score != nil || snapshot.distribution != nil || !(snapshot.stats?.isEmpty ?? true) || !snapshot.watching.isEmpty {
                items.append(.pulse)
            }
            if let sentiments = snapshot.sentiments, !sentiments.isEmpty { items.append(.sentiments) }
            return items
        case .comments:
            guard !snapshot.comments.isEmpty else { return [] }
            if isUnlocked { return snapshot.comments.map { .comment($0.id) } }
            let free = snapshot.comments.prefix(TraktCommunity.freeCommentCount).map { Item.comment($0.id) }
            return free + (snapshot.commentCount > free.count ? [.unlock] : [])
        case .actions:
            return [.actions]
        }
    }

    /// The first part with items, which carries the Community heading.
    var headedPart: Part? {
        [Part.overview, .comments, .actions].first { !items(in: $0).isEmpty }
    }

    func comment(_ id: Int) -> TraktComment? {
        snapshot?.comments.first { $0.id == id }
    }

    // MARK: - Layout

    func layout(_ part: Part, environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let section: NSCollectionLayoutSection
        switch part {
        case .overview:
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(220))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
            section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = Theme.Space.s
            section.contentInsets = DetailLayout.rowInsets(top: 0, bottom: Theme.Space.s, environment: environment)
        case .comments:
            let room = Theme.Room(environment)
            let width: CGFloat = room == .compact ? min(310, environment.container.effectiveContentSize.width - 56) : 340
            let size = NSCollectionLayoutSize(widthDimension: .absolute(width), heightDimension: .estimated(250))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
            section = NSCollectionLayoutSection(group: group)
            section.orthogonalScrollingBehavior = .groupPaging
            section.interGroupSpacing = Theme.Space.s
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: room.gutter, bottom: Theme.Space.s, trailing: room.gutter)
        case .actions:
            section = DetailLayout.fullWidth(top: Theme.Space.xs, bottom: Theme.Space.l, environment: environment)
        }
        if headedPart == part {
            let header = DetailLayout.header()
            if part != .comments { header.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Theme.Space.m, bottom: 0, trailing: Theme.Space.m) }
            section.boundarySupplementaryItems = [header]
        }
        return section
    }

    // MARK: - Cells

    func configure(_ cell: UICollectionViewCell, item: Item) {
        guard let snapshot else { return }
        switch item {
        case .pulse:
            var config = TraktPulseConfiguration(score: snapshot.score, distribution: snapshot.distribution, stats: snapshot.stats, watching: snapshot.watching)
            config.animatesBars = !barsAnimated
            barsAnimated = true
            config.onWatching = { [weak self] in self?.openWatching() }
            cell.contentConfiguration = config
        case .sentiments:
            guard let sentiments = snapshot.sentiments else { return }
            var config = TraktSentimentsConfiguration(sentiments: sentiments, isLocked: !isUnlocked)
            config.onAspect = { [weak self] aspect in self?.openAspect(aspect) }
            config.onUnlock = { ProAccess.shared.requestUnlock(.traktCommunity) }
            cell.contentConfiguration = config
        case .comment(let id):
            guard let comment = comment(id) else { return }
            cell.contentConfiguration = commentConfiguration(comment)
            cell.accessibilityLabel = TraktCommunityCopy.accessibilityLabel(comment, hidingSpoilers: !revealed.contains(id))
        case .unlock:
            cell.contentConfiguration = TraktUnlockCardConfiguration(count: snapshot.commentCount)
        case .actions:
            var config = TraktCommunityActionsConfiguration(
                commentCount: snapshot.commentCount,
                showsSeeAll: snapshot.commentCount > 0,
                note: snapshot.commentCount == 0 ? "\(TraktCommunityCopy.emptyTitle). \(TraktCommunityCopy.emptyMessage)" : nil
            )
            config.onWrite = { [weak self] in self?.write() }
            config.onSeeAll = { [weak self] in self?.seeAll() }
            cell.contentConfiguration = config
        }
    }

    private func commentConfiguration(_ comment: TraktComment) -> TraktCommentConfiguration {
        let community = TraktCommunity.shared
        var config = TraktCommentConfiguration(comment: comment, style: .card)
        config.isMine = community.isMine(comment)
        config.isRevealed = revealed.contains(comment.id)
        config.isLiked = community.isLiked(comment.id)
        config.summary = community.cachedSummary(comment.id)
        config.mine = community.reactions(of: comment.id)
        config.onLike = { [weak self] in
            guard let self, let host = self.host else { return }
            TraktCommunityScreens.toggleLike(self.comment(comment.id) ?? comment, from: host)
        }
        config.onReplies = { [weak self] in self?.openThread(comment.id) }
        config.onReact = { [weak self] reaction in
            guard let host = self?.host else { return }
            TraktCommunityScreens.toggleReaction(reaction, on: comment.id, from: host)
        }
        config.onReveal = { [weak self] in self?.reveal(comment.id) }
        config.onAuthor = { [weak self] in
            guard let host = self?.host else { return }
            TraktCommunityScreens.openMember(comment.user, from: host)
        }
        return config
    }

    /// Fetches the reactions of a comment card as it comes on screen.
    func willDisplay(_ item: Item) {
        guard case .comment(let id) = item, TraktCommunity.shared.cachedSummary(id) == nil else { return }
        Task { [weak self] in
            guard await TraktCommunity.shared.summary(for: id) != nil else { return }
            self?.onReconfigure?([.comment(id)])
        }
    }

    // MARK: - Taps

    func canSelect(_ item: Item) -> Bool {
        switch item {
        case .comment, .unlock: return true
        default: return false
        }
    }

    func didSelect(_ item: Item) {
        switch item {
        case .comment(let id):
            guard let comment = comment(id) else { return }
            if comment.isSpoiler, !revealed.contains(id) { return reveal(id) }
            openThread(id)
        case .unlock:
            ProAccess.shared.requestUnlock(.traktCommunity)
        default:
            break
        }
    }

    func contextMenu(for item: Item) -> UIContextMenuConfiguration? {
        guard case .comment(let id) = item, let comment = comment(id), let host else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            TraktCommunityScreens.menu(for: comment, subject: self?.snapshot?.subject, titleName: self?.titleName, from: host, includesOpen: true)
        })
    }

    private func reveal(_ id: Int) {
        revealed.insert(id)
        onReconfigure?([.comment(id)])
    }

    private func openThread(_ id: Int) {
        guard let host, let comment = comment(id) else { return }
        let isFree = snapshot?.comments.prefix(TraktCommunity.freeCommentCount).contains { $0.id == id } ?? false
        TraktCommunityScreens.openThread(comment, subject: snapshot?.subject, titleName: titleName, isFree: isFree, from: host)
    }

    private func openWatching() {
        guard let host, let users = snapshot?.watching, !users.isEmpty else { return }
        TraktCommunityScreens.openWatching(users, titleName: titleName, from: host)
    }

    private func openAspect(_ aspect: TraktSentiments.Aspect) {
        guard let host, let subject = snapshot?.subject else { return }
        TraktCommunityScreens.openAspect(aspect, on: subject, titleName: titleName, from: host)
    }

    private func write() {
        guard let host, let subject = snapshot?.subject else { return }
        TraktCommunityScreens.compose(.new(subject, titleName: titleName), from: host)
    }

    private func seeAll() {
        guard let host, let subject = snapshot?.subject else { return }
        TraktCommunityScreens.openComments(on: subject, titleName: titleName, from: host)
    }

    // MARK: - Changes

    private func handle(_ change: TraktCommunity.Change) {
        guard let current = snapshot, let result = current.applying(change, isBlocked: TraktCommunity.shared.isBlocked) else { return }
        snapshot = result.snapshot
        if result.reshaped {
            onStructureChange?()
            return
        }
        switch change {
        case .updated(let comment): onReconfigure?([.comment(comment.id)])
        case .reactions(let id): onReconfigure?([.comment(id)])
        default: onReconfigure?([.pulse] + result.snapshot.comments.map { .comment($0.id) })
        }
    }
}

import CrucibleCore
import CrucibleDesign
import CrucibleIntelligence
import MidgarCore
@preconcurrency import UIKit

/// Every comment on a title, a page at a time as the list scrolls, in the order the viewer picks: most liked, newest, most
/// replies, highest or lowest rated, most watched or oldest. Opened from a sentiment, it lists the comments Trakt drew that
/// sentiment from instead. Each row likes, reacts, reveals its spoilers and opens its thread; the bar writes a new comment.
final class TraktCommentsViewController: UICollectionViewController {
    enum Source {
        case subject(TraktCommunitySubject)
        case aspect(TraktSentiments.Aspect, TraktCommunitySubject)

        var subject: TraktCommunitySubject {
            switch self {
            case .subject(let subject), .aspect(_, let subject): return subject
            }
        }
    }

    private enum Section: Hashable { case aspect, comments, more }

    private enum Item: Hashable {
        case aspect
        case comment(Int)
        case loading
    }

    private let source: Source
    private let titleName: String
    private var sort = TraktCommentSort.likes
    private var comments: [TraktComment] = []
    private var page = 0
    private var hasMore = true
    private var isLoading = false
    private var revealed = Set<Int>()
    private var loadTask: Task<Void, Never>?
    private var changeObserver: NSObjectProtocol?
    private var translationObserver: NSObjectProtocol?
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private lazy var sortItem = UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down"), menu: sortMenu())

    init(source: Source, titleName: String) {
        self.source = source
        self.titleName = titleName
        var list = UICollectionLayoutListConfiguration(appearance: .plain)
        list.backgroundColor = Theme.Color.canvas
        list.showsSeparators = true
        list.separatorConfiguration.color = Theme.Color.separator
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: list))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        if let translationObserver { NotificationCenter.default.removeObserver(translationObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = TraktCommunityCopy.comments
        if #available(iOS 26.0, *) { navigationItem.subtitle = titleName }
        navigationItem.largeTitleDisplayMode = .never
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.accessibilityIdentifier = "trakt.comments"
        let compose = UIBarButtonItem(systemItem: .compose, primaryAction: UIAction { [weak self] _ in self?.write() })
        compose.accessibilityLabel = TraktCommunityCopy.writeReview
        compose.accessibilityIdentifier = "trakt.comments.write"
        sortItem.accessibilityLabel = TraktCommunityCopy.sort
        sortItem.accessibilityIdentifier = "trakt.comments.sort"
        if case .subject = source {
            navigationItem.rightBarButtonItems = [compose, sortItem]
        } else {
            navigationItem.rightBarButtonItems = [compose]
        }
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)
        collectionView.refreshControl = refresh
        configureDataSource()
        changeObserver = NotificationCenter.default.addObserver(forName: .traktCommunityChanged, object: nil, queue: .main) { [weak self] note in
            guard let change = note.object as? TraktCommunity.Change else { return }
            MainActor.assumeIsolated { self?.handle(change) }
        }
        translationObserver = NotificationCenter.default.addObserver(forName: .translationChanged, object: nil, queue: .main) { [weak self] note in
            let key = note.object as? String
            MainActor.assumeIsolated { self?.aspectTranslationChanged(key) }
        }
        reload()
    }

    /// Redraws the aspect heading once its translation lands; the comments' own cells follow their translations.
    private func aspectTranslationChanged(_ key: String?) {
        guard case .aspect = source, key == nil || key?.hasPrefix(TraktSentimentsTranslation.prefix) == true else { return }
        var snapshot = dataSource.snapshot()
        guard snapshot.indexOfItem(.aspect) != nil else { return }
        snapshot.reconfigureItems([.aspect])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func configureDataSource() {
        let commentCell = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { [weak self] cell, _, id in
            guard let self, let comment = self.comments.first(where: { $0.id == id }) else { return }
            cell.contentConfiguration = self.configuration(for: comment)
            cell.backgroundConfiguration = .clear()
        }
        let aspectCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self, case .aspect(let aspect, _) = self.source else { return }
            var content = UIListContentConfiguration.subtitleCell().textSized()
            content.text = TraktSentimentsTranslation.text(aspect)
            content.textProperties.font = Theme.Font.title3
            content.secondaryText = TraktCommunityCopy.whatPeopleSay
            content.secondaryTextProperties.color = Theme.Color.labelSecondary
            content.image = UIImage(systemName: "sparkles")
            content.imageProperties.tintColor = Theme.Color.accent
            cell.contentConfiguration = content
            cell.backgroundConfiguration = .clear()
        }
        let loadingCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, _ in
            var content = UIListContentConfiguration.cell().textSized()
            content.text = " "
            cell.contentConfiguration = content
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .leading(), reservedLayoutWidth: .actual))]
            cell.backgroundConfiguration = .clear()
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .comment(let id): return collectionView.dequeueConfiguredReusableCell(using: commentCell, for: indexPath, item: id)
            case .aspect: return collectionView.dequeueConfiguredReusableCell(using: aspectCell, for: indexPath, item: item)
            case .loading: return collectionView.dequeueConfiguredReusableCell(using: loadingCell, for: indexPath, item: item)
            }
        }
    }

    private func configuration(for comment: TraktComment) -> TraktCommentConfiguration {
        let community = TraktCommunity.shared
        var config = TraktCommentConfiguration(comment: comment, style: .row)
        config.isMine = community.isMine(comment)
        config.isRevealed = revealed.contains(comment.id)
        config.isLiked = community.isLiked(comment.id)
        config.summary = community.cachedSummary(comment.id)
        config.mine = community.reactions(of: comment.id)
        config.menu = TraktCommunityScreens.menu(for: comment, subject: source.subject, titleName: titleName, from: self)
        config.onLike = { [weak self] in
            guard let self, let current = self.comments.first(where: { $0.id == comment.id }) else { return }
            TraktCommunityScreens.toggleLike(current, from: self)
        }
        config.onReplies = { [weak self] in self?.openThread(comment.id) }
        config.onReact = { [weak self] reaction in
            guard let self else { return }
            TraktCommunityScreens.toggleReaction(reaction, on: comment.id, from: self)
        }
        config.onReveal = { [weak self] in self?.reveal(comment.id) }
        config.onAuthor = { [weak self] in
            guard let self else { return }
            TraktCommunityScreens.openMember(comment.user, from: self)
        }
        config.onLink = { TraktCommunityScreens.open($0) }
        return config
    }

    private func sortMenu() -> UIMenu {
        UIMenu(title: TraktCommunityCopy.sort, options: .singleSelection, children: TraktCommentSort.allCases.map { option in
            UIAction(title: option.title, image: UIImage(systemName: option.symbol), state: option == sort ? .on : .off) { [weak self] _ in
                guard let self, self.sort != option else { return }
                Haptics.selection()
                self.sort = option
                self.sortItem.menu = self.sortMenu()
                self.reload()
            }
        })
    }

    // MARK: - Loading

    private func reload() {
        loadTask?.cancel()
        page = 0
        hasMore = true
        isLoading = false
        if comments.isEmpty { contentUnavailableConfiguration = CommentListSkeletonConfiguration() }
        loadNextPage(replacing: true)
    }

    private func loadNextPage(replacing: Bool = false) {
        guard !isLoading, hasMore || replacing else { return }
        isLoading = true
        let next = page + 1
        let source = source
        let sort = sort
        loadTask = Task { [weak self] in
            do {
                let found: [TraktComment]
                let more: Bool
                switch source {
                case .subject(let subject):
                    let result = try await TraktCommunity.shared.comments(on: subject, sort: sort, page: next)
                    found = result.items
                    more = result.hasMore(limit: TraktCommunityRoute.pageLimit)
                case .aspect(let aspect, _):
                    found = await TraktCommunity.shared.comments(ids: aspect.commentIDs)
                    more = false
                }
                guard let self, !Task.isCancelled else { return }
                self.page = next
                self.hasMore = more
                if replacing { self.comments = [] }
                let known = Set(self.comments.map(\.id))
                self.comments += found.filter { !known.contains($0.id) }
                self.isLoading = false
                self.collectionView.refreshControl?.endRefreshing()
                await self.apply()
                self.showState()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isLoading = false
                self.collectionView.refreshControl?.endRefreshing()
                MidgarLog.notice("Trakt comments not loaded: \(error.localizedDescription)", category: .trakt)
                if self.comments.isEmpty { self.showFailure(error) }
            }
        }
    }

    private func showState() {
        guard comments.isEmpty else {
            revealLoadedPage()
            return
        }
        var empty = UIContentUnavailableConfiguration.empty()
        empty.image = UIImage(systemName: "bubble.left.and.text.bubble.right")
        empty.text = TraktCommunityCopy.emptyTitle
        empty.secondaryText = TraktCommunityCopy.emptyMessage
        var button = Glass.prominentButton { .filled() }
        button.title = TraktCommunityCopy.writeReview
        button.baseBackgroundColor = Theme.Color.accent
        button.baseForegroundColor = Theme.Color.onAccent
        button.cornerStyle = .capsule
        empty.button = button
        empty.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.write() }
        contentUnavailableConfiguration = empty
    }

    private func showFailure(_ error: Error) {
        var failure = UIContentUnavailableConfiguration.empty()
        failure.image = UIImage(systemName: "exclamationmark.triangle")
        failure.text = TraktCommunityCopy.loadFailed
        failure.secondaryText = error.localizedDescription
        var button = UIButton.Configuration.filled()
        button.title = String(localized: "Retry")
        button.baseBackgroundColor = Theme.Color.accent
        button.baseForegroundColor = Theme.Color.onAccent
        button.cornerStyle = .capsule
        failure.button = button
        failure.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.reload() }
        contentUnavailableConfiguration = failure
    }

    private func apply(animated: Bool = false) async {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if case .aspect = source {
            snapshot.appendSections([.aspect])
            snapshot.appendItems([.aspect], toSection: .aspect)
        }
        snapshot.appendSections([.comments])
        snapshot.appendItems(comments.map { .comment($0.id) }, toSection: .comments)
        if hasMore, !comments.isEmpty {
            snapshot.appendSections([.more])
            snapshot.appendItems([.loading], toSection: .more)
        }
        await dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private func reconfigure(_ ids: [Int]) {
        var snapshot = dataSource.snapshot()
        let present = ids.map { Item.comment($0) }.filter { snapshot.indexOfItem($0) != nil }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Collection view

    override func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .loading:
            loadNextPage()
        case .comment(let id):
            if let index = comments.firstIndex(where: { $0.id == id }), index >= comments.count - 4 { loadNextPage() }
            guard TraktCommunity.shared.cachedSummary(id) == nil else { return }
            Task { [weak self] in
                guard await TraktCommunity.shared.summary(for: id) != nil else { return }
                self?.reconfigure([id])
            }
        default:
            break
        }
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        if case .comment = dataSource.itemIdentifier(for: indexPath) { return true }
        return false
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .comment(let id) = dataSource.itemIdentifier(for: indexPath),
              let comment = comments.first(where: { $0.id == id }) else { return }
        if comment.isSpoiler, !revealed.contains(id) { return reveal(id) }
        openThread(id)
    }

    override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, case .comment(let id) = dataSource.itemIdentifier(for: indexPath),
              let comment = comments.first(where: { $0.id == id }) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return TraktCommunityScreens.menu(for: comment, subject: self.source.subject, titleName: self.titleName, from: self, includesOpen: true)
        })
    }

    private func reveal(_ id: Int) {
        revealed.insert(id)
        reconfigure([id])
    }

    private func openThread(_ id: Int) {
        guard let comment = comments.first(where: { $0.id == id }) else { return }
        navigationController?.pushViewController(TraktCommentThreadViewController(comment: comment, subject: source.subject, titleName: titleName), animated: true)
    }

    private func write() {
        TraktCommunityScreens.compose(.new(source.subject, titleName: titleName), from: self)
    }

    private func handle(_ change: TraktCommunity.Change) {
        switch change {
        case .updated(let comment):
            guard let index = comments.firstIndex(where: { $0.id == comment.id }) else { return }
            comments[index] = comment
            reconfigure([comment.id])
        case .removed(let id):
            guard comments.contains(where: { $0.id == id }) else { return }
            comments.removeAll { $0.id == id }
            showState()
            Task { await apply(animated: true) }
        case .posted(let comment, let subjectKey):
            guard subjectKey == source.subject.key, case .subject = source, !comments.contains(where: { $0.id == comment.id }) else { return }
            comments.insert(comment, at: 0)
            showState()
            Task {
                await apply(animated: true)
                collectionView.scrollToItem(at: IndexPath(item: 0, section: 0), at: .top, animated: true)
            }
        case .reactions(let id):
            reconfigure([id])
        case .viewerState:
            reconfigure(comments.map(\.id))
        case .relationship:
            let before = comments.count
            comments.removeAll { TraktCommunity.shared.isBlocked($0.user.handle) }
            guard comments.count != before else { return }
            showState()
            Task { await apply(animated: true) }
        }
    }
}

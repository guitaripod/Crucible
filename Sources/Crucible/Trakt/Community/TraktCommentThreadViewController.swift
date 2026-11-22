import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

/// One comment with everything around it: its full text, every reaction with who left it, and its replies, a page at a time.
/// The toolbar replies; the comment's menu likes, reports, edits or deletes it.
final class TraktCommentThreadViewController: UICollectionViewController {
    private enum Section: Hashable { case root, reactions, replies, more }

    private enum Item: Hashable {
        case root
        case reactions
        case reply(Int)
        case loading
        case noReplies
        case repliesFailed
    }

    private var root: TraktComment
    private let subject: TraktCommunitySubject?
    private let titleName: String?
    private var replies: [TraktComment] = []
    private var reactors: [TraktReactionEntry] = []
    private var page = 0
    private var hasMore = true
    private var isLoading = false
    private var repliesFailed = false
    /// Counts what the viewer changed on this thread, so an answer asked for before a change does not undo it.
    private var localChanges = 0
    private var revealed = Set<Int>()
    private var changeObserver: NSObjectProtocol?
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(comment: TraktComment, subject: TraktCommunitySubject?, titleName: String?) {
        root = comment
        self.subject = subject
        self.titleName = titleName
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = root.isReview ? TraktCommunityCopy.review : TraktCommunityCopy.comments
        if #available(iOS 26.0, *), let titleName { navigationItem.subtitle = titleName }
        navigationItem.largeTitleDisplayMode = .never
        collectionView.collectionViewLayout = makeLayout()
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.accessibilityIdentifier = "trakt.thread"
        let share = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { return completion([]) }
            completion([TraktCommunityScreens.menu(for: self.root, subject: self.subject, titleName: self.titleName, from: self)])
        }]))
        share.accessibilityLabel = String(localized: "More")
        share.accessibilityIdentifier = "trakt.thread.more"
        navigationItem.rightBarButtonItem = share
        configureDataSource()
        changeObserver = NotificationCenter.default.addObserver(forName: .traktCommunityChanged, object: nil, queue: .main) { [weak self] note in
            guard let change = note.object as? TraktCommunity.Change else { return }
            MainActor.assumeIsolated { self?.handle(change) }
        }
        Task { await apply() }
        refreshRoot()
        loadReactions()
        loadNextPage()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !root.isReply else { return }
        var reply = Glass.prominentButton { .filled() }
        reply.title = TraktCommunityCopy.reply
        reply.image = UIImage(systemName: "arrowshape.turn.up.left.fill")
        reply.imagePadding = 8
        reply.cornerStyle = .capsule
        reply.baseBackgroundColor = Theme.Color.accent
        reply.baseForegroundColor = Theme.Color.onAccent
        let button = UIButton(configuration: reply, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            TraktCommunityScreens.compose(.reply(self.root), from: self)
        })
        button.accessibilityIdentifier = "trakt.thread.reply"
        toolbarItems = [UIBarButtonItem(systemItem: .flexibleSpace), UIBarButtonItem(customView: button), UIBarButtonItem(systemItem: .flexibleSpace)]
        navigationController?.setToolbarHidden(false, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    /// Plain rows without separators; the replies get a heading that counts them.
    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            var list = UICollectionLayoutListConfiguration(appearance: .plain)
            list.backgroundColor = Theme.Color.canvas
            list.showsSeparators = false
            let isReplies = self?.dataSource?.sectionIdentifier(for: index) == .replies
            list.headerMode = isReplies ? .supplementary : .none
            return NSCollectionLayoutSection.list(using: list, layoutEnvironment: environment)
        }
    }

    private func headerConfiguration() -> UIListContentConfiguration {
        var content = UIListContentConfiguration.groupedHeader().textSized()
        content.text = TraktCommunityCopy.replyCount(root.replyCount)
        content.textProperties.font = Theme.Font.headline
        content.textProperties.color = Theme.Color.label
        return content
    }

    private func refreshHeader() {
        for path in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: UICollectionView.elementKindSectionHeader) {
            (collectionView.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader, at: path) as? UICollectionViewListCell)?
                .contentConfiguration = headerConfiguration()
        }
    }

    private func configureDataSource() {
        let commentCell = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { [weak self] cell, _, id in
            guard let self else { return }
            let comment = id == self.root.id ? self.root : self.replies.first { $0.id == id }
            guard let comment else { return }
            cell.contentConfiguration = self.configuration(for: comment, style: id == self.root.id ? .root : .reply)
            cell.backgroundConfiguration = .clear()
        }
        let reactionsCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            var config = TraktReactionBarConfiguration(
                summary: TraktCommunity.shared.cachedSummary(self.root.id) ?? .empty,
                mine: TraktCommunity.shared.reactions(of: self.root.id),
                reactors: self.reactors
            )
            config.onToggle = { [weak self] reaction in
                guard let self else { return }
                TraktCommunityScreens.toggleReaction(reaction, on: self.root.id, from: self)
            }
            config.onReactors = { [weak self] in self?.openReactors() }
            cell.contentConfiguration = config
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
        let failedCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, _ in
            var content = UIListContentConfiguration.cell().textSized()
            content.text = String(localized: "Replies didn\u{2019}t load. Tap to try again.", comment: "Shown under a Trakt comment when its replies failed to load")
            content.textProperties.color = Theme.Color.labelSecondary
            content.textProperties.font = Theme.Font.subheadline
            content.image = UIImage(systemName: "arrow.clockwise")
            content.imageProperties.tintColor = Theme.Color.accent
            cell.contentConfiguration = content
            cell.backgroundConfiguration = .clear()
            cell.accessibilityIdentifier = "trakt.thread.retry"
        }
        let emptyCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, _ in
            var content = UIListContentConfiguration.cell().textSized()
            content.text = String(localized: "No replies yet.", comment: "Shown under a Trakt comment nobody replied to")
            content.textProperties.color = Theme.Color.labelSecondary
            content.textProperties.font = Theme.Font.subheadline
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.backgroundConfiguration = .clear()
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
            switch item {
            case .root: return collectionView.dequeueConfiguredReusableCell(using: commentCell, for: indexPath, item: self?.root.id ?? 0)
            case .reply(let id): return collectionView.dequeueConfiguredReusableCell(using: commentCell, for: indexPath, item: id)
            case .reactions: return collectionView.dequeueConfiguredReusableCell(using: reactionsCell, for: indexPath, item: item)
            case .loading: return collectionView.dequeueConfiguredReusableCell(using: loadingCell, for: indexPath, item: item)
            case .noReplies: return collectionView.dequeueConfiguredReusableCell(using: emptyCell, for: indexPath, item: item)
            case .repliesFailed: return collectionView.dequeueConfiguredReusableCell(using: failedCell, for: indexPath, item: item)
            }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, _ in
            guard let self else { return }
            cell.contentConfiguration = self.headerConfiguration()
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func configuration(for comment: TraktComment, style: TraktCommentConfiguration.Style) -> TraktCommentConfiguration {
        let community = TraktCommunity.shared
        var config = TraktCommentConfiguration(comment: comment, style: style)
        config.isMine = community.isMine(comment)
        config.isRevealed = revealed.contains(comment.id)
        config.isLiked = community.isLiked(comment.id)
        config.summary = style == .root ? nil : community.cachedSummary(comment.id)
        config.mine = community.reactions(of: comment.id)
        config.menu = TraktCommunityScreens.menu(for: comment, subject: subject, titleName: titleName, from: self)
        config.onLike = { [weak self] in
            guard let self else { return }
            let current = comment.id == self.root.id ? self.root : (self.replies.first { $0.id == comment.id } ?? comment)
            TraktCommunityScreens.toggleLike(current, from: self)
        }
        config.onReplies = { [weak self] in
            guard let self, !comment.isReply else { return }
            TraktCommunityScreens.compose(.reply(self.root), from: self)
        }
        config.onReact = { [weak self] reaction in
            guard let self else { return }
            TraktCommunityScreens.toggleReaction(reaction, on: comment.id, from: self)
        }
        config.onReveal = { [weak self] in
            self?.revealed.insert(comment.id)
            self?.reconfigure([comment.id == self?.root.id ? .root : .reply(comment.id)])
        }
        config.onAuthor = { [weak self] in
            guard let self else { return }
            TraktCommunityScreens.openMember(comment.user, from: self)
        }
        config.onLink = { TraktCommunityScreens.open($0) }
        return config
    }

    // MARK: - Loading

    private func refreshRoot() {
        let id = root.id
        let changes = localChanges
        Task { [weak self] in
            guard let fresh = try? await TraktCommunity.shared.comment(id), let self, self.localChanges == changes else { return }
            self.root = fresh
            self.reconfigure([.root])
            self.refreshHeader()
        }
    }

    private func loadReactions() {
        let id = root.id
        let changes = localChanges
        Task { [weak self] in
            let entries = (try? await TraktCommunity.shared.reactions(to: id)) ?? []
            if entries.isEmpty { _ = await TraktCommunity.shared.summary(for: id) }
            guard let self, self.localChanges == changes else { return }
            self.reactors = entries
            self.reconfigure([.reactions, .root])
        }
    }

    private func loadNextPage() {
        repliesFailed = false
        guard !isLoading, hasMore, !root.isReply else {
            if root.isReply { hasMore = false }
            return
        }
        isLoading = true
        let next = page + 1
        let id = root.id
        Task { [weak self] in
            do {
                let result = try await TraktCommunity.shared.replies(to: id, page: next)
                guard let self else { return }
                self.page = next
                self.hasMore = result.hasMore(limit: TraktCommunityRoute.pageLimit)
                let known = Set(self.replies.map(\.id))
                self.replies += result.items.filter { !known.contains($0.id) }
                self.isLoading = false
                await self.apply()
            } catch {
                guard let self else { return }
                self.isLoading = false
                self.repliesFailed = true
                MidgarLog.notice("Trakt replies not loaded: \(error.localizedDescription)", category: .trakt)
                await self.apply()
            }
        }
    }

    private func apply(animated: Bool = false) async {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.root, .reactions])
        snapshot.appendItems([.root], toSection: .root)
        snapshot.appendItems([.reactions], toSection: .reactions)
        if !root.isReply {
            snapshot.appendSections([.replies])
            if replies.isEmpty, !hasMore {
                snapshot.appendItems([.noReplies], toSection: .replies)
            } else {
                snapshot.appendItems(replies.map { .reply($0.id) }, toSection: .replies)
            }
            if repliesFailed {
                snapshot.appendSections([.more])
                snapshot.appendItems([.repliesFailed], toSection: .more)
            } else if hasMore {
                snapshot.appendSections([.more])
                snapshot.appendItems([.loading], toSection: .more)
            }
        }
        await dataSource.apply(snapshot, animatingDifferences: animated)
        refreshHeader()
    }

    private func reconfigure(_ items: [Item]) {
        var snapshot = dataSource.snapshot()
        let present = items.filter { snapshot.indexOfItem($0) != nil }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func openReactors() {
        let users = reactors.map(\.user)
        guard !users.isEmpty else { return }
        var reactions: [String: [TraktReaction]] = [:]
        for entry in reactors { reactions[entry.user.username, default: []].append(entry.reaction) }
        var seen = Set<String>()
        let unique = users.filter { seen.insert($0.username).inserted }
        let screen = TraktMembersViewController(title: TraktCommunityCopy.reactions, subtitle: nil, users: unique, reactions: reactions)
        let navigation = UINavigationController(rootViewController: screen)
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.medium(), .large()]
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        present(navigation, animated: true)
    }

    // MARK: - Collection view

    override func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .loading:
            loadNextPage()
        case .reply(let id):
            guard TraktCommunity.shared.cachedSummary(id) == nil else { return }
            Task { [weak self] in
                guard await TraktCommunity.shared.summary(for: id) != nil else { return }
                self?.reconfigure([.reply(id)])
            }
        default:
            break
        }
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) == .repliesFailed
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard dataSource.itemIdentifier(for: indexPath) == .repliesFailed else { return }
        loadNextPage()
        Task { await apply() }
    }

    override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first else { return nil }
        let comment: TraktComment?
        switch dataSource.itemIdentifier(for: indexPath) {
        case .root: comment = root
        case .reply(let id): comment = replies.first { $0.id == id }
        default: comment = nil
        }
        guard let comment else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return TraktCommunityScreens.menu(for: comment, subject: self.subject, titleName: self.titleName, from: self)
        })
    }

    private func handle(_ change: TraktCommunity.Change) {
        switch change {
        case .updated(let comment):
            if comment.id == root.id {
                localChanges += 1
                root = comment
                reconfigure([.root])
                Task { await apply() }
            } else if let index = replies.firstIndex(where: { $0.id == comment.id }) {
                replies[index] = comment
                reconfigure([.reply(comment.id)])
            }
        case .removed(let id):
            if id == root.id {
                navigationController?.popViewController(animated: true)
            } else if replies.contains(where: { $0.id == id }) {
                replies.removeAll { $0.id == id }
                root.replyCount = max(0, root.replyCount - 1)
                Task { await apply(animated: true) }
            }
        case .posted(let reply, _):
            guard reply.parentID == root.id, !replies.contains(where: { $0.id == reply.id }) else { return }
            replies.append(reply)
            root.replyCount = max(root.replyCount, replies.count)
            Task {
                await apply(animated: true)
                if let path = dataSource.indexPath(for: .reply(reply.id)) {
                    collectionView.scrollToItem(at: path, at: .bottom, animated: true)
                }
            }
        case .reactions(let id):
            if id == root.id {
                localChanges += 1
                let mine = TraktCommunity.shared.reactions(of: id)
                if let me = TraktAccount.shared.profile?.username {
                    reactors.removeAll { $0.user.username == me }
                    let viewer = TraktUser(username: me, name: TraktAccount.shared.profile?.name, isVIP: TraktAccount.shared.profile?.isVIP ?? false, slug: me, avatarURL: TraktAccount.shared.profile?.avatarURL)
                    reactors.insert(contentsOf: mine.map { TraktReactionEntry(reaction: $0, reactedAt: Date(), user: viewer) }, at: 0)
                }
                reconfigure([.reactions])
            } else {
                reconfigure([.reply(id)])
            }
        case .viewerState:
            reconfigure([.root, .reactions] + replies.map { .reply($0.id) })
        case .relationship:
            let before = replies.count
            replies.removeAll { TraktCommunity.shared.isBlocked($0.user.handle) }
            if TraktCommunity.shared.isBlocked(root.user.handle) {
                navigationController?.popViewController(animated: true)
            } else if replies.count != before {
                Task { await apply(animated: true) }
            }
        }
    }
}

/// Every reaction under a comment as a row of pills, each with its count and the viewer's own lit, so one tap adds or takes
/// back a reaction; under it, the faces of who reacted.
struct TraktReactionBarConfiguration: UIContentConfiguration {
    var summary: TraktReactionSummary
    var mine: Set<TraktReaction>
    var reactors: [TraktReactionEntry]
    var onToggle: ((TraktReaction) -> Void)?
    var onReactors: (() -> Void)?

    func makeContentView() -> UIView & UIContentView { TraktReactionBarContentView(configuration: self) }
    func updated(for state: UIConfigurationState) -> TraktReactionBarConfiguration { self }
}

final class TraktReactionBarContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let pills = UIStackView()
    private let reactorsButton = UIControl()
    private let faces = UIStackView()
    private let reactorsLabel = UILabel()

    init(configuration: TraktReactionBarConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        pills.axis = .horizontal
        pills.spacing = 6
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.clipsToBounds = false
        pills.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(pills)
        NSLayoutConstraint.activate([
            pills.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            pills.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            pills.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            pills.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            scroll.frameLayoutGuide.heightAnchor.constraint(equalTo: pills.heightAnchor),
        ])

        faces.axis = .horizontal
        faces.spacing = -8
        faces.isUserInteractionEnabled = false
        reactorsLabel.font = Theme.Font.footnote
        reactorsLabel.textColor = Theme.Color.labelSecondary
        reactorsLabel.adjustsFontForContentSizeCategory = true
        let row = UIStackView(arrangedSubviews: [faces, reactorsLabel])
        row.spacing = 10
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        reactorsButton.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: reactorsButton.topAnchor),
            row.bottomAnchor.constraint(equalTo: reactorsButton.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: reactorsButton.leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: reactorsButton.trailingAnchor),
        ])
        reactorsButton.addAction(UIAction { [weak self] _ in (self?.configuration as? TraktReactionBarConfiguration)?.onReactors?() }, for: .primaryActionTriggered)
        reactorsButton.isAccessibilityElement = true
        reactorsButton.accessibilityTraits = .button
        reactorsButton.accessibilityIdentifier = "trakt.thread.reactors"

        let stack = UIStackView(arrangedSubviews: [scroll, reactorsButton])
        stack.axis = .vertical
        stack.spacing = Theme.Space.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.s),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
        ])
        accessibilityIdentifier = "trakt.thread.reactions"
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? TraktReactionBarConfiguration else { return }
        pills.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for reaction in TraktReaction.allCases {
            let count = config.summary.counts[reaction] ?? 0
            let pill = TraktCommentFooterView.pill(reaction, count: count, mine: config.mine.contains(reaction)) {
                config.onToggle?(reaction)
            }
            pill.alpha = count == 0 && !config.mine.contains(reaction) ? 0.55 : 1
            pill.accessibilityIdentifier = "trakt.reaction.\(reaction.rawValue)"
            pills.addArrangedSubview(pill)
        }
        faces.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var seen = Set<String>()
        let people = config.reactors.map(\.user).filter { seen.insert($0.username).inserted }
        for user in people.prefix(6) {
            let avatar = TraktAvatarView(diameter: 24)
            avatar.configure(user)
            avatar.layer.borderWidth = 2
            avatar.layer.borderColor = Theme.Color.canvas.cgColor
            faces.addArrangedSubview(avatar)
        }
        reactorsButton.isHidden = people.isEmpty
        let names = people.prefix(2).map(\.displayName)
        let rest = people.count - names.count
        reactorsLabel.text = rest > 0
            ? String(localized: "\(names.joined(separator: ", ")) and \(rest) more reacted", comment: "Who reacted to a Trakt comment: two names and how many others")
            : String(localized: "\(names.joined(separator: ", ")) reacted", comment: "Who reacted to a Trakt comment: one or two names")
        reactorsButton.accessibilityLabel = reactorsLabel.text
    }
}

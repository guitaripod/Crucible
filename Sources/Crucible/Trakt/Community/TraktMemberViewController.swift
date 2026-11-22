import CrucibleCore
import CrucibleDesign
import CrucibleIntelligence
import MidgarCore
@preconcurrency import UIKit

/// A Trakt member: who they are, what they are watching right now and what they wrote lately, with Follow, Block and Report.
final class TraktMemberViewController: UICollectionViewController {
    private enum Section: Hashable { case profile, watching, comments }

    private enum Item: Hashable {
        case profile
        case watching
        case comment(Int)
        case privateNote
        case loading
    }

    private var user: TraktUser
    private var watching: TraktWatchingNow?
    private var following: TraktCommunity.Following?
    private var comments: [TraktUserComment] = []
    private var commentsLoaded = false
    private var commentsHidden = false
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var translationObserver: NSObjectProtocol?

    init(user: TraktUser) {
        self.user = user
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let translationObserver { NotificationCenter.default.removeObserver(translationObserver) }
    }

    /// Redraws the comments whose translation changed, so a preview turns into the reader's language as it lands.
    private func observeTranslations() {
        translationObserver = NotificationCenter.default.addObserver(forName: .translationChanged, object: nil, queue: .main) { [weak self] note in
            let key = note.object as? String
            MainActor.assumeIsolated {
                guard let self, self.dataSource != nil else { return }
                let changed = self.comments.filter { key == nil || TranslationCenter.key($0.comment) == key }.map { Item.comment($0.comment.id) }
                var snapshot = self.dataSource.snapshot()
                let present = changed.filter { snapshot.indexOfItem($0) != nil }
                guard !present.isEmpty else { return }
                snapshot.reconfigureItems(present)
                self.dataSource.apply(snapshot, animatingDifferences: false)
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        collectionView.collectionViewLayout = makeLayout()
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.accessibilityIdentifier = "trakt.member"
        if navigationController?.viewControllers.first === self {
            navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        }
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.moreMenu() ?? [])
        }]))
        more.accessibilityLabel = String(localized: "More")
        more.accessibilityIdentifier = "trakt.member.more"
        navigationItem.leftBarButtonItem = more
        configureDataSource()
        observeTranslations()
        Task { await apply() }
        load()
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            var list = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            list.backgroundColor = Theme.Color.canvas
            let section = self?.dataSource?.sectionIdentifier(for: index)
            list.headerMode = section == .comments || section == .watching ? .supplementary : .none
            return NSCollectionLayoutSection.list(using: list, layoutEnvironment: environment)
        }
    }

    private func configureDataSource() {
        let profileCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            var config = TraktMemberHeaderConfiguration(user: self.user, following: self.following, isMe: self.isMe)
            config.onFollow = { [weak self] in self?.toggleFollow() }
            cell.contentConfiguration = config
            cell.backgroundConfiguration = .clear()
        }
        let watchingCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let watching = self?.watching else { return }
            var content = UIListContentConfiguration.subtitleCell().textSized()
            content.text = watching.title
            content.secondaryText = watching.subtitle
            content.image = UIImage(systemName: "play.tv.fill")
            content.imageProperties.tintColor = .systemRed
            cell.contentConfiguration = content
        }
        let commentCell = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { [weak self] cell, _, id in
            guard let entry = self?.comments.first(where: { $0.comment.id == id }) else { return }
            var content = UIListContentConfiguration.subtitleCell().textSized()
            let text = TraktCommentText(TranslationCenter.shared.displayed(entry.comment).text)
            content.text = entry.comment.isSpoiler ? TraktCommunityCopy.spoilerCover : text.textHidingSpoilers
            content.textProperties.numberOfLines = 3
            content.textProperties.font = Theme.Font.subheadline
            content.secondaryText = [entry.itemTitle, TraktCommunityCopy.age(entry.comment.createdAt)].compactMap { $0 }.joined(separator: " · ")
            content.secondaryTextProperties.color = Theme.Color.labelSecondary
            content.image = UIImage(systemName: entry.comment.isReview ? "text.quote" : (entry.comment.isReply ? "arrowshape.turn.up.left" : "bubble.left"))
            content.imageProperties.tintColor = Theme.Color.accent
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
        let noteCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, _ in
            var content = UIListContentConfiguration.cell().textSized()
            content.text = TraktCommunityCopy.privateProfile
            content.image = UIImage(systemName: "lock.fill")
            content.textProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
        }
        let loadingCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, _ in
            var content = UIListContentConfiguration.cell().textSized()
            content.text = " "
            cell.contentConfiguration = content
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .leading(), reservedLayoutWidth: .actual))]
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .profile: return collectionView.dequeueConfiguredReusableCell(using: profileCell, for: indexPath, item: item)
            case .watching: return collectionView.dequeueConfiguredReusableCell(using: watchingCell, for: indexPath, item: item)
            case .comment(let id): return collectionView.dequeueConfiguredReusableCell(using: commentCell, for: indexPath, item: id)
            case .privateNote: return collectionView.dequeueConfiguredReusableCell(using: noteCell, for: indexPath, item: item)
            case .loading: return collectionView.dequeueConfiguredReusableCell(using: loadingCell, for: indexPath, item: item)
            }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader().textSized()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section) == .watching ? TraktCommunityCopy.watchingNowLabel : TraktCommunityCopy.recentComments
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private var isMe: Bool { TraktAccount.shared.profile?.username == user.username }

    private func load() {
        let handle = user.handle
        Task { [weak self] in
            async let profile = try? TraktCommunity.shared.profile(handle)
            async let watching = TraktCommunity.shared.watchingNow(handle)
            async let following = TraktCommunity.shared.following(handle)
            let loadedProfile = await profile
            let loadedWatching = await watching
            let loadedFollowing = await following
            guard let self else { return }
            if let loadedProfile { self.user = loadedProfile.keepingAvatar(of: self.user) }
            self.watching = loadedWatching
            self.following = loadedFollowing
            await self.apply()
            self.reconfigure(.profile)
            await self.loadComments()
        }
    }

    private func loadComments() async {
        do {
            let page = try await TraktCommunity.shared.comments(by: user.handle, page: 1, limit: 12)
            comments = page.items.filter { !TraktCommunity.shared.isBlocked($0.comment.user.handle) }
            commentsHidden = false
        } catch {
            commentsHidden = user.isPrivate
            MidgarLog.notice("Trakt member's comments not loaded: \(error.localizedDescription)", category: .trakt)
        }
        commentsLoaded = true
        await apply()
    }

    private func apply() async {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.profile])
        snapshot.appendItems([.profile], toSection: .profile)
        if watching != nil {
            snapshot.appendSections([.watching])
            snapshot.appendItems([.watching], toSection: .watching)
        }
        if !commentsLoaded {
            snapshot.appendSections([.comments])
            snapshot.appendItems([.loading], toSection: .comments)
        } else if commentsHidden {
            snapshot.appendSections([.comments])
            snapshot.appendItems([.privateNote], toSection: .comments)
        } else if !comments.isEmpty {
            snapshot.appendSections([.comments])
            snapshot.appendItems(comments.map { .comment($0.comment.id) }, toSection: .comments)
        }
        await dataSource.apply(snapshot, animatingDifferences: true)
    }

    private func reconfigure(_ item: Item) {
        var snapshot = dataSource.snapshot()
        guard snapshot.indexOfItem(item) != nil else { return }
        snapshot.reconfigureItems([item])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func toggleFollow() {
        let follow = (following ?? .notFollowing) == .notFollowing
        Haptics.light()
        Task { [weak self] in
            guard let self else { return }
            do {
                self.following = try await TraktCommunity.shared.setFollowing(follow, handle: self.user.handle)
                Haptics.success()
            } catch {
                self.presentTraktMessage(error.localizedDescription)
            }
            self.reconfigure(.profile)
        }
    }

    private func moreMenu() -> [UIMenuElement] {
        var elements: [UIMenuElement] = []
        if let url = user.webURL {
            elements.append(UIAction(title: TraktCommunityCopy.openOnTrakt, image: UIImage(systemName: "safari")) { _ in UIApplication.shared.open(url) })
        }
        guard !isMe else { return elements }
        let handle = user.handle
        if TraktCommunity.shared.isBlocked(handle) {
            elements.append(UIAction(title: TraktCommunityCopy.unblock, image: UIImage(systemName: "person.crop.circle.badge.checkmark")) { [weak self] _ in
                Task { [weak self] in
                    do { try await TraktCommunity.shared.unblock(handle) } catch { self?.presentTraktMessage(error.localizedDescription) }
                }
            })
        } else {
            elements.append(UIAction(title: TraktCommunityCopy.block, image: UIImage(systemName: "hand.raised"), attributes: .destructive) { [weak self] _ in
                self?.confirmBlock()
            })
        }
        elements.append(UIMenu(title: TraktCommunityCopy.report, image: UIImage(systemName: "flag"), children: TraktUserReportReason.allCases.map { reason in
            UIAction(title: reason.title) { [weak self] _ in
                Task { [weak self] in
                    do {
                        try await TraktCommunity.shared.report(user: handle, reason: reason)
                        guard let self else { return }
                        TraktToast.show(TraktCommunityCopy.reported, symbol: "flag.fill", in: self.navigationController?.view ?? self.view, belowBar: true)
                    } catch {
                        self?.presentTraktMessage(error.localizedDescription)
                    }
                }
            }
        }))
        return elements
    }

    private func confirmBlock() {
        let alert = UIAlertController(title: TraktCommunityCopy.blockTitle, message: TraktCommunityCopy.blockMessage, preferredStyle: .alert)
        let handle = user.handle
        alert.addAction(UIAlertAction(title: TraktCommunityCopy.block, style: .destructive) { [weak self] _ in
            Task { [weak self] in
                do {
                    try await TraktCommunity.shared.block(handle)
                    Haptics.success()
                    guard let self else { return }
                    self.following = .notFollowing
                    self.reconfigure(.profile)
                    TraktToast.show(TraktCommunityCopy.blocked, symbol: "hand.raised.fill", in: self.navigationController?.view ?? self.view, belowBar: true)
                } catch {
                    self?.presentTraktMessage(error.localizedDescription)
                }
            }
        })
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(alert, animated: true)
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        if case .comment = dataSource.itemIdentifier(for: indexPath) { return true }
        return false
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .comment(let id) = dataSource.itemIdentifier(for: indexPath), let entry = comments.first(where: { $0.comment.id == id }) else { return }
        navigationController?.pushViewController(TraktCommentThreadViewController(comment: entry.comment, subject: nil, titleName: entry.itemTitle), animated: true)
    }
}

/// The top of a member's page: a large face, their name and handle, badges, where they are and since when they are on Trakt,
/// what they say about themselves, and Follow.
struct TraktMemberHeaderConfiguration: UIContentConfiguration {
    var user: TraktUser
    var following: TraktCommunity.Following?
    var isMe: Bool
    var onFollow: (() -> Void)?

    func makeContentView() -> UIView & UIContentView { TraktMemberHeaderContentView(configuration: self) }
    func updated(for state: UIConfigurationState) -> TraktMemberHeaderConfiguration { self }
}

final class TraktMemberHeaderContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let avatar = TraktAvatarView(diameter: 92)
    private let name = UILabel()
    private let handle = UILabel()
    private let tags = UIStackView()
    private let meta = UILabel()
    private let about = UILabel()
    private let follow = UIButton(configuration: .plain())

    init(configuration: TraktMemberHeaderConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        name.font = Theme.Font.title2
        name.textColor = Theme.Color.label
        name.textAlignment = .center
        name.numberOfLines = 2
        name.adjustsFontForContentSizeCategory = true
        handle.font = Theme.Font.subheadline
        handle.textColor = Theme.Color.labelSecondary
        handle.adjustsFontForContentSizeCategory = true
        tags.axis = .horizontal
        tags.spacing = 6
        meta.font = Theme.Font.footnote
        meta.textColor = Theme.Color.labelSecondary
        meta.textAlignment = .center
        meta.numberOfLines = 0
        meta.adjustsFontForContentSizeCategory = true
        about.font = Theme.Font.callout
        about.textColor = Theme.Color.label
        about.textAlignment = .center
        about.numberOfLines = 0
        about.adjustsFontForContentSizeCategory = true
        follow.addAction(UIAction { [weak self] _ in (self?.configuration as? TraktMemberHeaderConfiguration)?.onFollow?() }, for: .primaryActionTriggered)
        follow.accessibilityIdentifier = "trakt.member.follow"
        let stack = UIStackView(arrangedSubviews: [avatar, name, handle, tags, meta, about, follow])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.setCustomSpacing(Theme.Space.s, after: avatar)
        stack.setCustomSpacing(Theme.Space.m, after: about)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.s),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.s),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? TraktMemberHeaderConfiguration else { return }
        let user = config.user
        avatar.configure(user)
        name.text = user.displayName
        handle.text = "@\(user.username)"
        handle.isHidden = user.name == nil
        tags.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if user.isVIP { tags.addArrangedSubview(TraktTag.vip.makeView()) }
        if user.isDirector { tags.addArrangedSubview(TraktTag.director.makeView()) }
        tags.isHidden = tags.arrangedSubviews.isEmpty
        var facts: [String] = []
        if let location = user.location { facts.append(location) }
        if let joined = user.joinedAt { facts.append(TraktCommunityCopy.joined(joined)) }
        if let years = user.vipYears, years > 0, user.isVIP { facts.append(TraktCommunityCopy.vipYears(years)) }
        meta.text = facts.joined(separator: "  ·  ")
        meta.isHidden = facts.isEmpty
        about.text = user.isPrivate ? TraktCommunityCopy.privateProfile : user.about
        about.isHidden = about.text == nil

        follow.isHidden = config.isMe || config.following == nil
        guard let following = config.following else { return }
        var button: UIButton.Configuration
        switch following {
        case .notFollowing:
            button = Glass.prominentButton { .filled() }
            button.title = TraktCommunityCopy.follow
            button.image = UIImage(systemName: "person.badge.plus")
            button.baseBackgroundColor = Theme.Color.accent
            button.baseForegroundColor = Theme.Color.onAccent
        case .following:
            button = Glass.glassButton { .tinted() }
            button.title = TraktCommunityCopy.following
            button.image = UIImage(systemName: "checkmark")
            button.baseForegroundColor = Theme.Color.label
        case .requested:
            button = Glass.glassButton { .tinted() }
            button.title = TraktCommunityCopy.requested
            button.image = UIImage(systemName: "clock")
            button.baseForegroundColor = Theme.Color.labelSecondary
        }
        button.imagePadding = 8
        button.cornerStyle = .capsule
        button.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 26, bottom: 10, trailing: 26)
        follow.configuration = button
    }
}

/// A list of Trakt members, such as who is watching a title right now or who reacted to a comment, each opening their page.
final class TraktMembersViewController: UICollectionViewController {
    private let users: [TraktUser]
    private let reactions: [String: [TraktReaction]]
    private let subtitle: String?
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    init(title: String, subtitle: String?, users: [TraktUser], reactions: [String: [TraktReaction]] = [:]) {
        self.users = users
        self.reactions = reactions
        self.subtitle = subtitle
        var list = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        list.backgroundColor = Theme.Color.canvas
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: list))
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 26.0, *), let subtitle { navigationItem.subtitle = subtitle }
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.accessibilityIdentifier = "trakt.members"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, username in
            guard let self, let user = self.users.first(where: { $0.username == username }) else { return }
            cell.contentConfiguration = TraktMemberRowConfiguration(user: user, reactions: self.reactions[username] ?? [])
            cell.accessories = [.disclosureIndicator()]
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, username in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: username)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        var seen = Set<String>()
        snapshot.appendItems(users.map(\.username).filter { seen.insert($0).inserted }, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let username = dataSource.itemIdentifier(for: indexPath), let user = users.first(where: { $0.username == username }) else { return }
        navigationController?.pushViewController(TraktMemberViewController(user: user), animated: true)
    }
}

/// One member in a list: face, name, handle and badges, and the reactions they left when the list is of reactions.
struct TraktMemberRowConfiguration: UIContentConfiguration {
    var user: TraktUser
    var reactions: [TraktReaction]

    func makeContentView() -> UIView & UIContentView { TraktMemberRowContentView(configuration: self) }
    func updated(for state: UIConfigurationState) -> TraktMemberRowConfiguration { self }
}

final class TraktMemberRowContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let avatar = TraktAvatarView(diameter: 40)
    private let name = UILabel()
    private let handle = UILabel()
    private let tags = UIStackView()
    private let emoji = UILabel()

    init(configuration: TraktMemberRowConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        name.font = Theme.Font.headline
        name.adjustsFontForContentSizeCategory = true
        name.textColor = Theme.Color.label
        handle.font = Theme.Font.footnote
        handle.adjustsFontForContentSizeCategory = true
        handle.textColor = Theme.Color.labelSecondary
        tags.spacing = 4
        let nameRow = UIStackView(arrangedSubviews: [name, tags])
        nameRow.spacing = 6
        nameRow.alignment = .center
        let texts = UIStackView(arrangedSubviews: [nameRow, handle])
        texts.axis = .vertical
        texts.spacing = 1
        texts.alignment = .leading
        emoji.font = Theme.Font.title3
        emoji.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [avatar, texts, emoji])
        row.spacing = Theme.Space.s
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
        ])
        isAccessibilityElement = true
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? TraktMemberRowConfiguration else { return }
        avatar.configure(config.user)
        name.text = config.user.displayName
        handle.text = "@\(config.user.username)"
        tags.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if config.user.isVIP { tags.addArrangedSubview(TraktTag.vip.makeView()) }
        if config.user.isDirector { tags.addArrangedSubview(TraktTag.director.makeView()) }
        emoji.text = config.reactions.map(\.emoji).joined()
        emoji.isHidden = config.reactions.isEmpty
        accessibilityLabel = ([config.user.displayName] + config.reactions.map(\.title)).joined(separator: ", ")
        accessibilityTraits = .button
    }
}

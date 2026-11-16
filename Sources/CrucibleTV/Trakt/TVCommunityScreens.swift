import CrucibleCore
import CrucibleDesign
import CrucibleIntelligence
import MidgarCore
import UIKit

/// Opens the community's screens and runs its actions on Apple TV: comments, threads, members, who is watching, the composer,
/// and the likes, reactions, reports and deletions a comment offers. What needs Pro asks for it first.
@MainActor
enum TVCommunityScreens {
    static func unlocked(_ action: @escaping @MainActor () -> Void) {
        guard !TraktCommunity.shared.isUnlocked else { return action() }
        ProAccess.shared.requestUnlock(.traktCommunity) { unlocked in
            if unlocked { action() }
        }
    }

    static func openComments(on subject: TraktCommunitySubject, titleName: String, from host: UIViewController) {
        unlocked { TVNavigation.push(TVCommentsViewController(source: .subject(subject), titleName: titleName), from: host) }
    }

    static func openAspect(_ aspect: TraktSentiments.Aspect, on subject: TraktCommunitySubject, titleName: String, from host: UIViewController) {
        unlocked { TVNavigation.push(TVCommentsViewController(source: .aspect(aspect, subject), titleName: titleName), from: host) }
    }

    /// Opens a comment's thread; `isFree` opens one of the comments a viewer without Pro reads in full.
    static func openThread(_ comment: TraktComment, subject: TraktCommunitySubject?, titleName: String?, isFree: Bool = false, from host: UIViewController) {
        let open = { TVNavigation.push(TVCommentThreadViewController(comment: comment, subject: subject, titleName: titleName), from: host) }
        if isFree {
            open()
            return
        }
        unlocked { open() }
    }

    static func openMember(_ user: TraktUser, from host: UIViewController) {
        unlocked { TVNavigation.push(TVTraktMemberViewController(user: user), from: host) }
    }

    static func openWatching(_ users: [TraktUser], titleName: String, from host: UIViewController) {
        unlocked { TVNavigation.push(TVTraktMembersViewController(title: TraktCommunityCopy.watchingNowTitle, detail: titleName, users: users), from: host) }
    }

    static func compose(_ mode: TVCommentComposerViewController.Mode, from host: UIViewController) {
        TVNavigation.push(TVCommentComposerViewController(mode: mode), from: host)
    }

    static func toggleLike(_ comment: TraktComment, from host: UIViewController) {
        let liking = !TraktCommunity.shared.isLiked(comment.id)
        Task { @MainActor [weak host] in
            do {
                try await TraktCommunity.shared.setLiked(liking, comment)
            } catch {
                host?.presentAlert(title: TraktCopy.name, message: error.localizedDescription)
            }
        }
    }

    static func toggleReaction(_ reaction: TraktReaction, on commentID: Int, from host: UIViewController) {
        let active = !TraktCommunity.shared.reactions(of: commentID).contains(reaction)
        Task { @MainActor [weak host] in
            do {
                try await TraktCommunity.shared.setReaction(reaction, active: active, on: commentID)
            } catch {
                host?.presentAlert(title: TraktCopy.name, message: error.localizedDescription)
            }
        }
    }

    /// The seven reactions as buttons, the viewer's own checked; choosing one adds it or takes it back.
    static func pickReaction(for commentID: Int, from host: UIViewController) {
        guard host.presentedViewController == nil else { return }
        let mine = TraktCommunity.shared.reactions(of: commentID)
        let sheet = UIAlertController(title: TraktCommunityCopy.react, message: nil, preferredStyle: .actionSheet)
        for reaction in TraktReaction.allCases {
            let title = "\(reaction.emoji)  \(reaction.title)" + (mine.contains(reaction) ? "  ✓" : "")
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak host] _ in
                guard let host else { return }
                toggleReaction(reaction, on: commentID, from: host)
            })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        host.present(sheet, animated: TVMotion.animationsEnabled)
    }

    static func report(_ comment: TraktComment, from host: UIViewController) {
        guard host.presentedViewController == nil else { return }
        let sheet = UIAlertController(title: TraktCommunityCopy.reportTitle, message: nil, preferredStyle: .actionSheet)
        for reason in TraktCommentReportReason.allCases {
            sheet.addAction(UIAlertAction(title: reason.title, style: .default) { [weak host] _ in
                Task { @MainActor [weak host] in
                    do {
                        try await TraktCommunity.shared.report(comment, reason: reason)
                        host?.presentAlert(title: TraktCommunityCopy.reported)
                    } catch {
                        host?.presentAlert(title: TraktCopy.name, message: error.localizedDescription)
                    }
                }
            })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        host.present(sheet, animated: TVMotion.animationsEnabled)
    }

    static func confirmDelete(_ comment: TraktComment, from host: UIViewController, then: (@MainActor () -> Void)? = nil) {
        host.presentConfirmation(title: TraktCommunityCopy.deleteTitle, message: TraktCommunityCopy.deleteMessage, confirmTitle: TraktCommunityCopy.delete) { [weak host] in
            Task { @MainActor [weak host] in
                do {
                    try await TraktCommunity.shared.delete(comment)
                    then?()
                } catch {
                    host?.presentAlert(title: TraktCopy.name, message: error.localizedDescription)
                }
            }
        }
    }

    /// A comment's long-press menu: like, react, report, or edit and delete for the viewer's own.
    static func menu(for comment: TraktComment, from host: UIViewController) -> UIMenu {
        let community = TraktCommunity.shared
        let liked = community.isLiked(comment.id)
        var children: [UIMenuElement] = [
            UIAction(title: liked ? TraktCommunityCopy.unlike : TraktCommunityCopy.like, image: UIImage(systemName: liked ? "heart.slash" : "heart")) { [weak host] _ in
                guard let host else { return }
                toggleLike(comment, from: host)
            },
            UIMenu(title: TraktCommunityCopy.react, image: UIImage(systemName: "face.smiling"), children: TraktReaction.allCases.map { reaction in
                UIAction(title: "\(reaction.emoji)  \(reaction.title)", state: community.reactions(of: comment.id).contains(reaction) ? .on : .off) { [weak host] _ in
                    guard let host else { return }
                    toggleReaction(reaction, on: comment.id, from: host)
                }
            }),
        ]
        if let translation = translationAction(for: comment) { children.append(translation) }
        if community.isMine(comment) {
            children.append(UIAction(title: TraktCommunityCopy.edit, image: UIImage(systemName: "pencil")) { [weak host] _ in
                guard let host else { return }
                compose(.edit(comment), from: host)
            })
            children.append(UIAction(title: TraktCommunityCopy.delete, image: UIImage(systemName: "trash"), attributes: .destructive) { [weak host] _ in
                guard let host else { return }
                confirmDelete(comment, from: host)
            })
        } else {
            children.append(UIMenu(title: TraktCommunityCopy.report, image: UIImage(systemName: "flag"), children: TraktCommentReportReason.allCases.map { reason in
                UIAction(title: reason.title) { [weak host] _ in
                    Task { @MainActor [weak host] in
                        do {
                            try await TraktCommunity.shared.report(comment, reason: reason)
                            host?.presentAlert(title: TraktCommunityCopy.reported)
                        } catch {
                            host?.presentAlert(title: TraktCopy.name, message: error.localizedDescription)
                        }
                    }
                }
            }))
        }
        return UIMenu(children: children)
    }

    /// "♥ 12" for a row's value, the reactions after it when there are any.
    static func countsValue(_ comment: TraktComment, summary: TraktReactionSummary?) -> String {
        var parts = ["♥ \(Formatters.compactCount(comment.likeCount))"]
        if comment.replyCount > 0 { parts.append("💬 \(Formatters.compactCount(comment.replyCount))") }
        if let top = summary?.ranked.first { parts.append("\(top.reaction.emoji) \(Formatters.compactCount(top.count))") }
        return parts.joined(separator: "  ")
    }

    /// A comment's text for a row or a column, spoilers hidden unless `revealed`, in the reader's language once translated.
    static func text(_ comment: TraktComment, revealed: Bool) -> String {
        if comment.isSpoiler && !revealed { return TraktCommunityCopy.spoilerCover + " · " + TraktCommunityCopy.pressToReveal }
        let text = TraktCommentText(TranslationCenter.shared.displayed(comment).text)
        return revealed ? text.plainText : text.textHidingSpoilers
    }

    /// Translate, Show Original or Show Translation for a comment in another language, or nil for one in the reader's.
    static func translationAction(for comment: TraktComment) -> UIAction? {
        let center = TranslationCenter.shared
        switch center.presentation(for: comment).phase {
        case .offer, .failed:
            return UIAction(title: TranslationCopy.translate, image: UIImage(systemName: "translate")) { _ in center.translate(comment) }
        case .translated:
            return UIAction(title: TranslationCopy.showOriginal, image: UIImage(systemName: "text.bubble")) { _ in center.toggleOriginal(comment) }
        case .original:
            return UIAction(title: TranslationCopy.showTranslation, image: UIImage(systemName: "translate")) { _ in center.toggleOriginal(comment) }
        case .translating, .none:
            return nil
        }
    }

    /// Calls `refresh` whenever a translation lands or the reader switches between a translation and the original.
    static func observeTranslations(_ refresh: @escaping @MainActor () -> Void) -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: .translationChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { refresh() }
        }
    }

    /// The row of a thread about its comment's translation, or nil for a comment in the reader's language.
    static func translationRow(for comment: TraktComment) -> TVRowItem? {
        let shown = TranslationCenter.shared.presentation(for: comment)
        guard let language = shown.sourceName else { return nil }
        switch shown.phase {
        case .offer:
            return TVRowItem(id: "thread.translation", title: TranslationCopy.translateFrom(language), symbol: "translate")
        case .translating:
            return TVRowItem(id: "thread.translation", title: TranslationCopy.translating, symbol: "translate", isEnabled: false)
        case .translated:
            return TVRowItem(id: "thread.translation", title: TranslationCopy.showOriginal, subtitle: TranslationCopy.translatedFrom(language), symbol: "text.bubble")
        case .original:
            return TVRowItem(id: "thread.translation", title: TranslationCopy.showTranslation, symbol: "translate")
        case .failed:
            return TVRowItem(id: "thread.translation", title: TranslationCopy.tryAgain, subtitle: TranslationCopy.failed, symbol: "translate")
        case .none:
            return nil
        }
    }

    /// What the thread's translation row does for the phase it showed.
    static func selectTranslation(of comment: TraktComment) {
        let center = TranslationCenter.shared
        switch center.presentation(for: comment).phase {
        case .offer, .failed: center.translate(comment)
        case .translated, .original: center.toggleOriginal(comment)
        case .translating, .none: break
        }
    }
}

/// Who wrote a comment and what it says, in the left column of a thread on Apple TV.
final class TVCommentColumn: TVReadOnlyPanel {
    private let avatar = TraktAvatarView(diameter: 96)
    private let name = UILabel()
    private let meta = UILabel()
    private let body = UILabel()
    private let gif = TraktGIFView(cornerRadius: Theme.Radius.m)
    private var spoken: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        name.font = Theme.Font.title3
        name.textColor = Theme.Color.label
        name.numberOfLines = 2
        meta.font = TVFont.cardSubtitle
        meta.textColor = Theme.Color.labelSecondary
        meta.numberOfLines = 2
        let names = UIStackView(arrangedSubviews: [name, meta])
        names.axis = .vertical
        names.spacing = 4
        let header = UIStackView(arrangedSubviews: [avatar, names])
        header.spacing = 24
        header.alignment = .center
        body.font = Theme.Font.callout
        body.textColor = Theme.Color.label
        body.numberOfLines = 16
        body.lineBreakMode = .byTruncatingTail
        gif.isHidden = true
        gif.heightAnchor.constraint(equalToConstant: 300).isActive = true
        let stack = UIStackView(arrangedSubviews: [header, body, gif])
        stack.axis = .vertical
        stack.spacing = 32
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        spokenLabel = { [weak self] in self?.spoken }
        accessibilityIdentifier = "trakt.thread.column"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ written: TraktComment, revealed: Bool, isMine: Bool) {
        let translation = TranslationCenter.shared.presentation(for: written)
        let comment = TranslationCenter.shared.displayed(written)
        avatar.configure(comment.user)
        name.text = isMine ? "\(comment.user.displayName) (\(TraktCommunityCopy.you))" : comment.user.displayName
        var facts = TVCommentCardView.tags(comment)
        if let rating = comment.authorRating { facts.append("★ \(rating)/10") }
        if comment.authorPlays > 1 { facts.append(TraktCommunityCopy.authorPlays(comment.authorPlays)) }
        facts.append(TraktCommunityCopy.age(comment.createdAt))
        if comment.wasEdited { facts.append(TraktCommunityCopy.edited) }
        if translation.showsTranslation, let language = translation.sourceName { facts.append(TranslationCopy.translatedFrom(language)) }
        meta.text = facts.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: "  ·  ")
        if comment.isSpoiler && !revealed {
            body.attributedText = NSAttributedString(string: TraktCommunityCopy.spoilerCover, attributes: [.font: Theme.Font.callout, .foregroundColor: Theme.Color.labelSecondary])
        } else {
            body.attributedText = TraktCommentTextFormatter.attributed(TraktCommentText(comment.text), font: Theme.Font.callout, color: Theme.Color.label, revealed: revealed, lineSpacing: 6)
        }
        let hasGIF = comment.gifURL != nil && !(comment.isSpoiler && !revealed)
        gif.isHidden = !hasGIF
        gif.show(hasGIF ? comment.gifURL : nil)
        body.numberOfLines = hasGIF ? 8 : 16
        spoken = TraktCommunityCopy.accessibilityLabel(comment, hidingSpoilers: !revealed)
    }
}

/// One comment with everything around it on Apple TV: the comment on the left; on the right, reveal, read in full, like,
/// react, reply, the author, and the replies, each opening as a thread of its own.
final class TVCommentThreadViewController: TVSettingsScaffold {
    /// Removed in deinit, which runs off the main actor; NotificationCenter takes removals from any thread.
    nonisolated(unsafe) private var translationObserver: (any NSObjectProtocol)?
    private var root: TraktComment
    private let subject: TraktCommunitySubject?
    private let titleName: String?
    private var replies: [TraktComment] = []
    private var page = 0
    private var hasMore = true
    private var revealed = false
    private var revealedReplies = Set<Int>()
    private var localChanges = 0
    private var focusAfterLoad: String?
    private let column = TVCommentColumn()
    nonisolated(unsafe) private var changeObserver: (any NSObjectProtocol)?
    private lazy var loadSlot = makeTaskSlot()

    init(comment: TraktComment, subject: TraktCommunitySubject?, titleName: String?) {
        root = comment
        self.subject = subject
        self.titleName = titleName
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        if let translationObserver { NotificationCenter.default.removeObserver(translationObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installContext(column)
        render()
        translationObserver = TVCommunityScreens.observeTranslations { [weak self] in self?.render() }
        changeObserver = NotificationCenter.default.addObserver(forName: .traktCommunityChanged, object: nil, queue: .main) { [weak self] note in
            guard let change = note.object as? TraktCommunity.Change else { return }
            MainActor.assumeIsolated { self?.handle(change) }
        }
        let id = root.id
        let changes = localChanges
        Task { [weak self] in
            async let fresh = try? TraktCommunity.shared.comment(id)
            async let reactions = try? TraktCommunity.shared.reactions(to: id)
            let loaded = await fresh
            _ = await reactions
            if TraktCommunity.shared.cachedSummary(id) == nil { _ = await TraktCommunity.shared.summary(for: id) }
            guard let self else { return }
            if let loaded, self.localChanges == changes { self.root = loaded }
            self.render()
        }
        loadReplies()
    }

    override var preferredFocusRowID: String? {
        if let focusAfterLoad { return focusAfterLoad }
        return root.isSpoiler && !revealed ? "thread.reveal" : "thread.like"
    }

    private func loadReplies() {
        guard hasMore, !root.isReply else {
            hasMore = false
            return
        }
        let next = page + 1
        let id = root.id
        loadSlot.run { [weak self] in
            do {
                let result = try await TraktCommunity.shared.replies(to: id, page: next)
                guard let self, !Task.isCancelled else { return }
                self.page = next
                self.hasMore = result.hasMore(limit: TraktCommunityRoute.pageLimit)
                let known = Set(self.replies.map(\.id))
                let fresh = result.items.filter { !known.contains($0.id) }
                if next > 1, let first = fresh.first { self.focusAfterLoad = "reply.\(first.id)" }
                self.replies += fresh
                self.render()
            } catch {
                guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                self.hasMore = false
                MidgarLog.notice("Trakt replies not loaded: \(error.localizedDescription)", category: .trakt)
                self.render()
            }
        }
    }

    private func render() {
        let community = TraktCommunity.shared
        let mine = community.isMine(root)
        column.show(root, revealed: revealed, isMine: mine)
        var rows: [TVRowItem] = []
        let text = TraktCommentText(TranslationCenter.shared.displayed(root).text)
        if !revealed, root.isSpoiler || text.hasInlineSpoilers {
            rows.append(TVRowItem(id: "thread.reveal", title: String(localized: "Reveal Spoilers", comment: "Row that shows a Trakt comment's hidden spoilers"), symbol: "eye"))
        }
        if text.plainText.count > 520 {
            rows.append(TVRowItem(id: "thread.read", title: String(localized: "Read in Full", comment: "Row that opens a long Trakt comment in a reader"), symbol: "text.alignleft", accessory: .chevron))
        }
        if let translation = TVCommunityScreens.translationRow(for: root) { rows.append(translation) }
        let liked = community.isLiked(root.id)
        rows.append(TVRowItem(id: "thread.like", title: liked ? TraktCommunityCopy.unlike : TraktCommunityCopy.like, value: "♥ \(Formatters.compactCount(root.likeCount))", symbol: liked ? "heart.fill" : "heart"))
        let summary = community.cachedSummary(root.id)
        let reactions = (summary?.ranked ?? []).prefix(4).map { "\($0.reaction.emoji) \($0.count)" }.joined(separator: "  ")
        rows.append(TVRowItem(id: "thread.react", title: TraktCommunityCopy.react, value: reactions.isEmpty ? nil : reactions, symbol: "face.smiling", accessory: .chevron))
        if !root.isReply {
            rows.append(TVRowItem(id: "thread.reply", title: TraktCommunityCopy.reply, symbol: "arrowshape.turn.up.left", accessory: .chevron))
        }
        rows.append(TVRowItem(id: "thread.author", title: root.user.displayName, subtitle: "@\(root.user.username)", symbol: "person.crop.circle", accessory: .chevron))
        for reply in replies {
            rows.append(TVRowItem(
                id: "reply.\(reply.id)",
                title: [reply.user.displayName, reply.authorRating.map { "★ \($0)" }].compactMap { $0 }.joined(separator: "  ·  "),
                subtitle: TVCommunityScreens.text(reply, revealed: revealedReplies.contains(reply.id)),
                value: TVCommunityScreens.countsValue(reply, summary: community.cachedSummary(reply.id)),
                symbol: "arrowshape.turn.up.left",
                accessory: .chevron
            ))
        }
        if hasMore, !root.isReply {
            rows.append(TVRowItem(id: "thread.more", title: String(localized: "More Replies", comment: "Row that loads more replies to a Trakt comment"), symbol: "ellipsis.circle"))
        }
        if mine {
            rows.append(TVRowItem(id: "thread.edit", title: TraktCommunityCopy.edit, symbol: "pencil", accessory: .chevron))
            rows.append(TVRowItem(id: "thread.delete", title: TraktCommunityCopy.delete, symbol: "trash", isDestructive: true))
        } else {
            rows.append(TVRowItem(id: "thread.report", title: TraktCommunityCopy.report, symbol: "flag", accessory: .chevron))
        }
        setRows(rows)
    }

    override func rowDidSelect(_ id: String) {
        switch id {
        case "thread.reveal":
            revealed = true
            render()
        case "thread.read":
            present(TVSynopsisViewController(title: root.user.displayName, text: TraktCommentText(TranslationCenter.shared.displayed(root).text).plainText), animated: TVMotion.animationsEnabled)
        case "thread.translation":
            TVCommunityScreens.selectTranslation(of: root)
        case "thread.like":
            TVCommunityScreens.toggleLike(root, from: self)
        case "thread.react":
            TVCommunityScreens.pickReaction(for: root.id, from: self)
        case "thread.reply":
            TVCommunityScreens.compose(.reply(root), from: self)
        case "thread.author":
            TVCommunityScreens.openMember(root.user, from: self)
        case "thread.more":
            loadReplies()
        case "thread.edit":
            TVCommunityScreens.compose(.edit(root), from: self)
        case "thread.delete":
            TVCommunityScreens.confirmDelete(root, from: self) { [weak self] in
                guard let self else { return }
                TVNavigation.pop(from: self)
            }
        case "thread.report":
            TVCommunityScreens.report(root, from: self)
        default:
            guard id.hasPrefix("reply."), let replyID = Int(id.dropFirst(6)), let reply = replies.first(where: { $0.id == replyID }) else { return }
            if reply.isSpoiler, !revealedReplies.contains(replyID) {
                revealedReplies.insert(replyID)
                return render()
            }
            TVNavigation.push(TVCommentThreadViewController(comment: reply, subject: subject, titleName: titleName), from: self)
        }
    }

    override func rowDidFocus(_ id: String?) {
        guard let id, id.hasPrefix("reply."), let replyID = Int(id.dropFirst(6)), TraktCommunity.shared.cachedSummary(replyID) == nil else { return }
        Task { [weak self] in
            guard await TraktCommunity.shared.summary(for: replyID) != nil else { return }
            self?.render()
        }
    }

    private func handle(_ change: TraktCommunity.Change) {
        switch change {
        case .updated(let comment):
            if comment.id == root.id {
                localChanges += 1
                root = comment
            } else if let index = replies.firstIndex(where: { $0.id == comment.id }) {
                replies[index] = comment
            }
        case .removed(let id):
            if id == root.id { return }
            replies.removeAll { $0.id == id }
        case .posted(let reply, _):
            guard reply.parentID == root.id, !replies.contains(where: { $0.id == reply.id }) else { return }
            replies.append(reply)
        case .relationship:
            replies.removeAll { TraktCommunity.shared.isBlocked($0.user.handle) }
        case .reactions, .viewerState:
            break
        }
        render()
    }
}

/// Every comment on a title on Apple TV, a page at a time, in the order the viewer picks. The focused comment reads in full
/// in the left column; Select opens its thread. Opened from a sentiment, it lists the comments Trakt drew it from.
final class TVCommentsViewController: TVSettingsScaffold {
    /// Removed in deinit, which runs off the main actor; NotificationCenter takes removals from any thread.
    nonisolated(unsafe) private var translationObserver: (any NSObjectProtocol)?
    enum Source {
        case subject(TraktCommunitySubject)
        case aspect(TraktSentiments.Aspect, TraktCommunitySubject)

        var subject: TraktCommunitySubject {
            switch self {
            case .subject(let subject), .aspect(_, let subject): return subject
            }
        }
    }

    private let source: Source
    private let titleName: String
    private var sort = TraktCommentSort.likes
    private var comments: [TraktComment] = []
    private var page = 0
    private var hasMore = true
    private var revealed = Set<Int>()
    private var focusAfterLoad: String?
    private let heading: TVSettingsHeading
    nonisolated(unsafe) private var changeObserver: (any NSObjectProtocol)?
    private lazy var loadSlot = makeTaskSlot()

    init(source: Source, titleName: String) {
        self.source = source
        self.titleName = titleName
        let title: String
        if case .aspect(let aspect, _) = source { title = TraktSentimentsTranslation.text(aspect) } else { title = TraktCommunityCopy.comments }
        heading = TVSettingsHeading(title: title, body: titleName)
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        if let translationObserver { NotificationCenter.default.removeObserver(translationObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installHeading(heading)
        presentState(.loading(title: TraktCommunityCopy.comments))
        translationObserver = TVCommunityScreens.observeTranslations { [weak self] in
            guard let self, self.page > 0 else { return }
            self.render()
        }
        changeObserver = NotificationCenter.default.addObserver(forName: .traktCommunityChanged, object: nil, queue: .main) { [weak self] note in
            guard let change = note.object as? TraktCommunity.Change else { return }
            MainActor.assumeIsolated { self?.handle(change) }
        }
        reload()
    }

    override var preferredFocusRowID: String? { focusAfterLoad ?? comments.first.map { "comment.\($0.id)" } ?? "comments.write" }

    private func reload() {
        page = 0
        hasMore = true
        comments = []
        focusAfterLoad = nil
        loadNextPage()
    }

    private func loadNextPage() {
        guard hasMore else { return }
        let next = page + 1
        let source = source
        let sort = sort
        loadSlot.run { [weak self] in
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
                let known = Set(self.comments.map(\.id))
                let fresh = found.filter { !known.contains($0.id) }
                if next > 1, let first = fresh.first { self.focusAfterLoad = "comment.\(first.id)" }
                self.comments += fresh
                self.presentState(nil)
                self.render()
            } catch {
                guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                if self.comments.isEmpty {
                    self.presentState(.error(title: TraktCommunityCopy.loadFailed, message: error.localizedDescription, retryTitle: String(localized: "Retry")) { [weak self] in
                        self?.presentState(.loading(title: TraktCommunityCopy.comments))
                        self?.reload()
                    })
                }
            }
        }
    }

    private func render() {
        var rows: [TVRowItem] = []
        if case .subject = source {
            rows.append(TVRowItem(id: "comments.sort", title: TraktCommunityCopy.sort, value: sort.title, symbol: "arrow.up.arrow.down", accessory: .chevron))
        }
        rows.append(TVRowItem(id: "comments.write", title: TraktCommunityCopy.writeReview, symbol: "square.and.pencil", accessory: .chevron))
        if comments.isEmpty {
            rows.append(TVRowItem(id: "comments.empty", title: TraktCommunityCopy.emptyTitle, subtitle: TraktCommunityCopy.emptyMessage, symbol: "bubble.left", isStatic: true))
        }
        let community = TraktCommunity.shared
        for comment in comments {
            var title = comment.user.displayName
            if comment.isReview { title += "  ·  " + TraktCommunityCopy.review }
            if let rating = comment.authorRating { title += "  ·  ★ \(rating)" }
            rows.append(TVRowItem(
                id: "comment.\(comment.id)",
                title: title,
                subtitle: TVCommunityScreens.text(comment, revealed: revealed.contains(comment.id)),
                value: TVCommunityScreens.countsValue(comment, summary: community.cachedSummary(comment.id)),
                symbol: comment.isSpoiler ? "eye.slash" : "text.bubble",
                accessory: .chevron
            ))
        }
        if hasMore, !comments.isEmpty {
            rows.append(TVRowItem(id: "comments.more", title: String(localized: "More Comments", comment: "Row that loads more Trakt comments"), symbol: "ellipsis.circle"))
        }
        setRows(rows)
    }

    override func rowDidFocus(_ id: String?) {
        guard let id, id.hasPrefix("comment."), let commentID = Int(id.dropFirst(8)), let comment = comments.first(where: { $0.id == commentID }) else {
            heading.setBody(titleName)
            return
        }
        heading.setBody(TVCommunityScreens.text(comment, revealed: revealed.contains(commentID)))
        if TraktCommunity.shared.cachedSummary(commentID) == nil {
            Task { [weak self] in
                guard await TraktCommunity.shared.summary(for: commentID) != nil else { return }
                self?.render()
            }
        }
        if comments.last?.id == commentID { loadNextPage() }
    }

    override func rowDidSelect(_ id: String) {
        switch id {
        case "comments.sort":
            chooseSort()
        case "comments.write":
            TVCommunityScreens.compose(.new(source.subject, titleName: titleName), from: self)
        case "comments.more":
            loadNextPage()
        default:
            guard id.hasPrefix("comment."), let commentID = Int(id.dropFirst(8)), let comment = comments.first(where: { $0.id == commentID }) else { return }
            if comment.isSpoiler, !revealed.contains(commentID) {
                revealed.insert(commentID)
                heading.setBody(TVCommunityScreens.text(comment, revealed: true))
                return render()
            }
            TVNavigation.push(TVCommentThreadViewController(comment: comment, subject: source.subject, titleName: titleName), from: self)
        }
    }

    private func chooseSort() {
        guard presentedViewController == nil else { return }
        let sheet = UIAlertController(title: TraktCommunityCopy.sort, message: nil, preferredStyle: .actionSheet)
        for option in TraktCommentSort.allCases {
            sheet.addAction(UIAlertAction(title: option.title + (option == sort ? "  ✓" : ""), style: .default) { [weak self] _ in
                guard let self, self.sort != option else { return }
                self.sort = option
                self.reload()
            })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(sheet, animated: TVMotion.animationsEnabled)
    }

    private func handle(_ change: TraktCommunity.Change) {
        switch change {
        case .updated(let comment):
            guard let index = comments.firstIndex(where: { $0.id == comment.id }) else { return }
            comments[index] = comment
        case .removed(let id):
            comments.removeAll { $0.id == id }
        case .posted(let comment, let subjectKey):
            guard subjectKey == source.subject.key, case .subject = source else { return }
            comments.insert(comment, at: 0)
        case .relationship:
            comments.removeAll { TraktCommunity.shared.isBlocked($0.user.handle) }
        case .reactions, .viewerState:
            break
        }
        render()
    }
}

/// A Trakt member on Apple TV: who they are on the left; Follow, what they are watching, what they wrote lately, Block and
/// Report on the right.
final class TVTraktMemberViewController: TVSettingsScaffold {
    private var user: TraktUser
    private var watching: TraktWatchingNow?
    private var following: TraktCommunity.Following?
    private var comments: [TraktUserComment] = []
    private let column = TVMemberColumn()
    /// Removed in deinit, which runs off the main actor; NotificationCenter takes removals from any thread.
    nonisolated(unsafe) private var translationObserver: (any NSObjectProtocol)?

    init(user: TraktUser) {
        self.user = user
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let translationObserver { NotificationCenter.default.removeObserver(translationObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installContext(column)
        translationObserver = TVCommunityScreens.observeTranslations { [weak self] in
            guard let self, !self.comments.isEmpty else { return }
            self.render()
        }
        column.show(user)
        presentState(.loading(title: user.displayName))
        let handle = user.handle
        Task { [weak self] in
            async let profile = try? TraktCommunity.shared.profile(handle)
            async let watching = TraktCommunity.shared.watchingNow(handle)
            async let following = TraktCommunity.shared.following(handle)
            async let comments = try? TraktCommunity.shared.comments(by: handle, page: 1, limit: 10)
            let (loadedProfile, loadedWatching, loadedFollowing, loadedComments) = await (profile, watching, following, comments)
            guard let self else { return }
            if let loadedProfile { self.user = loadedProfile.keepingAvatar(of: self.user) }
            self.watching = loadedWatching
            self.following = loadedFollowing
            self.comments = loadedComments?.items ?? []
            self.presentState(nil)
            self.render()
        }
    }

    override var preferredFocusRowID: String? { isMe ? nil : "member.follow" }

    private var isMe: Bool { TraktAccount.shared.profile?.username == user.username }

    private func render() {
        column.show(user)
        var rows: [TVRowItem] = []
        if !isMe, let following {
            let title: String
            let symbol: String
            switch following {
            case .notFollowing: (title, symbol) = (TraktCommunityCopy.follow, "person.badge.plus")
            case .following: (title, symbol) = (TraktCommunityCopy.following, "checkmark.circle.fill")
            case .requested: (title, symbol) = (TraktCommunityCopy.requested, "clock")
            }
            rows.append(TVRowItem(id: "member.follow", title: title, symbol: symbol))
        }
        if let watching {
            rows.append(TVRowItem(id: "member.watching", title: watching.title, subtitle: watching.subtitle, value: TraktCommunityCopy.watchingNowLabel, symbol: "play.tv.fill", isStatic: true))
        }
        for entry in comments {
            rows.append(TVRowItem(
                id: "member.comment.\(entry.comment.id)",
                title: entry.itemTitle ?? TraktCommunityCopy.comments,
                subtitle: TVCommunityScreens.text(entry.comment, revealed: false),
                value: TraktCommunityCopy.age(entry.comment.createdAt),
                symbol: entry.comment.isReview ? "text.quote" : "text.bubble",
                accessory: .chevron
            ))
        }
        if !isMe {
            if TraktCommunity.shared.isBlocked(user.handle) {
                rows.append(TVRowItem(id: "member.block", title: TraktCommunityCopy.unblock, symbol: "person.crop.circle.badge.checkmark"))
            } else {
                rows.append(TVRowItem(id: "member.block", title: TraktCommunityCopy.block, symbol: "hand.raised", isDestructive: true))
            }
            rows.append(TVRowItem(id: "member.report", title: TraktCommunityCopy.report, symbol: "flag", accessory: .chevron))
        }
        setRows(rows)
    }

    override func rowDidSelect(_ id: String) {
        let handle = user.handle
        switch id {
        case "member.follow":
            let follow = (following ?? .notFollowing) == .notFollowing
            Task { [weak self] in
                do {
                    self?.following = try await TraktCommunity.shared.setFollowing(follow, handle: handle)
                } catch {
                    self?.presentAlert(title: TraktCopy.name, message: error.localizedDescription)
                }
                self?.render()
            }
        case "member.block" where TraktCommunity.shared.isBlocked(handle):
            Task { [weak self] in
                do { try await TraktCommunity.shared.unblock(handle) } catch { self?.presentAlert(title: TraktCopy.name, message: error.localizedDescription) }
                self?.render()
            }
        case "member.block":
            presentConfirmation(title: TraktCommunityCopy.blockTitle, message: TraktCommunityCopy.blockMessage, confirmTitle: TraktCommunityCopy.block) { [weak self] in
                Task { [weak self] in
                    do {
                        try await TraktCommunity.shared.block(handle)
                        self?.following = .notFollowing
                    } catch {
                        self?.presentAlert(title: TraktCopy.name, message: error.localizedDescription)
                    }
                    self?.render()
                }
            }
        case "member.report":
            guard presentedViewController == nil else { return }
            let sheet = UIAlertController(title: TraktCommunityCopy.reportTitle, message: nil, preferredStyle: .actionSheet)
            for reason in TraktUserReportReason.allCases {
                sheet.addAction(UIAlertAction(title: reason.title, style: .default) { [weak self] _ in
                    Task { [weak self] in
                        do {
                            try await TraktCommunity.shared.report(user: handle, reason: reason)
                            self?.presentAlert(title: TraktCommunityCopy.reported)
                        } catch {
                            self?.presentAlert(title: TraktCopy.name, message: error.localizedDescription)
                        }
                    }
                })
            }
            sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
            present(sheet, animated: TVMotion.animationsEnabled)
        default:
            guard id.hasPrefix("member.comment."), let commentID = Int(id.dropFirst(15)), let entry = comments.first(where: { $0.comment.id == commentID }) else { return }
            TVNavigation.push(TVCommentThreadViewController(comment: entry.comment, subject: nil, titleName: entry.itemTitle), from: self)
        }
    }
}

/// A member's face, name, badges, where they are, since when and what they say about themselves.
final class TVMemberColumn: TVReadOnlyPanel {
    private let avatar = TraktAvatarView(diameter: 200)
    private let name = UILabel()
    private let details = UILabel()
    private let about = UILabel()
    private var spoken: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        name.font = Theme.Font.title2
        name.textColor = Theme.Color.label
        name.numberOfLines = 2
        details.font = TVFont.cardSubtitle
        details.textColor = Theme.Color.labelSecondary
        details.numberOfLines = 0
        about.font = Theme.Font.callout
        about.textColor = Theme.Color.label
        about.numberOfLines = 8
        let stack = UIStackView(arrangedSubviews: [avatar, name, details, about])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.setCustomSpacing(32, after: avatar)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        spokenLabel = { [weak self] in self?.spoken }
        accessibilityIdentifier = "trakt.member.column"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ user: TraktUser) {
        avatar.configure(user)
        name.text = user.displayName
        var facts = ["@\(user.username)"]
        if user.isVIP { facts.append(user.vipYears.map(TraktCommunityCopy.vipYears) ?? TraktCommunityCopy.vip) }
        if user.isDirector { facts.append(TraktCommunityCopy.director) }
        if let location = user.location { facts.append(location) }
        if let joined = user.joinedAt { facts.append(TraktCommunityCopy.joined(joined)) }
        details.text = facts.joined(separator: "  ·  ")
        about.text = user.isPrivate ? TraktCommunityCopy.privateProfile : user.about
        about.isHidden = about.text == nil
        spoken = [user.displayName, details.text, about.text].compactMap { $0 }.joined(separator: ", ")
    }
}

/// A list of members on Apple TV, such as who is watching a title right now, each opening their page.
final class TVTraktMembersViewController: TVSettingsScaffold {
    private let users: [TraktUser]
    private let heading: TVSettingsHeading

    init(title: String, detail: String?, users: [TraktUser]) {
        self.users = users
        heading = TVSettingsHeading(title: title, body: detail)
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        installHeading(heading)
        setRows(users.map { user in
            TVRowItem(id: "member.\(user.username)", title: user.displayName, subtitle: "@\(user.username)", value: user.isVIP ? TraktCommunityCopy.vip : nil, symbol: "person.crop.circle", accessory: .chevron)
        })
    }

    override func rowDidSelect(_ id: String) {
        guard let user = users.first(where: { "member.\($0.username)" == id }) else { return }
        TVNavigation.push(TVTraktMemberViewController(user: user), from: self)
    }
}

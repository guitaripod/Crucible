import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// Every comment on a title (`TVCommentsViewController`), a page at a time in the order the viewer picks; the focused one
/// reads in full on the left, and Return opens its thread. Opened from a sentiment, it lists the comments Trakt drew it from.
@MainActor
final class CommentsScreen: SettingsScaffold {
    enum Source {
        case subject(TraktCommunitySubject)
        case aspect(TraktSentiments.Aspect, TraktCommunitySubject)

        var subject: TraktCommunitySubject {
            switch self {
            case .subject(let subject), .aspect(_, let subject): return subject
            }
        }
    }

    private enum RowID {
        static let sort = "comments.sort"
        static let write = "comments.write"
        static let more = "comments.more"
        static let prefix = "comment."
    }

    private let source: Source
    private let titleName: String
    private var sort = TraktCommentSort.likes
    private var comments: [TraktComment] = []
    private var page = 0
    private var hasMore = true
    private var revealed = Set<Int>()
    private var focusAfterLoad: String?
    private var loadTask: Task<Void, Never>?
    private var observer: (any NSObjectProtocol)?
    private let panel: ContextPanel

    init(source: Source, titleName: String) {
        self.source = source
        self.titleName = titleName
        let title: String
        if case .aspect(let aspect, _) = source { title = aspect.text } else { title = TraktCommunityCopy.comments }
        panel = ContextPanel(content: .init(symbol: "bubble.left.and.bubble.right.fill", title: title, subtitle: titleName))
        super.init(title: title, detail: titleName)
        panel.wellView = BrandMarkView("trakt")
        installContext(panel)
        presentLoadingRows()
        reload()
    }

    override func screenDidAppear() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .traktCommunityChanged, object: nil, queue: .main) { [weak self] note in
            guard let change = note.object as? TraktCommunity.Change else { return }
            MainActor.assumeIsolated { self?.handle(change) }
        }
    }

    override func screenWillDisappear() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

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
        loadTask?.cancel()
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
                let known = Set(self.comments.map(\.id))
                let fresh = found.filter { !known.contains($0.id) }
                if next > 1, let first = fresh.first { self.focusAfterLoad = RowID.prefix + String(first.id) }
                self.comments += fresh
                self.render()
                self.presentState(nil)
                self.applyFocusAfterLoad()
            } catch {
                guard let self, !Task.isCancelled, !(error is CancellationError), self.comments.isEmpty else { return }
                self.presentState(.error(title: TraktCommunityCopy.loadFailed, message: error.localizedDescription, retryTitle: String(localized: "Retry"),
                                         retry: { [weak self] in
                                             self?.presentLoadingRows()
                                             self?.reload()
                                         }))
            }
        }
    }

    private func applyFocusAfterLoad() {
        guard let id = focusAfterLoad, containsFocus, let row = rows.row(id: id) else { return }
        focusAfterLoad = nil
        window?.focus.focus(row, animated: false)
    }

    private func render() {
        var items: [RowItem] = []
        if case .subject = source {
            items.append(RowItem(id: RowID.sort, title: TraktCommunityCopy.sort, value: sort.title, symbol: "arrow.up.arrow.down", accessory: .chevron))
        }
        items.append(RowItem(id: RowID.write, title: TraktCommunityCopy.writeReview, symbol: "square.and.pencil", accessory: .chevron))
        if comments.isEmpty {
            items.append(RowItem(id: "comments.empty", title: TraktCommunityCopy.emptyTitle, subtitle: TraktCommunityCopy.emptyMessage, symbol: "bubble.left",
                                 isStatic: true))
        }
        let community = TraktCommunity.shared
        for comment in comments {
            var title = comment.user.displayName
            if comment.isReview { title += "  ·  " + TraktCommunityCopy.review }
            if let rating = comment.authorRating { title += "  ·  ★ \(rating)" }
            items.append(RowItem(id: RowID.prefix + String(comment.id), title: title,
                                 subtitle: CommunityActions.text(comment, revealed: revealed.contains(comment.id)),
                                 value: CommunityActions.countsValue(comment, summary: community.cachedSummary(comment.id)),
                                 symbol: comment.isSpoiler ? "eye.slash" : "text.bubble", accessory: .chevron))
        }
        if hasMore, !comments.isEmpty {
            items.append(RowItem(id: RowID.more, title: String(localized: "More Comments", comment: "Row that loads more Trakt comments"), symbol: "ellipsis.circle"))
        }
        setRows(items)
    }

    private func comment(_ id: String) -> TraktComment? {
        guard id.hasPrefix(RowID.prefix), let commentID = Int(id.dropFirst(RowID.prefix.count)) else { return nil }
        return comments.first { $0.id == commentID }
    }

    /// The focused comment reads in full on the left; its reactions load, and reaching the last one loads the next page.
    override func rowFocused(_ id: String) {
        guard let comment = comment(id) else {
            panel.content.body = nil
            return
        }
        panel.content.body = CommunityActions.text(comment, revealed: revealed.contains(comment.id))
        if TraktCommunity.shared.cachedSummary(comment.id) == nil {
            Task { [weak self] in
                guard await TraktCommunity.shared.summary(for: comment.id) != nil else { return }
                self?.render()
            }
        }
        if comments.last?.id == comment.id { loadNextPage() }
    }

    override func rowSelected(_ id: String) {
        switch id {
        case RowID.sort: chooseSort()
        case RowID.write: navigation?.push(CommentComposerScreen(mode: .new(source.subject, titleName: titleName)))
        case RowID.more: loadNextPage()
        default:
            guard let comment = comment(id) else { return }
            if comment.isSpoiler, !revealed.contains(comment.id) {
                revealed.insert(comment.id)
                panel.content.body = CommunityActions.text(comment, revealed: true)
                return render()
            }
            navigation?.push(CommentThreadScreen(comment: comment, subject: source.subject, titleName: titleName))
        }
    }

    override func rowMenu(_ id: String, at anchor: Rect) -> Bool {
        guard let comment = comment(id) else { return false }
        CommunityActions.presentMenu(for: comment, at: Point(x: anchor.minX, y: anchor.maxY), from: self)
        return true
    }

    private func chooseSort() {
        guard let window, let anchor = rows.row(id: RowID.sort)?.frameInWindow else { return }
        let items = TraktCommentSort.allCases.map { MenuView.Item(id: $0.rawValue, title: $0.title, isChecked: $0 == sort) }
        let menu = MenuView(title: TraktCommunityCopy.sort, items: items, anchor: Rect(x: anchor.maxX - metricsMenuWidth, y: anchor.maxY, width: 1, height: 1))
        menu.onSelect = { [weak self] chosen in
            guard let self, let option = TraktCommentSort(rawValue: chosen.id), option != self.sort else { return }
            self.sort = option
            self.render()
            self.reload()
        }
        menu.present(in: window)
    }

    private var metricsMenuWidth: Float { Theme.current.metrics.tv(500) }

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

/// Who wrote a comment and what it says (`TVCommentColumn`), the left column of a thread: the face, the name with the
/// viewer's own marked, the facts (badges, rating, plays, age, edited), and the text with its formatting.
@MainActor
final class CommentColumnView: View {
    private let avatar = TraktAvatarView()
    private let gif = GIFView()
    private var comment: TraktComment?
    private var revealed = false
    private var isMine = false

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        addSubview(avatar)
        addSubview(gif)
        gif.isHidden = true
    }

    func show(_ comment: TraktComment, revealed: Bool, isMine: Bool) {
        self.comment = comment
        self.revealed = revealed
        self.isMine = isMine
        avatar.configure(comment.user)
        let shownGIF = comment.isSpoiler && !revealed ? nil : comment.gifURL
        gif.isHidden = shownGIF == nil
        gif.url = shownGIF
        superview?.setNeedsLayout()
        setNeedsDisplay()
    }

    private var metrics: Metrics { Theme.current.metrics }
    private var avatarSide: Float { metrics.tv(96) }
    private var gap: Float { metrics.tv(32) }

    private func layouts(width: Float) -> (name: TextLayout, meta: TextLayout, body: TextLayout)? {
        guard let comment else { return nil }
        let scale = window?.scale ?? 1
        let type = Theme.current.type
        let textWidth = width - avatarSide - metrics.tv(24)
        let nameText = isMine ? "\(comment.user.displayName) (\(TraktCommunityCopy.you))" : comment.user.displayName
        var facts = CommentCardContent.tags(comment).map(\.text)
        if let rating = comment.authorRating { facts.append("★ \(rating)/10") }
        if comment.authorPlays > 1 { facts.append(TraktCommunityCopy.authorPlays(comment.authorPlays)) }
        facts.append(TraktCommunityCopy.age(comment.createdAt))
        if comment.wasEdited { facts.append(TraktCommunityCopy.edited) }
        let name = TextLayout(nameText, font: type.title3, maxWidth: textWidth, maxLines: 2, scale: scale)
        let meta = TextLayout(facts.joined(separator: "  ·  "), font: type.cardSubtitle, maxWidth: textWidth, maxLines: 2, scale: scale)
        let markup = comment.isSpoiler && !revealed ? TextLayout.escapingMarkup(TraktCommunityCopy.spoilerCover)
            : CommentMarkup.markup(TraktCommentText(comment.text), revealed: revealed)
        let body = TextLayout(markup, font: type.callout, maxWidth: width, maxLines: gif.isHidden ? 18 : 10, scale: scale, markup: true, inColor: true)
        return (name, meta, body)
    }

    private var gifHeight: Float { gif.isHidden ? 0 : metrics.tv(300) }

    override func sizeThatFits(_ size: Size) -> Size {
        guard let laidOut = layouts(width: size.width) else { return Size(width: size.width, height: 0) }
        let header = max(avatarSide, laidOut.name.size.height + metrics.tv(4) + laidOut.meta.size.height)
        let gifRoom = gif.isHidden ? 0 : gap + gifHeight
        return Size(width: size.width, height: header + gap + laidOut.body.size.height + gifRoom)
    }

    override func layoutSubviews() {
        avatar.frame = Rect(x: 0, y: 0, width: avatarSide, height: avatarSide)
        guard let laidOut = layouts(width: frame.width) else { return }
        let header = max(avatarSide, laidOut.name.size.height + metrics.tv(4) + laidOut.meta.size.height)
        gif.cornerRadius = metrics.radiusM
        gif.frame = Rect(x: 0, y: header + gap + laidOut.body.size.height + gap, width: frame.width, height: gifHeight)
    }

    override func draw(_ context: inout DrawContext) {
        guard let laidOut = layouts(width: frame.width), let comment else { return }
        let palette = Theme.current.palette
        let headerText = laidOut.name.size.height + metrics.tv(4) + laidOut.meta.size.height
        let header = max(avatarSide, headerText)
        let x = avatarSide + metrics.tv(24)
        let y = ((header - headerText) / 2).rounded()
        context.text(laidOut.name, at: Point(x: x, y: y), color: palette.label)
        context.text(laidOut.meta, at: Point(x: x, y: y + laidOut.name.size.height + metrics.tv(4)), color: palette.labelSecondary)
        let covered = comment.isSpoiler && !revealed
        context.text(laidOut.body, at: Point(x: 0, y: header + gap), color: covered ? palette.labelSecondary : palette.label)
    }
}

/// One comment with everything around it (`TVCommentThreadViewController`): the comment on the left; on the right, reveal,
/// like, react, reply, the author, and the replies, each opening as a thread of its own, then edit and delete for the
/// viewer's own or report.
@MainActor
final class CommentThreadScreen: SettingsScaffold {
    private var root: TraktComment
    private let subject: TraktCommunitySubject?
    private let titleName: String?
    private var replies: [TraktComment] = []
    private var page = 0
    private var hasMore = true
    private var revealed = false
    private var revealedReplies = Set<Int>()
    private var localChanges = 0
    private var loadTask: Task<Void, Never>?
    private var observer: (any NSObjectProtocol)?
    private let column = CommentColumnView()

    init(comment: TraktComment, subject: TraktCommunitySubject?, titleName: String?) {
        root = comment
        self.subject = subject
        self.titleName = titleName
        super.init(title: comment.isReply ? TraktCommunityCopy.reply : TraktCommunityCopy.comments, detail: titleName)
        installContext(column)
        render()
        let id = comment.id
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

    override var preferredFocusView: View? {
        rows.row(id: root.isSpoiler && !revealed ? "thread.reveal" : "thread.like") ?? super.preferredFocusView
    }

    override func screenDidAppear() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .traktCommunityChanged, object: nil, queue: .main) { [weak self] note in
            guard let change = note.object as? TraktCommunity.Change else { return }
            MainActor.assumeIsolated { self?.handle(change) }
        }
    }

    override func screenWillDisappear() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func loadReplies() {
        guard hasMore, !root.isReply else {
            hasMore = false
            return
        }
        let next = page + 1
        let id = root.id
        loadTask = Task { [weak self] in
            do {
                let result = try await TraktCommunity.shared.replies(to: id, page: next)
                guard let self, !Task.isCancelled else { return }
                self.page = next
                self.hasMore = result.hasMore(limit: TraktCommunityRoute.pageLimit)
                let known = Set(self.replies.map(\.id))
                let fresh = result.items.filter { !known.contains($0.id) }
                self.replies += fresh
                self.render()
                if next > 1, let first = fresh.first, self.containsFocus, let row = self.rows.row(id: "reply.\(first.id)") {
                    self.window?.focus.focus(row, animated: false)
                }
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
        var items: [RowItem] = []
        let text = TraktCommentText(root.text)
        if !revealed, root.isSpoiler || text.hasInlineSpoilers {
            items.append(RowItem(id: "thread.reveal", title: String(localized: "Reveal Spoilers", comment: "Row that shows a Trakt comment's hidden spoilers"),
                                 symbol: "eye"))
        }
        if text.plainText.count > 520 {
            items.append(RowItem(id: "thread.read", title: String(localized: "Read in Full", comment: "Row that opens a long Trakt comment in a reader"),
                                 symbol: "text.alignleft", accessory: .chevron))
        }
        let liked = community.isLiked(root.id)
        items.append(RowItem(id: "thread.like", title: liked ? TraktCommunityCopy.unlike : TraktCommunityCopy.like,
                             value: "♥ \(Formatters.compactCount(root.likeCount))", symbol: liked ? "heart.fill" : "heart"))
        let summary = community.cachedSummary(root.id)
        let reactions = (summary?.ranked ?? []).prefix(4).map { "\($0.reaction.emoji) \($0.count)" }.joined(separator: "  ")
        items.append(RowItem(id: "thread.react", title: TraktCommunityCopy.react, value: reactions.isEmpty ? nil : reactions, symbol: "face.smiling",
                             accessory: .chevron))
        if !root.isReply {
            items.append(RowItem(id: "thread.reply", title: TraktCommunityCopy.reply, symbol: "arrowshape.turn.up.left", accessory: .chevron))
        }
        items.append(RowItem(id: "thread.author", title: root.user.displayName, subtitle: "@\(root.user.username)", symbol: "person.crop.circle",
                             accessory: .chevron))
        for reply in replies {
            items.append(RowItem(id: "reply.\(reply.id)",
                                 title: [reply.user.displayName, reply.authorRating.map { "★ \($0)" }].compactMap { $0 }.joined(separator: "  ·  "),
                                 subtitle: CommunityActions.text(reply, revealed: revealedReplies.contains(reply.id)),
                                 value: CommunityActions.countsValue(reply, summary: community.cachedSummary(reply.id)),
                                 symbol: "arrowshape.turn.up.left", accessory: .chevron))
        }
        if hasMore, !root.isReply {
            items.append(RowItem(id: "thread.more", title: String(localized: "More Replies", comment: "Row that loads more replies to a Trakt comment"),
                                 symbol: "ellipsis.circle"))
        }
        if mine {
            items.append(RowItem(id: "thread.edit", title: TraktCommunityCopy.edit, symbol: "pencil", accessory: .chevron))
            items.append(RowItem(id: "thread.delete", title: TraktCommunityCopy.delete, symbol: "trash", isDestructive: true))
        } else {
            items.append(RowItem(id: "thread.report", title: TraktCommunityCopy.report, symbol: "flag", accessory: .chevron))
        }
        setRows(items)
    }

    override func rowSelected(_ id: String) {
        switch id {
        case "thread.reveal":
            revealed = true
            render()
            if let like = rows.row(id: "thread.like") { window?.focus.focus(like, animated: false) }
        case "thread.read":
            navigation?.push(ReaderScreen(title: root.user.displayName,
                                          markup: CommentMarkup.markup(TraktCommentText(root.text), revealed: revealed || !root.isSpoiler)))
        case "thread.like":
            CommunityActions.toggleLike(root, from: self)
        case "thread.react":
            CommunityActions.pickReaction(for: root.id, from: self)
        case "thread.reply":
            navigation?.push(CommentComposerScreen(mode: .reply(root)))
        case "thread.author":
            navigation?.push(TraktMemberScreen(user: root.user))
        case "thread.more":
            loadReplies()
        case "thread.edit":
            navigation?.push(CommentComposerScreen(mode: .edit(root)))
        case "thread.delete":
            CommunityActions.confirmDelete(root, from: self) { [weak self] in _ = self?.navigation?.pop() }
        case "thread.report":
            CommunityActions.report(root, from: self)
        default:
            guard id.hasPrefix("reply."), let replyID = Int(id.dropFirst(6)), let reply = replies.first(where: { $0.id == replyID }) else { return }
            if reply.isSpoiler, !revealedReplies.contains(replyID) {
                revealedReplies.insert(replyID)
                return render()
            }
            navigation?.push(CommentThreadScreen(comment: reply, subject: subject, titleName: titleName))
        }
    }

    override func rowFocused(_ id: String) {
        guard id.hasPrefix("reply."), let replyID = Int(id.dropFirst(6)), TraktCommunity.shared.cachedSummary(replyID) == nil else { return }
        Task { [weak self] in
            guard await TraktCommunity.shared.summary(for: replyID) != nil else { return }
            self?.render()
        }
    }

    override func rowMenu(_ id: String, at anchor: Rect) -> Bool {
        guard id.hasPrefix("reply."), let replyID = Int(id.dropFirst(6)), let reply = replies.first(where: { $0.id == replyID }) else { return false }
        CommunityActions.presentMenu(for: reply, at: Point(x: anchor.minX, y: anchor.maxY), from: self)
        return true
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

/// A member's face, name, badges, where they are, since when and what they say about themselves (`TVMemberColumn`).
@MainActor
final class MemberColumnView: View {
    private let avatar = TraktAvatarView()
    private var user: TraktUser?

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        addSubview(avatar)
    }

    func show(_ user: TraktUser) {
        self.user = user
        avatar.configure(user)
        superview?.setNeedsLayout()
        setNeedsDisplay()
    }

    private var metrics: Metrics { Theme.current.metrics }
    private var avatarSide: Float { metrics.tv(200) }

    private func layouts(width: Float) -> [(TextLayout, Color)] {
        guard let user, let scale = window?.scale else { return [] }
        let type = Theme.current.type
        let palette = Theme.current.palette
        var facts = ["@\(user.username)"]
        if user.isVIP { facts.append(user.vipYears.map(TraktCommunityCopy.vipYears) ?? TraktCommunityCopy.vip) }
        if user.isDirector { facts.append(TraktCommunityCopy.director) }
        if let location = user.location { facts.append(location) }
        if let joined = user.joinedAt { facts.append(TraktCommunityCopy.joined(joined)) }
        var result = [
            (TextLayout(user.displayName, font: type.title2, maxWidth: width, maxLines: 2, scale: scale), palette.label),
            (TextLayout(facts.joined(separator: "  ·  "), font: type.cardSubtitle, maxWidth: width, maxLines: 4, scale: scale), palette.labelSecondary),
        ]
        if let about = user.isPrivate ? TraktCommunityCopy.privateProfile : user.about {
            result.append((TextLayout(about, font: type.callout, maxWidth: width, maxLines: 8, scale: scale), palette.label))
        }
        return result
    }

    override func sizeThatFits(_ size: Size) -> Size {
        let texts = layouts(width: size.width)
        let height = avatarSide + metrics.tv(32) + texts.map(\.0.size.height).reduce(0, +) + Float(max(texts.count - 1, 0)) * metrics.tv(16)
        return Size(width: size.width, height: height)
    }

    override func layoutSubviews() {
        avatar.frame = Rect(x: 0, y: 0, width: avatarSide, height: avatarSide)
    }

    override func draw(_ context: inout DrawContext) {
        var y = avatarSide + metrics.tv(32)
        for (layout, color) in layouts(width: frame.width) {
            context.text(layout, at: Point(x: 0, y: y), color: color)
            y += layout.size.height + metrics.tv(16)
        }
    }
}

/// A Trakt member (`TVTraktMemberViewController`): who they are on the left; Follow, what they are watching, what they
/// wrote lately, Block and Report on the right.
@MainActor
final class TraktMemberScreen: SettingsScaffold {
    private var user: TraktUser
    private var watching: TraktWatchingNow?
    private var following: TraktCommunity.Following?
    private var comments: [TraktUserComment] = []
    private let column = MemberColumnView()

    init(user: TraktUser) {
        self.user = user
        super.init(title: user.displayName)
        installContext(column)
        column.show(user)
        presentLoadingRows()
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
            self.render()
            self.presentState(nil)
        }
    }

    private var isMe: Bool { TraktAccount.shared.profile?.username == user.username }

    override var preferredFocusView: View? { rows.row(id: "member.follow") ?? super.preferredFocusView }

    private func render() {
        column.show(user)
        var items: [RowItem] = []
        if !isMe, let following {
            let title: String
            let symbol: Symbol
            switch following {
            case .notFollowing: (title, symbol) = (TraktCommunityCopy.follow, "person.badge.plus")
            case .following: (title, symbol) = (TraktCommunityCopy.following, "checkmark.circle.fill")
            case .requested: (title, symbol) = (TraktCommunityCopy.requested, "clock")
            }
            items.append(RowItem(id: "member.follow", title: title, symbol: symbol))
        }
        if let watching {
            items.append(RowItem(id: "member.watching", title: watching.title, subtitle: watching.subtitle, value: TraktCommunityCopy.watchingNowLabel,
                                 symbol: "play.tv.fill", isStatic: true))
        }
        for entry in comments {
            items.append(RowItem(id: "member.comment.\(entry.comment.id)", title: entry.itemTitle ?? TraktCommunityCopy.comments,
                                 subtitle: CommunityActions.text(entry.comment, revealed: false), value: TraktCommunityCopy.age(entry.comment.createdAt),
                                 symbol: entry.comment.isReview ? "text.quote" : "text.bubble", accessory: .chevron))
        }
        if !isMe {
            if TraktCommunity.shared.isBlocked(user.handle) {
                items.append(RowItem(id: "member.block", title: TraktCommunityCopy.unblock, symbol: "person.crop.circle.badge.checkmark"))
            } else {
                items.append(RowItem(id: "member.block", title: TraktCommunityCopy.block, symbol: "hand.raised", isDestructive: true))
            }
            items.append(RowItem(id: "member.report", title: TraktCommunityCopy.report, symbol: "flag", accessory: .chevron))
        }
        setRows(items)
    }

    override func rowSelected(_ id: String) {
        let handle = user.handle
        switch id {
        case "member.follow":
            let follow = (following ?? .notFollowing) == .notFollowing
            Task { [weak self] in
                do {
                    self?.following = try await TraktCommunity.shared.setFollowing(follow, handle: handle)
                } catch {
                    CommunityActions.alert(TraktCopy.name, message: error.localizedDescription, from: self)
                }
                self?.render()
            }
        case "member.block" where TraktCommunity.shared.isBlocked(handle):
            Task { [weak self] in
                do { try await TraktCommunity.shared.unblock(handle) } catch { CommunityActions.alert(TraktCopy.name, message: error.localizedDescription, from: self) }
                self?.render()
            }
        case "member.block":
            guard let window else { return }
            AlertView.confirm(title: TraktCommunityCopy.blockTitle, message: TraktCommunityCopy.blockMessage, confirm: TraktCommunityCopy.block, in: window) { [weak self] in
                Task { [weak self] in
                    do {
                        try await TraktCommunity.shared.block(handle)
                        self?.following = .notFollowing
                    } catch {
                        CommunityActions.alert(TraktCopy.name, message: error.localizedDescription, from: self)
                    }
                    self?.render()
                }
            }
        case "member.report":
            reportMember(handle)
        default:
            guard id.hasPrefix("member.comment."), let commentID = Int(id.dropFirst(15)), let entry = comments.first(where: { $0.comment.id == commentID }) else { return }
            navigation?.push(CommentThreadScreen(comment: entry.comment, subject: nil, titleName: entry.itemTitle))
        }
    }

    private func reportMember(_ handle: String) {
        guard let window, let anchor = rows.row(id: "member.report")?.frameInWindow else { return }
        let items = TraktUserReportReason.allCases.map { MenuView.Item(id: $0.rawValue, title: $0.title) }
        let menu = MenuView(title: TraktCommunityCopy.reportTitle, items: items, anchor: Rect(x: anchor.minX, y: anchor.maxY, width: 1, height: 1))
        menu.onSelect = { [weak self] chosen in
            guard let reason = TraktUserReportReason(rawValue: chosen.id) else { return }
            Task { [weak self] in
                do {
                    try await TraktCommunity.shared.report(user: handle, reason: reason)
                    CommunityActions.alert(TraktCommunityCopy.reported, message: nil, from: self)
                } catch {
                    CommunityActions.alert(TraktCopy.name, message: error.localizedDescription, from: self)
                }
            }
        }
        menu.present(in: window)
    }
}

/// A list of members (`TVTraktMembersViewController`), such as who is watching a title right now, each opening their page.
@MainActor
final class TraktMembersScreen: SettingsScaffold {
    private let users: [TraktUser]

    init(title: String, detail: String?, users: [TraktUser]) {
        self.users = users
        super.init(title: title, detail: detail)
        setRows(users.map { user in
            RowItem(id: "member.\(user.username)", title: user.displayName, subtitle: "@\(user.username)", value: user.isVIP ? TraktCommunityCopy.vip : nil,
                    symbol: "person.crop.circle", accessory: .chevron)
        })
    }

    override func rowSelected(_ id: String) {
        guard let user = users.first(where: { "member.\($0.username)" == id }) else { return }
        navigation?.push(TraktMemberScreen(user: user))
    }
}

import Foundation
import MidgarCore

extension Notification.Name {
    /// Posted on the main thread with a `TraktCommunity.Change` as the object whenever a comment, a reaction or a follow changed.
    package static let traktCommunityChanged = Notification.Name("crucible.traktCommunityChanged")
}

/// The Trakt community around a title, for every screen that shows it: how many watch and discuss it, how its voters spread,
/// what people praise and criticise, who is watching right now, and its comments with their replies, likes and reactions. It
/// also writes for the viewer: comments, replies, edits, likes, reactions, reports, follows and blocks. Everything it reads is
/// kept for a few minutes per title, and what the viewer changes shows at once, before Trakt answers, and goes back if Trakt
/// refuses it.
@MainActor
package final class TraktCommunity {
    package static let shared = TraktCommunity()

    /// What a title's page shows of its community.
    package struct Snapshot: Equatable, Sendable {
        package let subject: TraktCommunitySubject
        package var stats: TraktTitleStats?
        package var score: TraktScore?
        package var distribution: TraktRatingDistribution?
        package var sentiments: TraktSentiments?
        package var watching: [TraktUser]
        package var comments: [TraktComment]
        package var commentCount: Int

        package init(
            subject: TraktCommunitySubject,
            stats: TraktTitleStats? = nil,
            score: TraktScore? = nil,
            distribution: TraktRatingDistribution? = nil,
            sentiments: TraktSentiments? = nil,
            watching: [TraktUser] = [],
            comments: [TraktComment] = [],
            commentCount: Int = 0
        ) {
            self.subject = subject
            self.stats = stats
            self.score = score
            self.distribution = distribution
            self.sentiments = sentiments
            self.watching = watching
            self.comments = comments
            self.commentCount = commentCount
        }

        /// Whether there is anything to show: a page hides its community when Trakt knows nothing about the title.
        package var isEmpty: Bool {
            (stats?.isEmpty ?? true) && distribution == nil && (sentiments?.isEmpty ?? true) && watching.isEmpty && comments.isEmpty
        }
    }

    /// What changed, for the screens that show it.
    package enum Change: Equatable, Sendable {
        /// A comment's text, spoiler mark, likes or replies changed.
        case updated(TraktComment)
        case removed(Int)
        /// The viewer posted a comment on the subject with this key, or a reply.
        case posted(TraktComment, subjectKey: String?)
        case reactions(Int)
        /// Crucible learned which comments the viewer liked or reacted to.
        case viewerState
        /// The viewer followed, unfollowed, blocked or unblocked a member.
        case relationship(String)
    }

    /// Where the viewer stands with a member.
    package enum Following: Equatable, Sendable {
        case notFollowing
        case requested
        case following
    }

    static let snapshotLifetime: TimeInterval = 10 * 60
    static let summaryLifetime: TimeInterval = 10 * 60
    static let viewerStateLifetime: TimeInterval = 30 * 60

    /// How many comments a page asks for along with the rest of the community.
    package static let previewCount = 10
    /// How many comments the most a sentiment opens reads, one request each.
    static let aspectCommentLimit = 12

    private let client: TraktClient
    private let account: TraktAccount
    private let resolver: TraktResolver
    private let defaults: UserDefaults
    private var subjects: [String: TraktCommunitySubject] = [:]
    private var snapshots: [String: (snapshot: Snapshot, at: Date)] = [:]
    private var snapshotTasks: [String: Task<Snapshot?, Never>] = [:]
    private var summaries: [Int: (summary: TraktReactionSummary, at: Date)] = [:]
    private var summaryTasks: [Int: Task<TraktReactionSummary?, Never>] = [:]
    private var liked: Set<Int> = []
    private var reacted: [Int: Set<TraktReaction>] = [:]
    private var viewerStateLoadedAt: Date?
    private var viewerStateTask: Task<Void, Never>?
    private var followingHandles: [String: Following]?
    private var blocked: Set<String> = []
    private var accountKey: String?
    private var accountObserver: UUID?
    /// Bumped whenever what was kept is forgotten, so an answer that arrives for the account before is dropped.
    private var generation = 0

    package init(client: TraktClient = .shared, account: TraktAccount = .shared, resolver: TraktResolver = .shared, defaults: UserDefaults = .standard) {
        self.client = client
        self.account = account
        self.resolver = resolver
        self.defaults = defaults
    }

    /// Whether the viewer can see the community at all: it comes from Trakt, so only while Trakt is connected.
    package var isAvailable: Bool { account.isConnected }

    /// Whether every part of the community is open to the viewer; without Pro a page shows a taste of it.
    package var isUnlocked: Bool { ProAccess.shared.hasFullAccess }

    /// How many comments a viewer without Pro reads in full before the rest asks for Pro.
    package static let freeCommentCount = 2

    // MARK: - Reading

    /// The Trakt title a Plex item is, for its community; nil when Trakt is not connected or the title is not matched.
    package func subject(ratingKey: String, api: APIClient) async -> TraktCommunitySubject? {
        guard isAvailable, let server = ServerBootstrap.savedMachineIdentifier else { return nil }
        resetIfAccountChanged()
        let key = "\(server)/\(ratingKey)"
        if let known = subjects[key] { return known }
        guard let target = await resolver.target(ratingKey: ratingKey, server: server, api: api),
              let subject = TraktCommunitySubject(target) else { return nil }
        subjects[key] = subject
        return subject
    }

    /// The community of `ratingKey` as last loaded and still fresh, so a page can lay it out in its first pass.
    package func cachedSnapshot(ratingKey: String, now: Date = Date()) -> Snapshot? {
        guard isAvailable, let server = ServerBootstrap.savedMachineIdentifier, let subject = subjects["\(server)/\(ratingKey)"],
              let entry = snapshots[subject.key], now.timeIntervalSince(entry.at) < Self.snapshotLifetime else { return nil }
        return entry.snapshot
    }

    /// The community of `ratingKey`: from the cache while fresh, else from Trakt, every part at once. A part Trakt does not
    /// answer is left out instead of failing the rest.
    package func snapshot(ratingKey: String, api: APIClient, now: Date = Date()) async -> Snapshot? {
        guard let subject = await subject(ratingKey: ratingKey, api: api) else { return nil }
        if let entry = snapshots[subject.key], now.timeIntervalSince(entry.at) < Self.snapshotLifetime { return entry.snapshot }
        if let running = snapshotTasks[subject.key] { return await running.value }
        let started = generation
        let task = Task<Snapshot?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.load(subject, ratingKey: ratingKey, api: api)
        }
        snapshotTasks[subject.key] = task
        let snapshot = await task.value
        guard started == generation else { return nil }
        snapshotTasks[subject.key] = nil
        if let snapshot { snapshots[subject.key] = (snapshot, now) }
        return snapshot
    }

    /// Loads the community again the next time a page asks, as a pull to refresh does.
    package func invalidate(_ subject: TraktCommunitySubject) {
        snapshots[subject.key] = nil
    }

    private func load(_ subject: TraktCommunitySubject, ratingKey: String, api: APIClient) async -> Snapshot? {
        async let stats = optional { try await self.client.send(.community(.stats(subject)), as: TraktTitleStats.self) }
        async let sentiments = subject.hasSentiments
            ? optional { try await self.client.send(.community(.sentiments(subject)), as: TraktSentiments.self) }
            : nil
        async let watching = optional { try await self.client.send(.community(.watching(subject)), as: [TraktUser].self) }
        async let comments = optional {
            try await self.client.paged(.community(.comments(subject, sort: .likes, page: 1, limit: Self.previewCount)), page: 1, as: TraktComment.self)
        }
        async let scores = TraktScores.shared.scores(ratingKey: ratingKey, api: api)
        let loadedStats = await stats
        let loadedSentiments = await sentiments
        let loadedWatching = await watching ?? []
        let loadedComments = await comments
        let loadedScores = await scores
        guard loadedStats != nil || loadedComments != nil || loadedSentiments != nil else {
            MidgarLog.notice("Trakt community of \(subject.key) not loaded", category: .trakt)
            return nil
        }
        let visible = (loadedComments?.items ?? []).filter { !blocked.contains($0.user.handle) }
        let snapshot = Snapshot(
            subject: subject,
            stats: loadedStats,
            score: loadedScores.first { $0.source == .trakt },
            distribution: TraktScores.shared.cachedDistribution(ratingKey: ratingKey),
            sentiments: loadedSentiments,
            watching: loadedWatching.filter { !blocked.contains($0.handle) },
            comments: visible,
            commentCount: max(loadedStats?.comments ?? 0, loadedComments?.itemCount ?? 0, visible.count)
        )
        Task { await self.loadViewerState() }
        return snapshot
    }

    /// One page of a title's comments in `sort` order.
    package func comments(on subject: TraktCommunitySubject, sort: TraktCommentSort, page: Int, limit: Int = TraktCommunityRoute.pageLimit) async throws -> TraktPage<TraktComment> {
        var result = try await client.paged(.community(.comments(subject, sort: sort, page: page, limit: limit)), page: page, as: TraktComment.self)
        result.items.removeAll { blocked.contains($0.user.handle) }
        Task { await self.loadViewerState() }
        return result
    }

    /// One page of the replies to a comment, oldest first as Trakt keeps them.
    package func replies(to commentID: Int, page: Int, limit: Int = TraktCommunityRoute.pageLimit) async throws -> TraktPage<TraktComment> {
        var result = try await client.paged(.community(.replies(commentID, page: page, limit: limit)), page: page, as: TraktComment.self)
        result.items.removeAll { blocked.contains($0.user.handle) }
        return result
    }

    /// A comment as Trakt has it now.
    package func comment(_ id: Int) async throws -> TraktComment {
        try await client.send(.community(.comment(id)), as: TraktComment.self)
    }

    /// The comments a sentiment was drawn from, as many as are worth one request each, in the order Trakt listed them.
    package func comments(ids: [Int]) async -> [TraktComment] {
        let wanted = Array(ids.prefix(Self.aspectCommentLimit))
        var found: [Int: TraktComment] = [:]
        await withTaskGroup(of: TraktComment?.self) { group in
            for id in wanted {
                group.addTask { try? await self.client.send(.community(.comment(id)), as: TraktComment.self) }
            }
            for await comment in group {
                if let comment { found[comment.id] = comment }
            }
        }
        return wanted.compactMap { found[$0] }.filter { !blocked.contains($0.user.handle) }
    }

    /// The comments a member wrote, newest first, with what each is on.
    package func comments(by handle: String, page: Int, limit: Int = TraktCommunityRoute.pageLimit) async throws -> TraktPage<TraktUserComment> {
        try await client.paged(.community(.userComments(handle, page: page, limit: limit)), page: page, as: TraktUserComment.self)
    }

    /// The reactions a comment has, as last loaded and still fresh.
    package func cachedSummary(_ commentID: Int, now: Date = Date()) -> TraktReactionSummary? {
        guard let entry = summaries[commentID], now.timeIntervalSince(entry.at) < Self.summaryLifetime else { return nil }
        return entry.summary
    }

    /// The reactions a comment has. Several cells asking at once share one request.
    package func summary(for commentID: Int, now: Date = Date()) async -> TraktReactionSummary? {
        if let cached = cachedSummary(commentID, now: now) { return cached }
        if let running = summaryTasks[commentID] { return await running.value }
        let task = Task<TraktReactionSummary?, Never> { [client] in
            try? await client.send(.community(.reactionSummary(commentID)), as: TraktReactionSummary.self)
        }
        summaryTasks[commentID] = task
        let summary = await task.value
        summaryTasks[commentID] = nil
        if let summary { summaries[commentID] = (summary, now) }
        return summary
    }

    /// Who reacted to a comment and how, newest first. The viewer's own reactions among them are remembered.
    package func reactions(to commentID: Int) async throws -> [TraktReactionEntry] {
        let page = try await client.paged(.community(.reactions(commentID, page: 1, limit: 100)), page: 1, as: TraktReactionEntry.self)
        if let me = account.profile?.username {
            let mine = Set(page.items.filter { $0.user.username == me }.map(\.reaction))
            if page.hasMore(limit: 100) { reacted[commentID, default: []].formUnion(mine) } else { reacted[commentID] = mine }
        }
        var counts: [TraktReaction: Int] = [:]
        for entry in page.items { counts[entry.reaction, default: 0] += 1 }
        if page.hasMore(limit: 100) == false {
            summaries[commentID] = (TraktReactionSummary(counts: counts, userCount: Set(page.items.map(\.user.username)).count), Date())
        }
        return page.items.filter { !blocked.contains($0.user.handle) }
    }

    // MARK: - The viewer

    /// Whether `comment` is the viewer's own, which they can edit and delete.
    package func isMine(_ comment: TraktComment) -> Bool {
        guard let me = account.profile?.username else { return false }
        return comment.user.username == me
    }

    package func isLiked(_ commentID: Int) -> Bool { liked.contains(commentID) }

    package func reactions(of commentID: Int) -> Set<TraktReaction> { reacted[commentID] ?? [] }

    /// Learns which comments the viewer liked or reacted to, the newest hundred of each, once in a while.
    package func loadViewerState(now: Date = Date()) async {
        resetIfAccountChanged()
        guard isAvailable else { return }
        if let loaded = viewerStateLoadedAt, now.timeIntervalSince(loaded) < Self.viewerStateLifetime { return }
        if let running = viewerStateTask { return await running.value }
        let started = generation
        let task = Task { [weak self] in
            guard let self else { return }
            async let likes = optional { try await self.client.send(.community(.likedComments(page: 1, limit: 100)), as: [LikedComment?].self) }
            async let reactions = optional { try await self.client.send(.community(.reactedComments(page: 1, limit: 100)), as: [ReactedComment?].self) }
            async let blocks = optional { try await self.client.send(.community(.blocked), as: [Blocked?].self) }
            let likedIDs = await likes?.compactMap { $0?.comment?.id }
            let reactedEntries = await reactions?.compactMap { $0 }
            let blockedHandles = await blocks?.compactMap { $0?.user.handle }
            guard !Task.isCancelled, started == self.generation else { return }
            if let likedIDs { self.liked.formUnion(likedIDs) }
            for entry in reactedEntries ?? [] {
                guard let id = entry.comment?.id else { continue }
                self.reacted[id, default: []].insert(entry.reaction.type)
            }
            if let blockedHandles { self.blocked.formUnion(blockedHandles) }
            guard likedIDs != nil || reactedEntries != nil || blockedHandles != nil else { return }
            self.viewerStateLoadedAt = now
            self.announce(.viewerState)
        }
        viewerStateTask = task
        await task.value
        if started == generation { viewerStateTask = nil }
    }

    private struct LikedComment: Decodable { struct ID: Decodable { let id: Int }; let comment: ID? }
    private struct ReactedComment: Decodable {
        struct ID: Decodable { let id: Int }
        struct Kind: Decodable { let type: TraktReaction }
        let comment: ID?
        let reaction: Kind
    }
    private struct Blocked: Decodable { let user: TraktUser }

    // MARK: - Writing

    /// Likes or unlikes `comment`, showing it at once and taking it back if Trakt refuses. Returns the comment as it now stands.
    @discardableResult
    package func setLiked(_ like: Bool, _ comment: TraktComment) async throws -> TraktComment {
        guard liked.contains(comment.id) != like else { return comment }
        var updated = comment
        updated.likeCount = max(0, comment.likeCount + (like ? 1 : -1))
        apply(liked: like, updated)
        do {
            try await client.sendVoid(.community(like ? .like(comment.id) : .unlike(comment.id)))
            MidgarLog.notice("Trakt comment \(comment.id) \(like ? "liked" : "unliked")", category: .trakt)
            return updated
        } catch TraktError.conflict {
            return updated
        } catch {
            apply(liked: !like, comment)
            throw Self.communityError(error)
        }
    }

    private func apply(liked like: Bool, _ comment: TraktComment) {
        if like { liked.insert(comment.id) } else { liked.remove(comment.id) }
        replaceInSnapshots(comment)
        announce(.updated(comment))
    }

    /// Turns the viewer's `reaction` to a comment on or off, at once and back again if Trakt refuses.
    package func setReaction(_ reaction: TraktReaction, active: Bool, on commentID: Int) async throws {
        guard reactions(of: commentID).contains(reaction) != active else { return }
        let before = cachedSummary(commentID)
        applyReaction(reaction, active: active, on: commentID, summary: before?.toggling(reaction, on: active))
        do {
            try await client.sendVoid(.community(active ? .react(commentID, reaction) : .unreact(commentID, reaction)))
            MidgarLog.notice("Trakt reaction \(reaction.rawValue) \(active ? "added to" : "removed from") comment \(commentID)", category: .trakt)
        } catch TraktError.conflict {
        } catch TraktError.notFound where !active {
        } catch {
            applyReaction(reaction, active: !active, on: commentID, summary: before)
            throw Self.communityError(error)
        }
        if before == nil, await summary(for: commentID) != nil { announce(.reactions(commentID)) }
    }

    private func applyReaction(_ reaction: TraktReaction, active: Bool, on commentID: Int, summary: TraktReactionSummary?) {
        if active { reacted[commentID, default: []].insert(reaction) } else { reacted[commentID]?.remove(reaction) }
        if let summary { summaries[commentID] = (summary, Date()) } else { summaries[commentID] = nil }
        announce(.reactions(commentID))
    }

    /// Posts a comment on `subject`. Trakt marks it a review from 200 words.
    package func post(_ text: String, spoiler: Bool, on subject: TraktCommunitySubject) async throws -> TraktComment {
        do {
            let comment = try await client.send(.community(.post(subject, text: text, spoiler: spoiler)), as: TraktComment.self)
            MidgarLog.notice("Trakt comment \(comment.id) posted on \(subject.key)", category: .trakt)
            if var entry = snapshots[subject.key] {
                entry.snapshot.comments.insert(comment, at: 0)
                entry.snapshot.commentCount += 1
                if let stats = entry.snapshot.stats {
                    entry.snapshot.stats = TraktTitleStats(watchers: stats.watchers, plays: stats.plays, collectors: stats.collectors, comments: stats.comments + 1, lists: stats.lists, votes: stats.votes, favorited: stats.favorited)
                }
                snapshots[subject.key] = entry
            }
            TraktCommentDrafts.clear(Self.draftKey(subject: subject), defaults: defaults)
            announce(.posted(comment, subjectKey: subject.key))
            return comment
        } catch {
            throw Self.communityError(error)
        }
    }

    /// Replies to `parent`, a top-level comment.
    package func reply(_ text: String, spoiler: Bool, to parent: TraktComment) async throws -> TraktComment {
        do {
            let reply = try await client.send(.community(.reply(parent.id, text: text, spoiler: spoiler)), as: TraktComment.self)
            MidgarLog.notice("Trakt reply \(reply.id) posted to \(parent.id)", category: .trakt)
            var counted = parent
            counted.replyCount += 1
            replaceInSnapshots(counted)
            TraktCommentDrafts.clear(Self.draftKey(replyingTo: parent.id), defaults: defaults)
            announce(.updated(counted))
            announce(.posted(reply, subjectKey: nil))
            return reply
        } catch {
            throw Self.communityError(error)
        }
    }

    /// Changes the text or the spoiler mark of the viewer's own comment.
    package func edit(_ comment: TraktComment, text: String, spoiler: Bool) async throws -> TraktComment {
        do {
            let edited = try await client.send(.community(.edit(comment.id, text: text, spoiler: spoiler)), as: TraktComment.self)
            MidgarLog.notice("Trakt comment \(comment.id) edited", category: .trakt)
            replaceInSnapshots(edited)
            announce(.updated(edited))
            return edited
        } catch {
            throw Self.communityError(error)
        }
    }

    /// Deletes the viewer's own comment. Trakt keeps a comment that is more than two weeks old and has replies.
    package func delete(_ comment: TraktComment) async throws {
        do {
            try await client.sendVoid(.community(.delete(comment.id)))
        } catch TraktError.conflict {
            throw TraktCommunityError.cannotDelete
        } catch TraktError.notFound {
        } catch {
            throw Self.communityError(error)
        }
        MidgarLog.notice("Trakt comment \(comment.id) deleted", category: .trakt)
        for (key, var entry) in snapshots where entry.snapshot.comments.contains(where: { $0.id == comment.id }) {
            entry.snapshot.comments.removeAll { $0.id == comment.id }
            entry.snapshot.commentCount = max(0, entry.snapshot.commentCount - 1)
            if let stats = entry.snapshot.stats {
                entry.snapshot.stats = TraktTitleStats(watchers: stats.watchers, plays: stats.plays, collectors: stats.collectors, comments: max(0, stats.comments - 1), lists: stats.lists, votes: stats.votes, favorited: stats.favorited)
            }
            snapshots[key] = entry
        }
        announce(.removed(comment.id))
    }

    /// Reports a comment to Trakt's moderators. Reporting the same comment again while a report waits counts as done.
    package func report(_ comment: TraktComment, reason: TraktCommentReportReason) async throws {
        do {
            try await client.sendVoid(.community(.reportComment(comment.id, reason)))
            MidgarLog.notice("Trakt comment \(comment.id) reported for \(reason.rawValue)", category: .trakt)
        } catch TraktError.conflict {
        } catch {
            throw Self.communityError(error)
        }
    }

    // MARK: - Members

    /// A member's profile; a private one shows only to its approved followers.
    package func profile(_ handle: String) async throws -> TraktUser {
        do {
            return try await client.send(.community(.profile(handle)), as: TraktUser.self)
        } catch {
            throw Self.communityError(error)
        }
    }

    /// What a member is watching right now, when they share it.
    package func watchingNow(_ handle: String) async -> TraktWatchingNow? {
        guard let now = try? await client.sendOptional(.community(.userWatching(handle)), as: TraktWatchingNow.self), !now.title.isEmpty else { return nil }
        return now
    }

    /// Whether the viewer follows `handle`, from the list of members they follow, read once.
    package func following(_ handle: String) async -> Following {
        if followingHandles == nil {
            let started = generation
            if let list = try? await client.send(.community(.following), as: [Follower].self), started == generation, followingHandles == nil {
                followingHandles = Dictionary(list.map { ($0.user.handle, Following.following) }, uniquingKeysWith: { first, _ in first })
            }
        }
        return followingHandles?[handle] ?? .notFollowing
    }

    private struct Follower: Decodable { let user: TraktUser }

    /// Follows or unfollows a member. Following a private member sends a request they approve.
    package func setFollowing(_ follow: Bool, handle: String) async throws -> Following {
        do {
            let state: Following
            if follow {
                let result = try await client.send(.community(.follow(handle)), as: TraktFollowResult.self)
                state = result.approvedAt == nil ? .requested : .following
            } else {
                try await client.sendVoid(.community(.unfollow(handle)))
                state = .notFollowing
            }
            followingHandles?[handle] = state
            announce(.relationship(handle))
            return state
        } catch TraktError.conflict {
            guard follow else { return .notFollowing }
            followingHandles = nil
            let state = await following(handle)
            return state == .following ? .following : .requested
        } catch {
            throw Self.communityError(error)
        }
    }

    /// Blocks a member: they stop following the viewer, and their comments leave every list here.
    package func block(_ handle: String) async throws {
        do {
            try await client.sendVoid(.community(.block(handle)))
        } catch TraktError.conflict {
        } catch {
            throw Self.communityError(error)
        }
        blocked.insert(handle)
        followingHandles?[handle] = .notFollowing
        for (key, var entry) in snapshots {
            entry.snapshot.comments.removeAll { $0.user.handle == handle }
            entry.snapshot.watching.removeAll { $0.handle == handle }
            snapshots[key] = entry
        }
        MidgarLog.notice("Trakt member blocked", category: .trakt)
        announce(.relationship(handle))
    }

    package func unblock(_ handle: String) async throws {
        do {
            try await client.sendVoid(.community(.unblock(handle)))
        } catch {
            throw Self.communityError(error)
        }
        blocked.remove(handle)
        snapshots = [:]
        announce(.relationship(handle))
    }

    package func isBlocked(_ handle: String) -> Bool { blocked.contains(handle) }

    /// Reports a member to Trakt's moderators.
    package func report(user handle: String, reason: TraktUserReportReason) async throws {
        do {
            try await client.sendVoid(.community(.reportUser(handle, reason)))
            MidgarLog.notice("Trakt member reported for \(reason.rawValue)", category: .trakt)
        } catch TraktError.conflict {
        } catch {
            throw Self.communityError(error)
        }
    }

    // MARK: - Drafts

    package static func draftKey(subject: TraktCommunitySubject) -> String { "comment.\(subject.key)" }
    package static func draftKey(replyingTo commentID: Int) -> String { "reply.\(commentID)" }

    // MARK: - Bookkeeping

    /// Forgets everything kept for the account that was connected, when it disconnects or another one connects.
    package func forgetAll() {
        generation += 1
        viewerStateTask?.cancel()
        viewerStateTask = nil
        subjects = [:]
        snapshots = [:]
        snapshotTasks.values.forEach { $0.cancel() }
        snapshotTasks = [:]
        summaries = [:]
        liked = []
        reacted = [:]
        viewerStateLoadedAt = nil
        followingHandles = nil
        blocked = []
    }

    private func resetIfAccountChanged() {
        let key = account.isConnected ? "\(TraktTokenStore.currentOwner)/\(account.profile?.username ?? "")" : nil
        if accountObserver == nil {
            accountObserver = account.observe { [weak self] in self?.resetIfAccountChanged() }
        }
        guard key != accountKey else { return }
        if accountKey != nil { forgetAll() }
        accountKey = key
    }

    private func replaceInSnapshots(_ comment: TraktComment) {
        for (key, var entry) in snapshots {
            guard let index = entry.snapshot.comments.firstIndex(where: { $0.id == comment.id }) else { continue }
            entry.snapshot.comments[index] = comment
            snapshots[key] = entry
        }
    }

    private func announce(_ change: Change) {
        NotificationCenter.default.post(name: .traktCommunityChanged, object: change)
    }

    /// A refused token on a community write may be a ban from commenting rather than a lost sign-in, so the account is checked
    /// again before anything says Trakt signed Crucible out.
    private static func communityError(_ error: Error) -> Error {
        if case TraktError.unauthorized = error {
            Task { @MainActor in await TraktAccount.shared.refreshProfile() }
            return TraktCommunityError.refused
        }
        return error
    }

    private func optional<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) async -> T? {
        do {
            return try await work()
        } catch {
            if !(error is CancellationError) {
                MidgarLog.notice("Trakt community part not loaded: \(error.localizedDescription)", category: .trakt)
            }
            return nil
        }
    }
}

/// Community failures with a message of their own.
package enum TraktCommunityError: Error, Equatable, LocalizedError {
    /// Trakt keeps a comment older than two weeks that has replies.
    case cannotDelete
    /// Trakt refused the account for this, which can mean commenting was suspended.
    case refused

    package var errorDescription: String? {
        switch self {
        case .cannotDelete: return String(localized: "Trakt keeps comments that are more than two weeks old and have replies, so this one can't be deleted.", comment: "Error deleting an old Trakt comment that has replies")
        case .refused: return String(localized: "Trakt didn't let this account do that. If Trakt suspended your commenting, its support can help.", comment: "Error when Trakt refuses a community action for the account")
        }
    }
}

/// Comments being written, kept per title or per comment replied to, so leaving the composer never loses them.
package enum TraktCommentDrafts {
    package struct Draft: Codable, Equatable, Sendable {
        package var text: String
        package var isSpoiler: Bool

        package init(text: String, isSpoiler: Bool) {
            self.text = text
            self.isSpoiler = isSpoiler
        }
    }

    private static func storageKey(_ key: String) -> String { "trakt.draft.\(TraktTokenStore.currentOwner).\(key)" }

    package static func load(_ key: String, defaults: UserDefaults = .standard) -> Draft? {
        defaults.data(forKey: storageKey(key)).flatMap { try? JSONDecoder().decode(Draft.self, from: $0) }
    }

    package static func save(_ draft: Draft, for key: String, defaults: UserDefaults = .standard) {
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return clear(key, defaults: defaults) }
        if let data = try? JSONEncoder().encode(draft) { defaults.set(data, forKey: storageKey(key)) }
    }

    package static func clear(_ key: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey(key))
    }

    /// Forgets the drafts of `owner`, or of everyone on this device when nil, as disconnecting or signing out does.
    package static func clearAll(owner: String?, defaults: UserDefaults = .standard) {
        let prefix = owner.map { "trakt.draft.\($0)." } ?? "trakt.draft."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Whether the viewer has read Trakt's rules for comments, which the composer shows until they have.
package enum TraktCommentRules {
    private static let key = "trakt.commentRulesSeen"

    package static func wereSeen(defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key) }

    package static func markSeen(defaults: UserDefaults = .standard) { defaults.set(true, forKey: key) }

    package static func forget(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}

extension TraktCommunity.Snapshot {
    /// What a page's community becomes after `change`: nil when the change is about something else, otherwise the new
    /// snapshot and whether comments came or went, which re-lays the page out instead of redrawing cards in place.
    package func applying(_ change: TraktCommunity.Change, isBlocked: (String) -> Bool) -> (snapshot: Self, reshaped: Bool)? {
        var next = self
        switch change {
        case .updated(let comment):
            guard let index = comments.firstIndex(where: { $0.id == comment.id }) else { return nil }
            next.comments[index] = comment
            return (next, false)
        case .removed(let id):
            guard comments.contains(where: { $0.id == id }) else { return nil }
            next.comments.removeAll { $0.id == id }
            next.commentCount = max(0, commentCount - 1)
            return (next, true)
        case .posted(let comment, let subjectKey):
            guard subjectKey == subject.key, !comments.contains(where: { $0.id == comment.id }) else { return nil }
            next.comments.insert(comment, at: 0)
            next.commentCount += 1
            return (next, true)
        case .reactions(let id):
            return comments.contains(where: { $0.id == id }) ? (next, false) : nil
        case .viewerState:
            return comments.isEmpty ? nil : (next, false)
        case .relationship:
            next.comments.removeAll { isBlocked($0.user.handle) }
            next.watching.removeAll { isBlocked($0.handle) }
            return (next, next.comments.count != comments.count || next.watching.count != watching.count)
        }
    }
}

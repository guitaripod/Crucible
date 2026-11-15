import Foundation

/// A Trakt member as comments, reactions, profiles and "watching now" show them.
package struct TraktUser: Decodable, Hashable, Sendable, Identifiable {
    package let username: String
    package let name: String?
    package let isPrivate: Bool
    package let isDeleted: Bool
    package let isVIP: Bool
    package let isDirector: Bool
    package let slug: String?
    package let traktID: Int?
    package let joinedAt: Date?
    package let location: String?
    package let about: String?
    package let avatarURL: URL?
    package let vipYears: Int?

    package init(
        username: String,
        name: String? = nil,
        isPrivate: Bool = false,
        isDeleted: Bool = false,
        isVIP: Bool = false,
        isDirector: Bool = false,
        slug: String? = nil,
        traktID: Int? = nil,
        joinedAt: Date? = nil,
        location: String? = nil,
        about: String? = nil,
        avatarURL: URL? = nil,
        vipYears: Int? = nil
    ) {
        self.username = username
        self.name = name
        self.isPrivate = isPrivate
        self.isDeleted = isDeleted
        self.isVIP = isVIP
        self.isDirector = isDirector
        self.slug = slug
        self.traktID = traktID
        self.joinedAt = joinedAt
        self.location = location
        self.about = about
        self.avatarURL = avatarURL
        self.vipYears = vipYears
    }

    private enum CodingKeys: String, CodingKey {
        case username, name, deleted, vip, director, ids, location, about, images
        case isPrivate = "private"
        case joinedAt = "joined_at"
        case vipEP = "vip_ep"
        case vipYears = "vip_years"
    }

    private struct IDs: Decodable { let slug: String?; let trakt: Int? }
    private struct Images: Decodable {
        struct Avatar: Decodable { let full: String? }
        let avatar: Avatar?
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decode(String.self, forKey: .username)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        isPrivate = (try? container.decodeIfPresent(Bool.self, forKey: .isPrivate)) ?? false
        isDeleted = (try? container.decodeIfPresent(Bool.self, forKey: .deleted)) ?? false
        let vip = (try? container.decodeIfPresent(Bool.self, forKey: .vip)) ?? false
        let vipEP = (try? container.decodeIfPresent(Bool.self, forKey: .vipEP)) ?? false
        isVIP = vip || vipEP
        isDirector = (try? container.decodeIfPresent(Bool.self, forKey: .director)) ?? false
        let ids = try? container.decodeIfPresent(IDs.self, forKey: .ids)
        slug = ids?.slug
        traktID = ids?.trakt
        joinedAt = TraktDate.parse(try? container.decodeIfPresent(String.self, forKey: .joinedAt))
        location = (try? container.decodeIfPresent(String.self, forKey: .location))?.trimmedOrNil
        about = (try? container.decodeIfPresent(String.self, forKey: .about))?.trimmedOrNil
        avatarURL = TraktImage.url((try? container.decodeIfPresent(Images.self, forKey: .images))?.avatar?.full)
        vipYears = try? container.decodeIfPresent(Int.self, forKey: .vipYears)
    }

    package var id: String { handle }

    /// What the user endpoints take as the member's id: the slug Trakt hands out, else the username.
    package var handle: String { slug ?? username }

    /// The name to show: the member's own name, else their username.
    package var displayName: String {
        guard let name = name?.trimmedOrNil else { return username }
        return name
    }

    /// One or two letters for a monogram when the member has no avatar.
    package var initials: String {
        let words = displayName.split(whereSeparator: { $0.isWhitespace || $0 == "_" || $0 == "-" || $0 == "." }).prefix(2)
        let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }

    /// The member's page on Trakt's website.
    package var webURL: URL? { URL(string: "https://trakt.tv/users/\(handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle)") }

    /// This profile with the avatar of `other` when it came without one: a profile is read without images, which comments carry.
    package func keepingAvatar(of other: TraktUser) -> TraktUser {
        guard avatarURL == nil, let avatar = other.avatarURL else { return self }
        return TraktUser(
            username: username, name: name, isPrivate: isPrivate, isDeleted: isDeleted, isVIP: isVIP, isDirector: isDirector, slug: slug,
            traktID: traktID, joinedAt: joinedAt, location: location, about: about, avatarURL: avatar, vipYears: vipYears
        )
    }
}

/// A comment or a reply on a movie, show, season, episode or list. A comment of 200 words or more is a review.
package struct TraktComment: Decodable, Hashable, Sendable, Identifiable {
    package let id: Int
    package let parentID: Int
    package let createdAt: Date
    package var updatedAt: Date?
    package var text: String
    package var gifURL: URL?
    package var isSpoiler: Bool
    package var isReview: Bool
    package var replyCount: Int
    package var likeCount: Int
    package let language: String?
    /// The author's own rating of the title, out of 10, when they rated it.
    package let authorRating: Int?
    /// How many times the author watched the title.
    package let authorPlays: Int
    package let user: TraktUser

    package init(
        id: Int,
        parentID: Int = 0,
        createdAt: Date,
        updatedAt: Date? = nil,
        text: String,
        gifURL: URL? = nil,
        isSpoiler: Bool = false,
        isReview: Bool = false,
        replyCount: Int = 0,
        likeCount: Int = 0,
        language: String? = "en",
        authorRating: Int? = nil,
        authorPlays: Int = 0,
        user: TraktUser
    ) {
        self.id = id
        self.parentID = parentID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.text = text
        self.gifURL = gifURL
        self.isSpoiler = isSpoiler
        self.isReview = isReview
        self.replyCount = replyCount
        self.likeCount = likeCount
        self.language = language
        self.authorRating = authorRating
        self.authorPlays = authorPlays
        self.user = user
    }

    private enum CodingKeys: String, CodingKey {
        case id, comment, gif, spoiler, review, replies, likes, language, user
        case parentID = "parent_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case userRating = "user_rating"
        case userStats = "user_stats"
    }

    private struct GIF: Decodable { let url: String? }
    private struct Stats: Decodable {
        let rating: Int?
        let playCount: Int?
        private enum CodingKeys: String, CodingKey { case rating; case playCount = "play_count" }
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        parentID = (try? container.decodeIfPresent(Int.self, forKey: .parentID)) ?? 0
        createdAt = TraktDate.parse(try? container.decodeIfPresent(String.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        updatedAt = TraktDate.parse(try? container.decodeIfPresent(String.self, forKey: .updatedAt))
        text = (try? container.decodeIfPresent(String.self, forKey: .comment)) ?? ""
        gifURL = (try? container.decodeIfPresent(GIF.self, forKey: .gif))?.url.flatMap(TraktImage.url)
        isSpoiler = (try? container.decodeIfPresent(Bool.self, forKey: .spoiler)) ?? false
        isReview = (try? container.decodeIfPresent(Bool.self, forKey: .review)) ?? false
        replyCount = (try? container.decodeIfPresent(Int.self, forKey: .replies)) ?? 0
        likeCount = (try? container.decodeIfPresent(Int.self, forKey: .likes)) ?? 0
        language = try? container.decodeIfPresent(String.self, forKey: .language)
        let stats = try? container.decodeIfPresent(Stats.self, forKey: .userStats)
        authorRating = (try? container.decodeIfPresent(Int.self, forKey: .userRating)) ?? stats?.rating
        authorPlays = stats?.playCount ?? 0
        user = try container.decode(TraktUser.self, forKey: .user)
    }

    package var isReply: Bool { parentID != 0 }

    /// Whether the author changed the text after posting it.
    package var wasEdited: Bool {
        guard let updatedAt else { return false }
        return updatedAt.timeIntervalSince(createdAt) > 60
    }

    /// The comment's page on Trakt's website.
    package var webURL: URL? { URL(string: "https://trakt.tv/comments/\(id)") }
}

/// The reactions Trakt offers on a comment, in the order its picker shows them.
package enum TraktReaction: String, CaseIterable, Codable, Hashable, Sendable {
    case like, love, laugh, shocked, bravo, dislike, spoiler

    package var emoji: String {
        switch self {
        case .like: return "\u{1F44D}"
        case .love: return "\u{2764}\u{FE0F}"
        case .laugh: return "\u{1F602}"
        case .shocked: return "\u{1F62E}"
        case .bravo: return "\u{1F44F}"
        case .dislike: return "\u{1F44E}"
        case .spoiler: return "\u{26A0}\u{FE0F}"
        }
    }

    package var title: String {
        switch self {
        case .like: return String(localized: "Like", comment: "Trakt comment reaction")
        case .love: return String(localized: "Love", comment: "Trakt comment reaction")
        case .laugh: return String(localized: "Funny", comment: "Trakt comment reaction: laughing")
        case .shocked: return String(localized: "Shocked", comment: "Trakt comment reaction")
        case .bravo: return String(localized: "Bravo", comment: "Trakt comment reaction: applause")
        case .dislike: return String(localized: "Dislike", comment: "Trakt comment reaction")
        case .spoiler: return String(localized: "Spoiler!", comment: "Trakt comment reaction that flags a spoiler")
        }
    }
}

/// How many people reacted to a comment, and with what.
package struct TraktReactionSummary: Decodable, Equatable, Sendable {
    package var reactionCount: Int
    package var userCount: Int
    package var counts: [TraktReaction: Int]

    package init(counts: [TraktReaction: Int], userCount: Int? = nil) {
        self.counts = counts.filter { $0.value > 0 }
        reactionCount = self.counts.values.reduce(0, +)
        self.userCount = userCount ?? reactionCount
    }

    private enum CodingKeys: String, CodingKey {
        case distribution
        case reactionCount = "reaction_count"
        case userCount = "user_count"
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? container.decodeIfPresent([String: Int].self, forKey: .distribution)) ?? [:]
        var counts: [TraktReaction: Int] = [:]
        for (key, value) in raw {
            guard let reaction = TraktReaction(rawValue: key), value > 0 else { continue }
            counts[reaction] = value
        }
        self.counts = counts
        reactionCount = (try? container.decodeIfPresent(Int.self, forKey: .reactionCount)) ?? counts.values.reduce(0, +)
        userCount = (try? container.decodeIfPresent(Int.self, forKey: .userCount)) ?? reactionCount
    }

    /// The reactions people used, most used first, ties in the picker's order.
    package var ranked: [(reaction: TraktReaction, count: Int)] {
        TraktReaction.allCases.compactMap { reaction in counts[reaction].map { (reaction, $0) } }
            .sorted { $0.count > $1.count }
    }

    /// The summary after the viewer turned `reaction` on or off.
    package func toggling(_ reaction: TraktReaction, on: Bool) -> TraktReactionSummary {
        var counts = counts
        counts[reaction] = max(0, (counts[reaction] ?? 0) + (on ? 1 : -1))
        return TraktReactionSummary(counts: counts, userCount: max(userCount + (on ? 1 : -1), 0))
    }

    package static let empty = TraktReactionSummary(counts: [:])
}

/// One person's reaction to a comment.
package struct TraktReactionEntry: Decodable, Hashable, Sendable {
    package let reaction: TraktReaction
    package let reactedAt: Date?
    package let user: TraktUser

    private enum CodingKeys: String, CodingKey { case reaction, user; case reactedAt = "reacted_at" }
    private struct Kind: Decodable { let type: TraktReaction }

    package init(reaction: TraktReaction, reactedAt: Date?, user: TraktUser) {
        self.reaction = reaction
        self.reactedAt = reactedAt
        self.user = user
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reaction = try container.decode(Kind.self, forKey: .reaction).type
        reactedAt = TraktDate.parse(try? container.decodeIfPresent(String.self, forKey: .reactedAt))
        user = try container.decode(TraktUser.self, forKey: .user)
    }
}

/// What people praise and criticise about a title, distilled by Trakt from its comments and reactions.
package struct TraktSentiments: Decodable, Equatable, Sendable {
    package struct Aspect: Decodable, Hashable, Sendable, Identifiable {
        package let text: String
        package let commentIDs: [Int]

        package init(text: String, commentIDs: [Int] = []) {
            self.text = text
            self.commentIDs = commentIDs
        }

        private enum CodingKeys: String, CodingKey { case sentiment; case commentIDs = "comment_ids" }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .sentiment).trimmingCharacters(in: .whitespacesAndNewlines)
            commentIDs = (try? container.decodeIfPresent([Int].self, forKey: .commentIDs)) ?? []
        }

        package var id: String { text }
    }

    package let good: [Aspect]
    package let bad: [Aspect]
    package let commentCount: Int
    package let analyzedAt: Date?

    package init(good: [Aspect], bad: [Aspect], commentCount: Int, analyzedAt: Date? = nil) {
        self.good = good
        self.bad = bad
        self.commentCount = commentCount
        self.analyzedAt = analyzedAt
    }

    private enum CodingKeys: String, CodingKey {
        case good, bad
        case commentCount = "comment_count"
        case analyzedAt = "analyzed_at"
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        good = ((try? container.decodeIfPresent([Aspect].self, forKey: .good)) ?? []).filter { !$0.text.isEmpty }
        bad = ((try? container.decodeIfPresent([Aspect].self, forKey: .bad)) ?? []).filter { !$0.text.isEmpty }
        commentCount = (try? container.decodeIfPresent(Int.self, forKey: .commentCount)) ?? 0
        analyzedAt = TraktDate.parse(try? container.decodeIfPresent(String.self, forKey: .analyzedAt))
    }

    package var isEmpty: Bool { good.isEmpty && bad.isEmpty }
}

/// How many people watched, played, collected, listed, discussed and rated a title.
package struct TraktTitleStats: Decodable, Equatable, Sendable {
    package let watchers: Int
    package let plays: Int
    package let collectors: Int
    package let comments: Int
    package let lists: Int
    package let votes: Int
    package let favorited: Int?

    package init(watchers: Int, plays: Int, collectors: Int = 0, comments: Int, lists: Int, votes: Int = 0, favorited: Int? = nil) {
        self.watchers = watchers
        self.plays = plays
        self.collectors = collectors
        self.comments = comments
        self.lists = lists
        self.votes = votes
        self.favorited = favorited
    }

    private enum CodingKeys: String, CodingKey { case watchers, plays, collectors, comments, lists, votes, favorited }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func count(_ key: CodingKeys) -> Int { (try? container.decodeIfPresent(Int.self, forKey: key)) ?? 0 }
        watchers = count(.watchers)
        plays = count(.plays)
        collectors = count(.collectors)
        comments = count(.comments)
        lists = count(.lists)
        votes = count(.votes)
        favorited = try? container.decodeIfPresent(Int.self, forKey: .favorited)
    }

    package var isEmpty: Bool { watchers == 0 && plays == 0 && comments == 0 && lists == 0 && (favorited ?? 0) == 0 }
}

/// How Trakt's voters spread across its ten-point scale.
package struct TraktRatingDistribution: Equatable, Sendable {
    /// Votes for 1 through 10, in that order.
    package let counts: [Int]

    package init?(counts: [Int]) {
        guard counts.count == 10, counts.contains(where: { $0 > 0 }) else { return nil }
        self.counts = counts.map { max(0, $0) }
    }

    /// Reads Trakt's `{"1": 143, …, "10": 8567}`, whose values may arrive as decimals.
    init?(raw: [String: Double]?) {
        guard let raw else { return nil }
        self.init(counts: (1...10).map { Int((raw[String($0)] ?? 0).rounded()) })
    }

    package var total: Int { counts.reduce(0, +) }

    /// The share of the votes that gave `score`, from 0 to 1.
    package func share(of score: Int) -> Double {
        guard (1...10).contains(score), total > 0 else { return 0 }
        return Double(counts[score - 1]) / Double(total)
    }

    /// The share of the most given score, which the tallest bar is drawn against.
    package var peakShare: Double { (1...10).map(share(of:)).max() ?? 0 }

    /// The score most voters gave.
    package var mode: Int { (counts.enumerated().max { $0.element < $1.element }?.offset ?? 0) + 1 }
}

/// The orders Trakt can list a title's comments in.
package enum TraktCommentSort: String, CaseIterable, Sendable {
    case likes, newest, replies, highest, lowest, plays, oldest

    package var title: String {
        switch self {
        case .likes: return String(localized: "Most Liked", comment: "Order of Trakt comments: most liked first")
        case .newest: return String(localized: "Newest", comment: "Order of Trakt comments: newest first")
        case .oldest: return String(localized: "Oldest", comment: "Order of Trakt comments: oldest first")
        case .replies: return String(localized: "Most Replies", comment: "Order of Trakt comments: most replied to first")
        case .highest: return String(localized: "Highest Rated", comment: "Order of Trakt comments: authors who rated the title highest first")
        case .lowest: return String(localized: "Lowest Rated", comment: "Order of Trakt comments: authors who rated the title lowest first")
        case .plays: return String(localized: "Most Watched", comment: "Order of Trakt comments: authors who watched the title most first")
        }
    }

    package var symbol: String {
        switch self {
        case .likes: return "heart"
        case .newest: return "clock"
        case .oldest: return "clock.arrow.circlepath"
        case .replies: return "bubble.left.and.bubble.right"
        case .highest: return "star"
        case .lowest: return "star.slash"
        case .plays: return "play.circle"
        }
    }
}

/// Why a comment is reported to Trakt's moderators.
package enum TraktCommentReportReason: String, CaseIterable, Sendable {
    case spoilers, abusive, spam, bigotry, political, language, offtopic, support, duplicate
    case tooShort = "too_short"
    case other

    package var title: String {
        switch self {
        case .spoilers: return String(localized: "Unmarked Spoilers", comment: "Reason for reporting a Trakt comment")
        case .abusive: return String(localized: "Harassment or Abuse", comment: "Reason for reporting a Trakt comment")
        case .spam: return String(localized: "Spam or Self-Promotion", comment: "Reason for reporting a Trakt comment")
        case .bigotry: return String(localized: "Hate Speech", comment: "Reason for reporting a Trakt comment: bigotry or discrimination")
        case .political: return String(localized: "Political Attack", comment: "Reason for reporting a Trakt comment")
        case .language: return String(localized: "Not in English", comment: "Reason for reporting a Trakt comment")
        case .offtopic: return String(localized: "Off Topic", comment: "Reason for reporting a Trakt comment")
        case .support: return String(localized: "Support Question", comment: "Reason for reporting a Trakt comment")
        case .duplicate: return String(localized: "Duplicate", comment: "Reason for reporting a Trakt comment")
        case .tooShort: return String(localized: "Too Short to Be Useful", comment: "Reason for reporting a Trakt comment")
        case .other: return String(localized: "Something Else", comment: "Reason for reporting a Trakt comment: anything else")
        }
    }
}

/// Why a member is reported to Trakt's moderators.
package enum TraktUserReportReason: String, CaseIterable, Sendable {
    case spam, adult, language, other

    package var title: String {
        switch self {
        case .spam: return String(localized: "Spam Account", comment: "Reason for reporting a Trakt member")
        case .adult: return String(localized: "Adult Content in Profile", comment: "Reason for reporting a Trakt member")
        case .language: return String(localized: "Profile Not in English", comment: "Reason for reporting a Trakt member")
        case .other: return String(localized: "Something Else", comment: "Reason for reporting a Trakt comment: anything else")
        }
    }
}

/// What a member is watching right now, when they share it.
package struct TraktWatchingNow: Decodable, Equatable, Sendable {
    package let title: String
    package let subtitle: String?

    private enum CodingKeys: String, CodingKey { case type, movie, show, episode }
    private struct Item: Decodable { let title: String?; let year: Int?; let season: Int?; let number: Int? }

    package init(title: String, subtitle: String?) {
        self.title = title
        self.subtitle = subtitle
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let movie = try? container.decodeIfPresent(Item.self, forKey: .movie)
        let show = try? container.decodeIfPresent(Item.self, forKey: .show)
        let episode = try? container.decodeIfPresent(Item.self, forKey: .episode)
        if let show, let episode {
            title = show.title ?? ""
            let code = [episode.season.map { "S\($0)" }, episode.number.map { "E\($0)" }].compactMap { $0 }.joined()
            subtitle = [code, episode.title].compactMap { $0?.trimmedOrNil }.joined(separator: " · ").trimmedOrNil
        } else {
            title = movie?.title ?? ""
            subtitle = movie?.year.map(String.init)
        }
    }
}

/// One comment of the viewer's own, with what it is on.
package struct TraktUserComment: Decodable, Sendable {
    package let comment: TraktComment
    package let itemTitle: String?

    private enum CodingKeys: String, CodingKey { case comment, movie, show, season, episode }
    private struct Item: Decodable { let title: String?; let number: Int? }

    package init(comment: TraktComment, itemTitle: String?) {
        self.comment = comment
        self.itemTitle = itemTitle
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        comment = try container.decode(TraktComment.self, forKey: .comment)
        let show = try? container.decodeIfPresent(Item.self, forKey: .show)
        if let episode = try? container.decodeIfPresent(Item.self, forKey: .episode) {
            itemTitle = [show?.title, episode.title].compactMap { $0?.trimmedOrNil }.joined(separator: " · ").trimmedOrNil
        } else if let season = try? container.decodeIfPresent(Item.self, forKey: .season) {
            itemTitle = [show?.title, season.number.map { String(localized: "Season \($0)") }].compactMap { $0 }.joined(separator: " · ").trimmedOrNil
        } else {
            itemTitle = (try? container.decodeIfPresent(Item.self, forKey: .movie))?.title ?? show?.title
        }
    }
}

/// The answer to a follow: approved at once for a public member, waiting for approval for a private one.
package struct TraktFollowResult: Decodable, Sendable {
    package let approvedAt: Date?

    private enum CodingKeys: String, CodingKey { case approvedAt = "approved_at" }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        approvedAt = TraktDate.parse(try? container.decodeIfPresent(String.self, forKey: .approvedAt))
    }
}

/// One page of a paged Trakt list, with how many pages and items Trakt says there are.
package struct TraktPage<Item: Sendable>: Sendable {
    package var items: [Item]
    package var page: Int
    package var pageCount: Int?
    package var itemCount: Int?

    package init(items: [Item], page: Int, pageCount: Int?, itemCount: Int?) {
        self.items = items
        self.page = page
        self.pageCount = pageCount
        self.itemCount = itemCount
    }

    /// Whether Trakt has a page after this one. Without a page count, a full page suggests there may be more.
    package func hasMore(limit: Int) -> Bool {
        if let pageCount { return page < pageCount }
        return items.count >= limit
    }
}

/// Image addresses as Trakt sends them, often without a scheme.
package enum TraktImage {
    package static func url(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return URL(string: raw.hasPrefix("http") ? raw : "https://" + raw)
    }
}

extension TraktDate {
    /// Reads a Trakt timestamp, with or without milliseconds.
    package static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

extension String {
    /// The string without surrounding whitespace, or nil when nothing is left.
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

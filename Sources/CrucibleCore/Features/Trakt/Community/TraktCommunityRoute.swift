import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The title a community screen is about, as Trakt addresses it: a movie, a show, or one episode of a show.
package enum TraktCommunitySubject: Hashable, Sendable {
    case movie(id: Int, slug: String?)
    case show(id: Int, slug: String?)
    case episode(showID: Int, showSlug: String?, season: Int, number: Int, episodeID: Int)

    /// The subject of a resolved Plex item. Seasons have no community page of their own in Crucible, so they have none.
    package init?(_ target: TraktTarget) {
        switch target.kind {
        case .movie:
            guard let id = target.ids.trakt else { return nil }
            self = .movie(id: id, slug: target.ids.slug)
        case .show:
            guard target.season == nil, let id = target.ids.trakt else { return nil }
            self = .show(id: id, slug: target.ids.slug)
        case .episode:
            guard let showID = target.showIDs?.trakt, let season = target.season, let number = target.number, let id = target.ids.trakt else { return nil }
            self = .episode(showID: showID, showSlug: target.showIDs?.slug, season: season, number: number, episodeID: id)
        }
    }

    /// The path every title route of this subject starts with.
    package var pathPrefix: String {
        switch self {
        case .movie(let id, _): return "/movies/\(id)"
        case .show(let id, _): return "/shows/\(id)"
        case .episode(let show, _, let season, let number, _): return "/shows/\(show)/seasons/\(season)/episodes/\(number)"
        }
    }

    /// Trakt distils what people say only for movies and shows.
    package var hasSentiments: Bool {
        if case .episode = self { return false }
        return true
    }

    /// The key and Trakt id a new comment is posted under.
    package var postItem: (key: String, id: Int) {
        switch self {
        case .movie(let id, _): return ("movie", id)
        case .show(let id, _): return ("show", id)
        case .episode(_, _, _, _, let id): return ("episode", id)
        }
    }

    /// A key that tells subjects apart in caches and drafts.
    package var key: String {
        switch self {
        case .movie(let id, _): return "movie.\(id)"
        case .show(let id, _): return "show.\(id)"
        case .episode(_, _, _, _, let id): return "episode.\(id)"
        }
    }

    /// The title's comments on Trakt's website.
    package var webURL: URL? {
        switch self {
        case .movie(let id, let slug): return URL(string: "https://trakt.tv/movies/\(slug ?? String(id))/comments")
        case .show(let id, let slug): return URL(string: "https://trakt.tv/shows/\(slug ?? String(id))/comments")
        case .episode(let show, let slug, let season, let number, _):
            return URL(string: "https://trakt.tv/shows/\(slug ?? String(show))/seasons/\(season)/episodes/\(number)/comments")
        }
    }
}

/// Every community route Crucible calls: comments, replies, likes, reactions, reports, what people say, who is watching,
/// and members' profiles, follows and blocks.
package enum TraktCommunityRoute: Sendable {
    case comments(TraktCommunitySubject, sort: TraktCommentSort, page: Int, limit: Int)
    case comment(Int)
    case replies(Int, page: Int, limit: Int)
    case post(TraktCommunitySubject, text: String, spoiler: Bool)
    case reply(Int, text: String, spoiler: Bool)
    case edit(Int, text: String, spoiler: Bool)
    case delete(Int)
    case like(Int)
    case unlike(Int)
    case react(Int, TraktReaction)
    case unreact(Int, TraktReaction)
    case reactionSummary(Int)
    case reactions(Int, page: Int, limit: Int)
    case reportComment(Int, TraktCommentReportReason)
    case sentiments(TraktCommunitySubject)
    case stats(TraktCommunitySubject)
    case watching(TraktCommunitySubject)
    case profile(String)
    case userWatching(String)
    case userComments(String, page: Int, limit: Int)
    case follow(String)
    case unfollow(String)
    case block(String)
    case unblock(String)
    case reportUser(String, TraktUserReportReason)
    case following
    case blocked
    case likedComments(page: Int, limit: Int)
    case reactedComments(page: Int, limit: Int)

    /// The most a page of comments or replies asks for.
    package static let pageLimit = 20

    var method: String {
        switch self {
        case .post, .reply, .like, .react, .reportComment, .follow, .block, .reportUser: return "POST"
        case .edit: return "PUT"
        case .delete, .unlike, .unreact, .unfollow, .unblock: return "DELETE"
        default: return "GET"
        }
    }

    /// Reads that are public work without a token, but Trakt hides comments of members the viewer blocked when one is sent,
    /// so every community call carries it.
    var requiresToken: Bool { true }

    var path: String {
        switch self {
        case .comments(let subject, let sort, _, _): return "\(subject.pathPrefix)/comments/\(sort.rawValue)"
        case .comment(let id), .edit(let id, _, _), .delete(let id): return "/comments/\(id)"
        case .replies(let id, _, _), .reply(let id, _, _): return "/comments/\(id)/replies"
        case .post: return "/comments"
        case .like(let id), .unlike(let id): return "/comments/\(id)/like"
        case .react(let id, let reaction), .unreact(let id, let reaction): return "/comments/\(id)/reactions/\(reaction.rawValue)"
        case .reactionSummary(let id): return "/comments/\(id)/reactions/summary"
        case .reactions(let id, _, _): return "/comments/\(id)/reactions"
        case .reportComment(let id, _): return "/comments/\(id)/report"
        case .sentiments(let subject): return "\(subject.pathPrefix)/sentiments"
        case .stats(let subject): return "\(subject.pathPrefix)/stats"
        case .watching(let subject): return "\(subject.pathPrefix)/watching"
        case .profile(let user): return "/users/\(Self.escaped(user))"
        case .userWatching(let user): return "/users/\(Self.escaped(user))/watching"
        case .userComments(let user, _, _): return "/users/\(Self.escaped(user))/comments/all/all"
        case .follow(let user), .unfollow(let user): return "/users/\(Self.escaped(user))/follow"
        case .block(let user), .unblock(let user): return "/users/\(Self.escaped(user))/block"
        case .reportUser(let user, _): return "/users/\(Self.escaped(user))/report"
        case .following: return "/users/me/following"
        case .blocked: return "/users/blocked"
        case .likedComments: return "/users/likes/comments"
        case .reactedComments: return "/users/reactions/comments"
        }
    }

    var queryItems: [URLQueryItem] {
        switch self {
        case .comments(_, _, let page, let limit), .replies(_, let page, let limit), .reactions(_, let page, let limit):
            return Self.paging(page, limit) + [URLQueryItem(name: "extended", value: "full,images")]
        case .userComments(_, let page, let limit):
            return Self.paging(page, limit) + [
                URLQueryItem(name: "extended", value: "full,images"),
                URLQueryItem(name: "include_replies", value: "true"),
            ]
        case .likedComments(let page, let limit), .reactedComments(let page, let limit):
            return Self.paging(page, limit) + [URLQueryItem(name: "extended", value: "min")]
        case .following:
            return [URLQueryItem(name: "extended", value: "full,images")]
        case .profile:
            return [URLQueryItem(name: "extended", value: "full,vip")]
        case .watching, .userWatching:
            return [URLQueryItem(name: "extended", value: "full")]
        default:
            return []
        }
    }

    func body() throws -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        switch self {
        case .post(let subject, let text, let spoiler):
            let item = subject.postItem
            return try encoder.encode(PostBody(key: item.key, id: item.id, comment: text, spoiler: spoiler))
        case .reply(_, let text, let spoiler), .edit(_, let text, let spoiler):
            return try encoder.encode(TextBody(comment: text, spoiler: spoiler))
        case .reportComment(_, let reason):
            return try encoder.encode(["reason": reason.rawValue])
        case .reportUser(_, let reason):
            return try encoder.encode(["reason": reason.rawValue])
        default:
            return nil
        }
    }

    private static func paging(_ page: Int, _ limit: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "page", value: String(max(page, 1))), URLQueryItem(name: "limit", value: String(limit))]
    }

    /// A member's slug as one path segment: the request escapes what needs it, so only a slash, which would split it, is dropped.
    private static func escaped(_ user: String) -> String {
        user.replacingOccurrences(of: "/", with: "")
    }

    private struct TextBody: Encodable {
        let comment: String
        let spoiler: Bool
    }

    /// A new comment: the text, the spoiler flag and the item under its kind, named by its Trakt id only, as Trakt requires.
    private struct PostBody: Encodable {
        let key: String
        let id: Int
        let comment: String
        let spoiler: Bool

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ string: String) { stringValue = string }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        private struct Item: Encodable {
            struct IDs: Encodable { let trakt: Int }
            let ids: IDs
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(comment, forKey: Key("comment"))
            try container.encode(spoiler, forKey: Key("spoiler"))
            try container.encode(Item(ids: .init(trakt: id)), forKey: Key(key))
        }
    }
}

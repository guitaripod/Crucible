@testable import CrucibleCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CrucibleDemo

/// The demo's stand-in Trakt community, read and written through the app's own Trakt client.
struct DemoTraktCommunityTests {
    private func client(_ demo: DemoHarness) async -> TraktClient {
        let base = demo.base
        let transport = TraktTransport { request in
            var request = request
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            components.scheme = base.scheme
            components.host = base.host
            components.port = base.port
            request.url = components.url
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, response as! HTTPURLResponse)
        }
        let store = TraktTokenStore(keychain: .memory(), owner: { "demo-community" })
        await store.save(TraktToken(accessToken: "demo-trakt", refreshToken: "r", expiresIn: 604_800, createdAt: Int(Date().timeIntervalSince1970)))
        return TraktClient(transport: transport, tokens: store, sleep: { _ in }, clientID: { "crucible-demo" })
    }

    private let movie = TraktCommunitySubject.movie(id: 1001, slug: nil)

    @Test func aMovieHasAPagedCommunityWithEveryPart() async throws {
        try await withDemo { demo in
            let client = await client(demo)
            let page = try await client.paged(.community(.comments(movie, sort: .likes, page: 1, limit: 5)), page: 1, as: TraktComment.self)
            #expect(page.items.count == 5)
            #expect((page.itemCount ?? 0) >= 14 && (page.pageCount ?? 0) >= 3)
            #expect(page.items.map(\.likeCount) == page.items.map(\.likeCount).sorted(by: >))
            #expect(page.items.contains { $0.isReview })
            let second = try await client.paged(.community(.comments(movie, sort: .likes, page: 2, limit: 5)), page: 2, as: TraktComment.self)
            #expect(Set(second.items.map(\.id)).isDisjoint(with: page.items.map(\.id)))
            let stats = try await client.send(.community(.stats(movie)), as: TraktTitleStats.self)
            #expect(stats.watchers > 0 && stats.comments == page.itemCount)
            let sentiments = try await client.send(.community(.sentiments(movie)), as: TraktSentiments.self)
            #expect(!sentiments.good.isEmpty && !sentiments.bad.isEmpty)
            let quoted = try await client.send(.community(.comment(try #require(sentiments.good.first?.commentIDs.first))), as: TraktComment.self)
            #expect(!quoted.text.isEmpty)
            let watching = try await client.send(.community(.watching(movie)), as: [TraktUser].self)
            #expect(!watching.isEmpty && !watching.contains { $0.isPrivate })
            let ratings = try await client.send(.ratings(kind: .movie, ids: TraktIDs(trakt: 1001), season: nil, number: nil, showID: nil), as: TraktRatings.self)
            #expect(ratings.traktDistribution != nil)
        }
    }

    @Test func repliesComeAfterTheirComment() async throws {
        try await withDemo { demo in
            let client = await client(demo)
            let page = try await client.paged(.community(.comments(movie, sort: .likes, page: 1, limit: 30)), page: 1, as: TraktComment.self)
            for comment in page.items where comment.replyCount > 0 {
                let replies = try await client.paged(.community(.replies(comment.id, page: 1, limit: 20)), page: 1, as: TraktComment.self)
                #expect(replies.items.count == comment.replyCount)
                #expect(replies.items.allSatisfy { $0.createdAt >= comment.createdAt && $0.parentID == comment.id })
            }
        }
    }

    @Test func aCommentIsPostedLikedReactedToRepliedToEditedAndDeleted() async throws {
        try await withDemo { demo in
            let client = await client(demo)
            await #expect(throws: TraktError.rejected(["must be at least 5 words"])) {
                try await client.send(.community(.post(movie, text: "Too short", spoiler: false)), as: TraktComment.self)
            }
            let posted = try await client.send(.community(.post(movie, text: "A quiet film that stays with you", spoiler: true)), as: TraktComment.self)
            #expect(posted.user.username == "demo" && posted.isSpoiler)
            let newest = try await client.paged(.community(.comments(movie, sort: .newest, page: 1, limit: 3)), page: 1, as: TraktComment.self)
            #expect(newest.items.first?.id == posted.id)

            let other = try #require(newest.items.first { $0.id != posted.id })
            try await client.sendVoid(.community(.like(other.id)))
            let liked = try await client.send(.community(.comment(other.id)), as: TraktComment.self)
            #expect(liked.likeCount == other.likeCount + 1)
            await #expect(throws: TraktError.self) { try await client.sendVoid(.community(.like(other.id))) }
            let likes = try await client.send(.community(.likedComments(page: 1, limit: 100)), as: [[String: AnyDecodable]].self)
            #expect(likes.count == 1)

            try await client.sendVoid(.community(.react(other.id, .laugh)))
            let summary = try await client.send(.community(.reactionSummary(other.id)), as: TraktReactionSummary.self)
            #expect((summary.counts[.laugh] ?? 0) >= 1)
            let reactors = try await client.paged(.community(.reactions(other.id, page: 1, limit: 100)), page: 1, as: TraktReactionEntry.self)
            #expect(reactors.items.contains { $0.user.username == "demo" && $0.reaction == .laugh })

            let reply = try await client.send(.community(.reply(posted.id, text: "Answering my own comment here today", spoiler: false)), as: TraktComment.self)
            #expect(reply.parentID == posted.id)
            let replies = try await client.paged(.community(.replies(posted.id, page: 1, limit: 20)), page: 1, as: TraktComment.self)
            #expect(replies.items.map(\.id) == [reply.id])

            let edited = try await client.send(.community(.edit(posted.id, text: "A quiet film that stays with you for days", spoiler: false)), as: TraktComment.self)
            #expect(edited.text.hasSuffix("for days") && !edited.isSpoiler && edited.wasEdited)
            await #expect(throws: TraktError.unauthorized) { try await client.sendVoid(.community(.delete(other.id))) }
            try await client.sendVoid(.community(.delete(posted.id)))
            await #expect(throws: TraktError.notFound) { try await client.send(.community(.comment(posted.id)), as: TraktComment.self) }
        }
    }

    @Test func membersHaveProfilesFollowsAndBlocks() async throws {
        try await withDemo { demo in
            let client = await client(demo)
            let ana = try await client.send(.community(.profile("ana_lumen")), as: TraktUser.self)
            #expect(ana.isVIP && ana.about != nil && ana.joinedAt != nil)
            let follow = try await client.send(.community(.follow("ana_lumen")), as: TraktFollowResult.self)
            #expect(follow.approvedAt != nil)
            let request = try await client.send(.community(.follow("midnightmatinee")), as: TraktFollowResult.self)
            #expect(request.approvedAt == nil)
            let following = try await client.send(.community(.following), as: [[String: AnyDecodable]].self)
            #expect(following.count == 1)
            let comments = try await client.paged(.community(.userComments("marlowe", page: 1, limit: 10)), page: 1, as: TraktUserComment.self)
            #expect(!comments.items.isEmpty && comments.items.allSatisfy { $0.comment.user.username == "marlowe" && $0.itemTitle != nil })
            try await client.sendVoid(.community(.block("marlowe")))
            let after = try await client.paged(.community(.comments(movie, sort: .likes, page: 1, limit: 100)), page: 1, as: TraktComment.self)
            #expect(!after.items.contains { $0.user.username == "marlowe" })
            let blocked = try await client.send(.community(.blocked), as: [[String: AnyDecodable]].self)
            #expect(blocked.count == 1)
            for handle in ["ana_lumen", "kestrel", "pixelmonk", "nightowl_reels", "juniper.watches", "sable", "harborlight", "quillfeather", "basement_cinema", "tomas.frames"] {
                try await client.sendVoid(.community(.block(handle)))
            }
            #expect(try await client.send(.community(.watching(movie)), as: [TraktUser].self).isEmpty)
        }
    }
}

/// Decodes any JSON value, for counting entries whose shape the test does not care about.
private struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer()
    }
}

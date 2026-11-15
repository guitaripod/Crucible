import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CrucibleCore

enum CommunityFixtures {
    static let user = #"{"username":"ana_lumen","private":false,"deleted":false,"name":"Ana Lumen","vip":true,"vip_ep":false,"director":false,"ids":{"slug":"ana_lumen","trakt":41},"images":{"avatar":{"full":"walter-r2.trakt.tv/images/users/041/avatars/large/ab.jpg"}}}"#

    static func comment(id: Int = 7, parent: Int = 0, text: String = "Gorgeous to look at, a little slow in the middle.", likes: Int = 12, replies: Int = 2, spoiler: Bool = false, user: String = user) -> String {
        """
        {"id":\(id),"parent_id":\(parent),"created_at":"2026-10-01T10:00:00.000Z","updated_at":"2026-10-01T10:30:00.000Z","comment":"\(text)",\
        "spoiler":\(spoiler),"review":false,"replies":\(replies),"likes":\(likes),"language":"en","user_rating":8,\
        "user_stats":{"rating":8,"play_count":3,"completed_count":3},"user":\(user)}
        """
    }
}

struct TraktCommunityRouteTests {
    private func request(_ route: TraktCommunityRoute) throws -> URLRequest {
        try TraktEndpoint.community(route).urlRequest(token: "t", clientID: "c")
    }

    @Test func commentsOfEachKindOfTitleAskForAPageWithAvatars() throws {
        let movie = try request(.comments(.movie(id: 12, slug: "halcyon"), sort: .likes, page: 2, limit: 20))
        #expect(movie.url?.path == "/movies/12/comments/likes")
        let query = URLComponents(url: movie.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "page", value: "2")))
        #expect(query.contains(URLQueryItem(name: "limit", value: "20")))
        #expect(query.contains(URLQueryItem(name: "extended", value: "full,images")))
        #expect(movie.httpMethod == "GET")
        #expect(movie.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        let show = try request(.comments(.show(id: 40, slug: nil), sort: .newest, page: 1, limit: 10))
        #expect(show.url?.path == "/shows/40/comments/newest")
        let episode = try request(.comments(.episode(showID: 40, showSlug: nil, season: 2, number: 5, episodeID: 900), sort: .highest, page: 1, limit: 10))
        #expect(episode.url?.path == "/shows/40/seasons/2/episodes/5/comments/highest")
    }

    @Test func aNewCommentNamesItsTitleByTraktIDOnly() throws {
        let post = try request(.post(.episode(showID: 40, showSlug: "dry-season", season: 2, number: 5, episodeID: 900), text: "Five words make a comment", spoiler: true))
        #expect(post.url?.path == "/comments")
        #expect(post.httpMethod == "POST")
        let body = try #require(try JSONSerialization.jsonObject(with: post.httpBody!) as? [String: Any])
        #expect(body["comment"] as? String == "Five words make a comment")
        #expect(body["spoiler"] as? Bool == true)
        #expect((body["episode"] as? [String: Any])?["ids"] as? [String: Int] == ["trakt": 900])
        #expect(body["movie"] == nil && body["show"] == nil)
        #expect(TraktEndpoint.community(.post(.movie(id: 1, slug: nil), text: "x", spoiler: false)).isWrite)
    }

    @Test func repliesEditsAndDeletesUseTheCommentsOwnRoutes() throws {
        let reply = try request(.reply(7, text: "Completely agree with all of that", spoiler: false))
        #expect(reply.url?.path == "/comments/7/replies" && reply.httpMethod == "POST")
        let body = try #require(try JSONSerialization.jsonObject(with: reply.httpBody!) as? [String: Any])
        #expect(body["comment"] as? String == "Completely agree with all of that" && body["spoiler"] as? Bool == false && body.count == 2)
        let edit = try request(.edit(7, text: "Changed my mind about the ending", spoiler: true))
        #expect(edit.url?.path == "/comments/7" && edit.httpMethod == "PUT")
        let delete = try request(.delete(7))
        #expect(delete.url?.path == "/comments/7" && delete.httpMethod == "DELETE" && delete.httpBody == nil)
    }

    @Test func likesAndReactionsAreWritesWithoutABody() throws {
        let like = try request(.like(7))
        #expect(like.url?.path == "/comments/7/like" && like.httpMethod == "POST" && like.httpBody == nil)
        #expect(try request(.unlike(7)).httpMethod == "DELETE")
        let react = try request(.react(7, .laugh))
        #expect(react.url?.path == "/comments/7/reactions/laugh" && react.httpMethod == "POST")
        #expect(try request(.unreact(7, .spoiler)).url?.path == "/comments/7/reactions/spoiler")
        #expect(try request(.reactionSummary(7)).url?.path == "/comments/7/reactions/summary")
        #expect(TraktEndpoint.community(.react(7, .love)).isWrite)
        #expect(!TraktEndpoint.community(.reactionSummary(7)).isWrite)
    }

    @Test func reportsCarryTraktsReasonCodes() throws {
        let comment = try request(.reportComment(7, .tooShort))
        #expect(comment.url?.path == "/comments/7/report")
        #expect(try JSONSerialization.jsonObject(with: comment.httpBody!) as? [String: String] == ["reason": "too_short"])
        let user = try request(.reportUser("ana_lumen", .spam))
        #expect(user.url?.path == "/users/ana_lumen/report")
        #expect(try JSONSerialization.jsonObject(with: user.httpBody!) as? [String: String] == ["reason": "spam"])
    }

    @Test func membersAreAddressedBySlugAndEscaped() throws {
        #expect(try request(.profile("ana_lumen")).url?.path == "/users/ana_lumen")
        #expect(try request(.follow("a b")).url?.absoluteString.contains("/users/a%20b/follow") == true)
        #expect(try request(.block("x/y")).url?.path == "/users/xy/block")
        #expect(try request(.userComments("ana_lumen", page: 1, limit: 20)).url?.path == "/users/ana_lumen/comments/all/all")
        #expect(try request(.following).url?.path == "/users/me/following")
        #expect(try request(.likedComments(page: 1, limit: 100)).url?.path == "/users/likes/comments")
        #expect(try request(.reactedComments(page: 1, limit: 100)).url?.path == "/users/reactions/comments")
    }

    @Test func titleRoutesFollowTheSubject() throws {
        let subject = TraktCommunitySubject.episode(showID: 40, showSlug: nil, season: 1, number: 3, episodeID: 77)
        #expect(try request(.stats(subject)).url?.path == "/shows/40/seasons/1/episodes/3/stats")
        #expect(try request(.watching(subject)).url?.path == "/shows/40/seasons/1/episodes/3/watching")
        #expect(try request(.sentiments(.movie(id: 12, slug: nil))).url?.path == "/movies/12/sentiments")
        #expect(!subject.hasSentiments)
        #expect(TraktCommunitySubject.show(id: 1, slug: nil).hasSentiments)
    }

    @Test func subjectsComeFromResolvedTitlesButNotSeasons() {
        #expect(TraktCommunitySubject(TraktTarget(kind: .movie, ids: TraktIDs(trakt: 5, slug: "m"))) == .movie(id: 5, slug: "m"))
        #expect(TraktCommunitySubject(TraktTarget(kind: .show, ids: TraktIDs(trakt: 6))) == .show(id: 6, slug: nil))
        #expect(TraktCommunitySubject(TraktTarget(kind: .show, ids: TraktIDs(trakt: 6), showIDs: TraktIDs(trakt: 6), season: 2)) == nil)
        let episode = TraktTarget(kind: .episode, ids: TraktIDs(trakt: 99), showIDs: TraktIDs(trakt: 6, slug: "s"), season: 2, number: 4)
        #expect(TraktCommunitySubject(episode) == .episode(showID: 6, showSlug: "s", season: 2, number: 4, episodeID: 99))
        #expect(TraktCommunitySubject(TraktTarget(kind: .movie, ids: TraktIDs(imdb: "tt1"))) == nil)
        #expect(TraktCommunitySubject.movie(id: 5, slug: "m").webURL?.absoluteString == "https://trakt.tv/movies/m/comments")
    }
}

struct TraktCommunityDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func aCommentCarriesItsAuthorTheirRatingAndCounts() throws {
        let comment = try decode(TraktComment.self, CommunityFixtures.comment())
        #expect(comment.id == 7 && !comment.isReply)
        #expect(comment.likeCount == 12 && comment.replyCount == 2)
        #expect(comment.authorRating == 8 && comment.authorPlays == 3)
        #expect(comment.user.displayName == "Ana Lumen" && comment.user.isVIP && comment.user.handle == "ana_lumen")
        #expect(comment.user.avatarURL?.absoluteString == "https://walter-r2.trakt.tv/images/users/041/avatars/large/ab.jpg")
        #expect(comment.wasEdited)
        #expect(comment.webURL?.absoluteString == "https://trakt.tv/comments/7")
    }

    @Test func aMinimalMemberStillDecodes() throws {
        let user = try decode(TraktUser.self, #"{"username":"kestrel","private":true}"#)
        #expect(user.displayName == "kestrel" && user.isPrivate && !user.isVIP && user.avatarURL == nil)
        #expect(user.initials == "K")
        #expect(TraktUser(username: "x", name: "Mae Lindqvist").initials == "ML")
    }

    @Test func reactionSummariesSkipKindsCrucibleDoesNotKnow() throws {
        let summary = try decode(TraktReactionSummary.self, #"{"reaction_count":9,"user_count":6,"distribution":{"like":4,"laugh":5,"sparkle":3,"love":0}}"#)
        #expect(summary.counts == [.like: 4, .laugh: 5])
        #expect(summary.ranked.map(\.reaction) == [.laugh, .like])
        #expect(summary.userCount == 6)
        let toggled = summary.toggling(.love, on: true)
        #expect(toggled.counts[.love] == 1 && toggled.reactionCount == 10)
        #expect(toggled.toggling(.love, on: false).counts[.love] == nil)
    }

    @Test func sentimentsDropEmptyAspects() throws {
        let sentiments = try decode(TraktSentiments.self, #"{"good":[{"sentiment":" Stunning visuals ","comment_ids":[1,2]},{"sentiment":""}],"bad":[{"sentiment":"Too long"}],"analyzed_at":"2026-11-01T00:00:00.000Z","comment_count":42}"#)
        #expect(sentiments.good.map(\.text) == ["Stunning visuals"])
        #expect(sentiments.good.first?.commentIDs == [1, 2])
        #expect(sentiments.bad.first?.commentIDs == [])
        #expect(sentiments.commentCount == 42 && !sentiments.isEmpty)
    }

    @Test func statsOfAnEpisodeHaveNoFavorites() throws {
        let stats = try decode(TraktTitleStats.self, #"{"watchers":10,"plays":14,"collectors":3,"comments":2,"lists":1,"votes":5}"#)
        #expect(stats.favorited == nil && stats.plays == 14 && !stats.isEmpty)
        #expect(try decode(TraktTitleStats.self, "{}").isEmpty)
    }

    @Test func theSpreadOfVotesIsReadNestedOrFlat() throws {
        let nested = try decode(TraktRatings.self, #"{"trakt":{"rating":8.1,"votes":100,"distribution":{"1":1,"2":1,"3":1,"4":2,"5":5,"6":10,"7":20,"8":30,"9":20,"10":10}}}"#)
        let spread = try #require(nested.traktDistribution)
        #expect(spread.total == 100 && spread.mode == 8)
        #expect(spread.share(of: 8) == 0.3 && spread.peakShare == 0.3)
        #expect(spread.share(of: 11) == 0)
        let flat = try decode(TraktRatings.self, #"{"rating":7,"votes":3,"distribution":{"1":0,"2":0,"3":0,"4":0,"5":0,"6":0,"7":2.0,"8":1,"9":0,"10":0}}"#)
        #expect(flat.traktDistribution?.counts[6] == 2)
        #expect(TraktRatingDistribution(counts: Array(repeating: 0, count: 10)) == nil)
        #expect(TraktRatingDistribution(counts: [1, 2]) == nil)
    }

    @Test func whatAMemberWatchesNamesTheShowAndEpisode() throws {
        let episode = try decode(TraktWatchingNow.self, #"{"type":"episode","episode":{"season":2,"number":5,"title":"Low Tide"},"show":{"title":"Dry Season"}}"#)
        #expect(episode.title == "Dry Season" && episode.subtitle == "S2E5 · Low Tide")
        let movie = try decode(TraktWatchingNow.self, #"{"type":"movie","movie":{"title":"Halcyon","year":2024}}"#)
        #expect(movie.title == "Halcyon" && movie.subtitle == "2024")
    }

    @Test func aMembersCommentNamesWhatItIsOn() throws {
        let entry = try decode(TraktUserComment.self, "{\"type\":\"movie\",\"comment\":\(CommunityFixtures.comment()),\"movie\":{\"title\":\"Halcyon\"}}")
        #expect(entry.itemTitle == "Halcyon" && entry.comment.id == 7)
    }

    @Test func reactionsNameTheirMember() throws {
        let entry = try decode(TraktReactionEntry.self, "{\"reacted_at\":\"2026-11-01T10:00:00Z\",\"reaction\":{\"type\":\"bravo\"},\"user\":\(CommunityFixtures.user)}")
        #expect(entry.reaction == .bravo && entry.user.username == "ana_lumen" && entry.reactedAt != nil)
    }
}

struct TraktCommentTextTests {
    @Test func emphasisCodeAndLinksBecomeStyledRuns() {
        let text = TraktCommentText("A **bold** and *quiet* film with `code` and [a link](https://trakt.tv) and ~~gone~~.")
        #expect(text.plainText == "A bold and quiet film with code and a link and gone.")
        #expect(text.runs.first { $0.text == "bold" }?.styles == [.bold])
        #expect(text.runs.first { $0.text == "quiet" }?.styles == [.italic])
        #expect(text.runs.first { $0.text == "code" }?.styles == [.code])
        #expect(text.runs.first { $0.text == "a link" }?.link?.absoluteString == "https://trakt.tv")
        #expect(text.runs.first { $0.text == "gone" }?.styles == [.strike])
    }

    @Test func markersWithoutPartnersStayAsWritten() {
        #expect(TraktCommentText("snake_case_name and 2 * 3 = 6").plainText == "snake_case_name and 2 * 3 = 6")
        #expect(TraktCommentText("a lone **star").plainText == "a lone **star")
        #expect(TraktCommentText(#"escaped \*not italic\*"#).plainText == "escaped *not italic*")
        #expect(TraktCommentText("[not a link](javascript:alert)").runs.allSatisfy { $0.link == nil })
    }

    @Test func bareAddressesBecomeLinksWithoutTrailingPunctuation() {
        let text = TraktCommentText("See https://trakt.tv/movies/halcyon, it's great.")
        let link = text.runs.first { $0.link != nil }
        #expect(link?.text == "https://trakt.tv/movies/halcyon")
        #expect(text.plainText == "See https://trakt.tv/movies/halcyon, it's great.")
    }

    @Test func spoilerTagsHideTheirPartAnyCaseAndToTheEndWhenUnclosed() {
        let text = TraktCommentText("Great until [SPOILER]the dog dies[/Spoiler] at the end.")
        #expect(text.hasInlineSpoilers)
        #expect(text.runs.filter(\.isSpoiler).map(\.text).joined() == "the dog dies")
        #expect(text.plainText == "Great until the dog dies at the end.")
        #expect(text.textHidingSpoilers == "Great until [\(TraktCommunityCopy.spoilerWord)] at the end.")
        let unclosed = TraktCommentText("Fine [spoiler]then everything")
        #expect(unclosed.runs.last?.isSpoiler == true && unclosed.runs.last?.text == "then everything")
        #expect(!TraktCommentText("No spoilers here at all").hasInlineSpoilers)
    }

    @Test func spoilersKeepTheirOwnEmphasis() {
        let text = TraktCommentText("[spoiler]**he lives**[/spoiler]")
        #expect(text.runs == [TraktCommentText.Run(text: "he lives", styles: [.bold], isSpoiler: true)])
    }

    @Test func emphasisAndQuotesReachAcrossASpoilerTag() {
        let bold = TraktCommentText("**Big [spoiler]twist[/spoiler] ending**")
        #expect(bold.runs == [
            TraktCommentText.Run(text: "Big ", styles: [.bold]),
            TraktCommentText.Run(text: "twist", styles: [.bold], isSpoiler: true),
            TraktCommentText.Run(text: " ending", styles: [.bold]),
        ])
        let quote = TraktCommentText("> a [spoiler]b[/spoiler] c")
        #expect(quote.runs.allSatisfy { $0.styles.contains(.quote) })
        #expect(quote.runs.map(\.text).joined() == "a b c")
        #expect(TraktCommentText(#"\*[spoiler]x[/spoiler]"#).runs == [TraktCommentText.Run(text: "*"), TraktCommentText.Run(text: "x", isSpoiler: true)])
    }

    @Test func shortCodesBecomeEmojiAndUnknownOnesStay() {
        #expect(TraktCommentText("Loved it :joy: :+1: :not_a_code: 10:30").plainText == "Loved it 😂 👍 :not_a_code: 10:30")
    }

    @Test func quotedLinesAreMarked() {
        let text = TraktCommentText("> the best line\nmy reply")
        #expect(text.runs.first?.styles.contains(.quote) == true)
        #expect(text.runs.first?.text == "the best line\n")
        #expect(text.runs.last?.styles.contains(.quote) == false)
    }
}

struct TraktCommentDraftTests {
    @Test func wordsAreCountedWithoutTagsOrStrayPunctuation() {
        #expect(TraktCommentDraft("One two - three [spoiler]four[/spoiler] five!").wordCount == 5)
        #expect(TraktCommentDraft("  ").wordCount == 0)
        #expect(TraktCommentDraft("a b c d").canPost == false)
        #expect(TraktCommentDraft("a b c d e").canPost)
    }

    @Test func twoHundredWordsMakeAReview() {
        let review = TraktCommentDraft(Array(repeating: "word", count: 200).joined(separator: " "))
        #expect(review.isReview && review.reviewProgress == 1)
        #expect(!TraktCommentDraft(Array(repeating: "word", count: 199).joined(separator: " ")).isReview)
    }

    @Test func concernsNameTheRuleAtRisk() {
        #expect(TraktCommentDraft("too short").concerns == [.tooShort(missing: 3)])
        #expect(TraktCommentDraft("Это очень хороший фильм, мне понравилось").concerns.contains(.notEnglish))
        #expect(!TraktCommentDraft("Amélie is a lovely, whimsical café film").concerns.contains(.notEnglish))
        #expect(TraktCommentDraft("Loved every single minute of it via Crucible").concerns.contains(.appTag))
        #expect(TraktCommentDraft("Loved every single minute of it").concerns.isEmpty)
        #expect(TraktCommunityCopy.concern(TraktCommentDraft("")) == nil)
        #expect(TraktCommunityCopy.concern(TraktCommentDraft("two words")) == TraktCommunityCopy.wordsMissing(3))
    }

    @Test func hidingAsSpoilerWrapsTheSelectionOrPlacesTheCursorInside() {
        let wrapped = TraktCommentDraft.wrappingSpoiler("The dog dies", range: NSRange(location: 4, length: 3))
        #expect(wrapped.text == "The [spoiler]dog[/spoiler] dies")
        #expect(wrapped.cursor == NSRange(location: 26, length: 0))
        let empty = TraktCommentDraft.wrappingSpoiler("End", range: NSRange(location: 3, length: 0))
        #expect(empty.text == "End[spoiler][/spoiler]")
        #expect(empty.cursor == NSRange(location: 12, length: 0))
        let outOfRange = TraktCommentDraft.wrappingSpoiler("ab", range: NSRange(location: 9, length: 4))
        #expect(outOfRange.text == "ab[spoiler][/spoiler]")
    }
}

struct TraktCommunityClientTests {
    private func client(_ script: TraktScript) async -> TraktClient {
        let store = TraktTokenStore(keychain: .memory(), owner: { "community" })
        await store.save(TraktFixtures.token())
        return TraktClient(transport: script.transport, tokens: store, sleep: { _ in }, clientID: { "client" })
    }

    @Test func aRefusedCommentCarriesTraktsReasons() async throws {
        let script = TraktScript()
        script.queue("/comments", 422, #"{"comment":["must be at least 5 words","must be written in English"]}"#)
        let client = await client(script)
        await #expect(throws: TraktError.rejected(["must be at least 5 words", "must be written in English"])) {
            try await client.send(.community(.post(.movie(id: 1, slug: nil), text: "too short", spoiler: false)), as: TraktComment.self)
        }
        #expect(TraktError.rejected(["must be at least 5 words"]).errorDescription?.contains("must be at least 5 words") == true)
    }

    @Test func aRefusedScrobbleIsNotTakenForACommentRule() async throws {
        let script = TraktScript()
        script.queue("/scrobble/stop", 422)
        let client = await client(script)
        await #expect(throws: TraktError.invalidItem) {
            try await client.sendVoid(.scrobble(.stop, kind: .movie, ids: TraktIDs(trakt: 1), progress: 0.5))
        }
    }

    @Test func pagesReportTheirPageAndItemCounts() async throws {
        let script = TraktScript()
        script.queue("/movies/1/comments/likes", 200, "[\(CommunityFixtures.comment())]", headers: ["X-Pagination-Page-Count": "3", "X-Pagination-Item-Count": "41"])
        let client = await client(script)
        let page = try await client.paged(.community(.comments(.movie(id: 1, slug: nil), sort: .likes, page: 1, limit: 20)), page: 1, as: TraktComment.self)
        #expect(page.items.count == 1 && page.pageCount == 3 && page.itemCount == 41)
        #expect(page.hasMore(limit: 20))
        #expect(!TraktPage<Int>(items: [1], page: 3, pageCount: 3, itemCount: nil).hasMore(limit: 1))
        #expect(TraktPage<Int>(items: [1, 2], page: 1, pageCount: nil, itemCount: nil).hasMore(limit: 2))
    }

    @Test func nothingWatchedIsNoContent() async throws {
        let script = TraktScript()
        script.queue("/users/ana_lumen/watching", 204, "")
        let client = await client(script)
        let now = try await client.sendOptional(.community(.userWatching("ana_lumen")), as: TraktWatchingNow.self)
        #expect(now == nil)
    }

    @Test func validationMessagesAreReadFromAnyShape() {
        #expect(TraktError.validationMessages(in: Data(#"["a","b","a"]"#.utf8)) == ["a", "b"])
        #expect(TraktError.validationMessages(in: Data(#"{"errors":{"comment":["x"]}}"#.utf8)) == ["x"])
        #expect(TraktError.validationMessages(in: Data("not json".utf8)) == [])
    }
}

@MainActor
struct TraktCommunityServiceTests {
    @MainActor
    private struct Rig {
        let script = TraktScript()
        let community: TraktCommunity
        let account: TraktAccount

        init() async {
            let store = TraktTokenStore(keychain: .memory(), owner: { "community-service" })
            let client = TraktClient(transport: script.transport, tokens: store, sleep: { _ in }, clientID: { "client" })
            let defaults = UserDefaults(suiteName: "trakt-community-\(UUID().uuidString)")!
            account = TraktAccount(tokens: store, defaults: defaults, client: client)
            community = TraktCommunity(client: client, account: account, resolver: TraktResolver(storage: nil), defaults: defaults)
            script.queue("/users/settings", 200, #"{"user":{"username":"sam"}}"#)
            await account.connect(with: TraktFixtures.token())
        }

        func comment(_ json: String = CommunityFixtures.comment()) throws -> TraktComment {
            try JSONDecoder().decode(TraktComment.self, from: Data(json.utf8))
        }
    }

    @Test func aLikeShowsAtOnceAndIsTakenBackWhenTraktRefuses() async throws {
        let rig = await Rig()
        let comment = try rig.comment()
        rig.script.queue("/comments/7/like", 204, "")
        let liked = try await rig.community.setLiked(true, comment)
        #expect(liked.likeCount == 13 && rig.community.isLiked(7))
        #expect(rig.script.requests.last?.httpMethod == "POST")
        rig.script.queue("/comments/7/like", 500)
        rig.script.queue("/comments/7/like", 500)
        await #expect(throws: TraktError.unavailable) { try await rig.community.setLiked(false, liked) }
        #expect(rig.community.isLiked(7))
    }

    @Test func likingTwiceSendsNothingTheSecondTime() async throws {
        let rig = await Rig()
        let comment = try rig.comment()
        rig.script.queue("/comments/7/like", 204, "")
        let liked = try await rig.community.setLiked(true, comment)
        let again = try await rig.community.setLiked(true, liked)
        #expect(again == liked)
        #expect(rig.script.paths().filter { $0 == "/comments/7/like" }.count == 1)
    }

    @Test func aReactionCountsAtOnceAndGoesBackWhenRefused() async throws {
        let rig = await Rig()
        rig.script.queue("/comments/7/reactions/summary", 200, #"{"reaction_count":2,"user_count":2,"distribution":{"like":2}}"#)
        _ = await rig.community.summary(for: 7)
        rig.script.queue("/comments/7/reactions/laugh", 204, "")
        try await rig.community.setReaction(.laugh, active: true, on: 7)
        #expect(rig.community.reactions(of: 7) == [.laugh])
        #expect(rig.community.cachedSummary(7)?.counts == [.like: 2, .laugh: 1])
        rig.script.queue("/comments/7/reactions/laugh", 429)
        rig.script.queue("/comments/7/reactions/laugh", 429)
        rig.script.queue("/comments/7/reactions/laugh", 429)
        await #expect(throws: TraktError.rateLimited) { try await rig.community.setReaction(.laugh, active: false, on: 7) }
        #expect(rig.community.reactions(of: 7) == [.laugh])
        #expect(rig.community.cachedSummary(7)?.counts[.laugh] == 1)
    }

    @Test func theViewersOwnReactionsAreLearnedFromWhoReacted() async throws {
        let rig = await Rig()
        let sam = #"{"username":"sam","private":false}"#
        rig.script.queue("/comments/7/reactions", 200, "[{\"reacted_at\":\"2026-11-01T10:00:00Z\",\"reaction\":{\"type\":\"love\"},\"user\":\(sam)},{\"reacted_at\":\"2026-11-01T09:00:00Z\",\"reaction\":{\"type\":\"like\"},\"user\":\(CommunityFixtures.user)}]")
        let entries = try await rig.community.reactions(to: 7)
        #expect(entries.count == 2)
        #expect(rig.community.reactions(of: 7) == [.love])
        #expect(rig.community.cachedSummary(7)?.counts == [.love: 1, .like: 1])
    }

    @Test func onlyTheViewersOwnCommentsAreTheirs() async throws {
        let rig = await Rig()
        #expect(!rig.community.isMine(try rig.comment()))
        #expect(rig.community.isMine(try rig.comment(CommunityFixtures.comment(user: #"{"username":"sam","private":false}"#))))
    }

    @Test func anOldCommentWithRepliesCannotBeDeleted() async throws {
        let rig = await Rig()
        rig.script.queue("/comments/7", 409, "")
        await #expect(throws: TraktCommunityError.cannotDelete) { try await rig.community.delete(try rig.comment()) }
        rig.script.queue("/comments/7", 204, "")
        try await rig.community.delete(try rig.comment())
    }

    @Test func aBannedCommenterIsNotSignedOut() async throws {
        let rig = await Rig()
        rig.script.queue("/comments", 401)
        rig.script.queue("/oauth/token", 200, TraktFixtures.tokenJSON(access: "fresh", refresh: "next"))
        rig.script.queue("/comments", 401)
        rig.script.queue("/users/settings", 200, #"{"user":{"username":"sam"}}"#)
        await #expect(throws: TraktCommunityError.refused) {
            try await rig.community.post("This is a perfectly fine comment", spoiler: false, on: .movie(id: 1, slug: nil))
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(rig.account.isConnected)
    }

    @Test func reportingTwiceCountsAsReported() async throws {
        let rig = await Rig()
        rig.script.queue("/comments/7/report", 409, "")
        try await rig.community.report(try rig.comment(), reason: .spam)
    }

    @Test func blockingHidesTheMembersComments() async throws {
        let rig = await Rig()
        rig.script.queue("/users/ana_lumen/block", 201, "")
        try await rig.community.block("ana_lumen")
        #expect(rig.community.isBlocked("ana_lumen"))
        rig.script.queue("/movies/1/comments/likes", 200, "[\(CommunityFixtures.comment())]")
        let page = try await rig.community.comments(on: .movie(id: 1, slug: nil), sort: .likes, page: 1)
        #expect(page.items.isEmpty)
    }

    @Test func followingAPrivateMemberWaitsForApproval() async throws {
        let rig = await Rig()
        rig.script.queue("/users/me/following", 200, "[]")
        #expect(await rig.community.following("midnightmatinee") == .notFollowing)
        rig.script.queue("/users/midnightmatinee/follow", 201, #"{"approved_at":null,"user":{"username":"midnightmatinee","private":true}}"#)
        #expect(try await rig.community.setFollowing(true, handle: "midnightmatinee") == .requested)
        #expect(await rig.community.following("midnightmatinee") == .requested)
        rig.script.queue("/users/ana_lumen/follow", 201, "{\"approved_at\":\"2026-11-01T10:00:00Z\",\"user\":\(CommunityFixtures.user)}")
        #expect(try await rig.community.setFollowing(true, handle: "ana_lumen") == .following)
        rig.script.queue("/users/ana_lumen/follow", 204, "")
        #expect(try await rig.community.setFollowing(false, handle: "ana_lumen") == .notFollowing)
    }

    @Test func aSentimentReadsItsCommentsInTraktsOrder() async throws {
        let rig = await Rig()
        rig.script.queue("/comments/3", 200, CommunityFixtures.comment(id: 3))
        rig.script.queue("/comments/1", 200, CommunityFixtures.comment(id: 1))
        rig.script.queue("/comments/2", 404)
        let comments = await rig.community.comments(ids: [3, 2, 1])
        #expect(comments.map(\.id) == [3, 1])
    }

    @Test func draftsAreKeptPerTitleAndClearedWhenEmpty() {
        let defaults = UserDefaults(suiteName: "trakt-drafts-\(UUID().uuidString)")!
        TraktCommentDrafts.save(.init(text: "Half a thought", isSpoiler: true), for: "comment.movie.1", defaults: defaults)
        #expect(TraktCommentDrafts.load("comment.movie.1", defaults: defaults) == .init(text: "Half a thought", isSpoiler: true))
        #expect(TraktCommentDrafts.load("comment.movie.2", defaults: defaults) == nil)
        TraktCommentDrafts.save(.init(text: "   ", isSpoiler: false), for: "comment.movie.1", defaults: defaults)
        #expect(TraktCommentDrafts.load("comment.movie.1", defaults: defaults) == nil)
    }

    @Test func disconnectingForgetsTheDraftsOfThatAccountOnly() async {
        let rig = await Rig()
        let defaults = UserDefaults(suiteName: "trakt-drafts-owner-\(UUID().uuidString)")!
        defaults.set(Data(), forKey: "trakt.draft.a.comment.movie.1")
        defaults.set(Data(), forKey: "trakt.draft.b.comment.movie.1")
        TraktCommentDrafts.clearAll(owner: "a", defaults: defaults)
        #expect(defaults.object(forKey: "trakt.draft.a.comment.movie.1") == nil)
        #expect(defaults.object(forKey: "trakt.draft.b.comment.movie.1") != nil)
        TraktCommentDrafts.clearAll(owner: nil, defaults: defaults)
        #expect(defaults.object(forKey: "trakt.draft.b.comment.movie.1") == nil)
        TraktCommentRules.markSeen(defaults: defaults)
        TraktCommentRules.forget(defaults: defaults)
        #expect(!TraktCommentRules.wereSeen(defaults: defaults))
        _ = rig
    }

    @Test func traktCommunityIsListedOnlyWithTraktConnected() {
        #expect(!ProFeature.listed(isTV: false, includingTrakt: false).contains(.traktCommunity))
        #expect(ProFeature.listed(isTV: true, includingTrakt: true).contains(.traktCommunity))
        #expect(ProTVPresentation.reasonLine(for: .traktCommunity) != nil)
    }
}

@MainActor
struct TraktCommunityReviewFixTests {
    @MainActor
    private struct Rig {
        let script = TraktScript()
        let community: TraktCommunity
        let account: TraktAccount

        init() async {
            let store = TraktTokenStore(keychain: .memory(), owner: { "community-fixes" })
            let client = TraktClient(transport: script.transport, tokens: store, sleep: { _ in }, clientID: { "client" })
            let defaults = UserDefaults(suiteName: "trakt-community-fixes-\(UUID().uuidString)")!
            account = TraktAccount(tokens: store, defaults: defaults, client: client)
            community = TraktCommunity(client: client, account: account, resolver: TraktResolver(storage: nil), defaults: defaults)
            script.queue("/users/settings", 200, #"{"user":{"username":"sam"}}"#)
            await account.connect(with: TraktFixtures.token())
        }
    }

    @Test func aReactionWithoutAKnownSummaryAsksTraktForTheRealOne() async throws {
        let rig = await Rig()
        rig.script.queue("/comments/7/reactions/love", 204, "")
        rig.script.queue("/comments/7/reactions/summary", 200, #"{"reaction_count":5,"user_count":5,"distribution":{"love":5}}"#)
        try await rig.community.setReaction(.love, active: true, on: 7)
        #expect(rig.community.cachedSummary(7)?.counts == [.love: 5])
    }

    @Test func aFollowAlreadyAskedForStaysRequested() async throws {
        let rig = await Rig()
        rig.script.queue("/users/me/following", 200, "[]")
        #expect(await rig.community.following("midnightmatinee") == .notFollowing)
        rig.script.queue("/users/midnightmatinee/follow", 409, "")
        rig.script.queue("/users/me/following", 200, "[]")
        #expect(try await rig.community.setFollowing(true, handle: "midnightmatinee") == .requested)
    }

    @Test func viewerStateSkipsEmptyEntriesAndLearnsBlocks() async throws {
        let rig = await Rig()
        rig.script.queue("/users/likes/comments", 200, #"[{"liked_at":"2026-11-01T10:00:00Z","type":"comment","comment":null},{"liked_at":"2026-11-01T10:00:00Z","type":"comment","comment":{"id":9}}]"#)
        rig.script.queue("/users/reactions/comments", 200, #"[{"reacted_at":"2026-11-01T10:00:00Z","reaction":{"type":"bravo"},"type":"comment","comment":{"id":4}}]"#)
        rig.script.queue("/users/blocked", 200, "[{\"blocked_at\":\"2026-11-01T10:00:00Z\",\"user\":\(CommunityFixtures.user)}]")
        await rig.community.loadViewerState()
        #expect(rig.community.isLiked(9))
        #expect(rig.community.reactions(of: 4) == [.bravo])
        #expect(rig.community.isBlocked("ana_lumen"))
    }

    @Test func aFailedViewerStateIsAskedForAgain() async throws {
        let rig = await Rig()
        await rig.community.loadViewerState()
        rig.script.queue("/users/likes/comments", 200, #"[{"liked_at":"2026-11-01T10:00:00Z","type":"comment","comment":{"id":3}}]"#)
        await rig.community.loadViewerState()
        #expect(rig.community.isLiked(3))
    }

    @Test func aProfileKeepsTheAvatarItsCommentShowed() throws {
        let fromComment = try JSONDecoder().decode(TraktUser.self, from: Data(CommunityFixtures.user.utf8))
        let profile = TraktUser(username: "ana_lumen", name: "Ana Lumen", about: "Slow cinema")
        let merged = profile.keepingAvatar(of: fromComment)
        #expect(merged.avatarURL == fromComment.avatarURL && merged.about == "Slow cinema")
    }

    @Test func profilesAndWatchingAskOnlyForWhatTheirRoutesTake() throws {
        let profile = try TraktEndpoint.community(.profile("x")).urlRequest(token: "t", clientID: "c")
        #expect(profile.url?.query == "extended=full,vip")
        let watching = try TraktEndpoint.community(.watching(.movie(id: 1, slug: nil))).urlRequest(token: "t", clientID: "c")
        #expect(watching.url?.query == "extended=full")
        #expect(try TraktEndpoint.community(.blocked).urlRequest(token: "t", clientID: "c").url?.path == "/users/blocked")
    }
}

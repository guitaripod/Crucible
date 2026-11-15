import CrucibleCore
import Foundation

/// What the viewer did in the stand-in Trakt's community while the demo runs: comments they wrote, changed or deleted, the
/// comments they liked or reacted to, and the members they follow or blocked.
struct DemoTraktCommunityState {
    var posted: [Int: DemoJSON] = [:]
    var postedSubject: [Int: String] = [:]
    var edits: [Int: (text: String, spoiler: Bool, at: Date)] = [:]
    var deleted = Set<Int>()
    var likes: [Int: Date] = [:]
    var reactions: [Int: [String: Date]] = [:]
    var follows: [String: Date] = [:]
    var blocks = Set<String>()
    var nextID = 90_000_000
}

/// The stand-in Trakt's community: every title of the catalogue has steady, believable comments, replies, reactions, what
/// people say, who is watching and how many watch it, drawn from the title's own rating key so screenshots and tests always
/// see the same page, plus whatever the viewer adds.
extension DemoLibrary {
    struct DemoMember {
        let username: String
        let name: String?
        let vip: Bool
        let director: Bool
        let isPrivate: Bool
        let location: String?
        let about: String?
        let joined: String

        var json: DemoJSON {
            var json: DemoJSON = [
                "username": username, "private": isPrivate, "deleted": false, "vip": vip, "vip_ep": false, "director": director,
                "ids": ["slug": username, "trakt": username.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) % 100_000 }] as DemoJSON,
                "joined_at": joined,
            ]
            if let name { json["name"] = name }
            if !isPrivate {
                if let location { json["location"] = location }
                if let about { json["about"] = about }
            }
            if vip { json["vip_years"] = 4 + username.count % 6 }
            return json
        }
    }

    static let communityMembers: [DemoMember] = [
        DemoMember(username: "ana_lumen", name: "Ana Lumen", vip: true, director: false, isPrivate: false, location: "Lisbon", about: "Slow cinema, fast opinions. Rewatching everything A24 ever touched.", joined: "2015-03-14T10:00:00.000Z"),
        DemoMember(username: "marlowe", name: "Marlowe Kent", vip: false, director: false, isPrivate: false, location: "Bristol", about: "Noir, westerns and anything with a good score.", joined: "2017-09-02T10:00:00.000Z"),
        DemoMember(username: "kestrel", name: nil, vip: false, director: false, isPrivate: false, location: nil, about: nil, joined: "2021-01-20T10:00:00.000Z"),
        DemoMember(username: "pixelmonk", name: "Theo Park", vip: true, director: false, isPrivate: false, location: "Seoul", about: "Colorist by day. I notice the grade before the plot.", joined: "2014-06-11T10:00:00.000Z"),
        DemoMember(username: "nightowl_reels", name: "Noor Haddad", vip: false, director: false, isPrivate: false, location: "Amman", about: "Midnight screenings only.", joined: "2019-11-30T10:00:00.000Z"),
        DemoMember(username: "juniper.watches", name: "Juniper", vip: false, director: false, isPrivate: false, location: "Portland", about: "Cozy mysteries and documentaries about bread.", joined: "2020-04-05T10:00:00.000Z"),
        DemoMember(username: "sable", name: "Sable Okafor", vip: true, director: true, isPrivate: false, location: "Lagos", about: "Short films and too many festival badges.", joined: "2013-02-17T10:00:00.000Z"),
        DemoMember(username: "harborlight", name: "Ines Varga", vip: false, director: false, isPrivate: false, location: "Budapest", about: "Here for the slow burns.", joined: "2018-08-23T10:00:00.000Z"),
        DemoMember(username: "quillfeather", name: "Quill", vip: false, director: false, isPrivate: false, location: "Edinburgh", about: "Book first, film second, argue third.", joined: "2022-05-09T10:00:00.000Z"),
        DemoMember(username: "basement_cinema", name: "Lou Becker", vip: true, director: false, isPrivate: false, location: "Hamburg", about: "Projector, couch, popcorn machine. In that order.", joined: "2016-12-01T10:00:00.000Z"),
        DemoMember(username: "tomas.frames", name: "Tomás Ruiz", vip: false, director: false, isPrivate: false, location: "Valencia", about: "Sci-fi completionist.", joined: "2023-03-18T10:00:00.000Z"),
        DemoMember(username: "midnightmatinee", name: "Mae Lindqvist", vip: false, director: false, isPrivate: true, location: "Malmö", about: nil, joined: "2016-07-07T10:00:00.000Z"),
    ]

    private static var demoViewer: DemoJSON {
        [
            "username": "demo", "name": "Demo Viewer", "private": false, "deleted": false, "vip": false, "vip_ep": false, "director": false,
            "ids": ["slug": "demo", "trakt": 1] as DemoJSON, "joined_at": "2024-01-01T10:00:00.000Z",
        ]
    }

    private static let shouts = [
        "The last twenty minutes of {title} had me holding my breath. Worth it for that alone.",
        "Gorgeous to look at, a little slow in the middle, but the ending lands. :clap:",
        "I went in blind and that's the way to do it. **Don't read anything first.**",
        "Solid, but I expected more after all the hype. The score carries a lot of it.",
        "Rewatched {title} last night and caught so many details I missed the first time.",
        "That cast! Every single performance feels lived in. :heart_eyes:",
        "Not for me. The pacing dragged and I never cared about the lead. Still, the cinematography is *lovely*.",
        "Perfect Sunday night watch. Cozy, funny, and it sticks the landing.",
        "[spoiler]The reveal about the letter[/spoiler] completely reframed everything before it. Brilliant writing.",
        "Underrated. More people need to see this one, it deserves a much bigger audience.",
        "The sound design is unreal on a good system. Turn it up and thank me later.",
        "Funny how a story this quiet can hit this hard. :sob:",
        "Watched it with my parents and we talked about it for an hour after. That's rare.",
        "Some scenes run long, but the payoff makes every minute count in the end.",
        "The production design deserves every award. Every frame looks like a painting.",
        "I laughed way more than I expected to. The dialogue is sharp and never tries too hard.",
    ]

    private static let spoilerShouts = [
        "I can't believe they let the one character holding everything together walk away at the end. The final scene broke me.",
        "So the whole first act was a dream all along? I need to watch it again knowing that.",
    ]

    private static let review = """
    {title} is the kind of story that trusts its audience, and that trust is the whole point. It starts small, almost too small, with \
    a handful of people in a handful of rooms, and it takes its time letting you learn who they are. By the time the first real turn \
    arrives, you're not watching a plot unfold so much as watching people you know make choices you can't stop them from making.

    The performances are the heart of it. Nobody shouts, nobody explains their feelings, and yet every glance lands. There's a dinner \
    scene about halfway through that does more character work in four minutes than most films manage in two hours.

    It isn't flawless. The middle stretch loses a little momentum, and one subplot feels like it belonged to a different, louder \
    film. A tighter edit would have helped. But those are small complaints against how confidently it handles its ending, which \
    manages to be surprising and inevitable at the same time.

    Visually it's a treat: warm, grainy, patient framing that lets scenes breathe. The score is used sparingly, which makes the \
    moments it swells feel earned rather than manipulative.

    If you liked slow, character-first stories, this is an easy recommendation. If you need constant momentum, give it twenty \
    minutes before deciding. I'll be thinking about it for a while, and I'm already planning a rewatch with friends.
    """

    private static let replies = [
        "Completely agree, the ending got me too.",
        "Hard disagree on the pacing, I thought it was just right.",
        "Same here! Watched it twice in one week.",
        "This is exactly why I keep coming back to it.",
        "Good call on the sound, it really is something on a proper system.",
        "You put into words what I couldn't. Great take.",
    ]

    private static let goodAspects = [
        "Stunning cinematography", "Powerful performances", "Memorable score", "Clever writing", "Emotional ending",
        "Great chemistry", "Sharp humor", "Rewatchable", "Immersive sound",
    ]

    private static let badAspects = ["Slow middle act", "Predictable twist", "Runs too long", "Underused side characters", "Uneven tone", "Rushed ending"]

    /// The Trakt id the stand-in gives a subject path (`movies/12`, `shows/40`, `shows/40/seasons/1/episodes/3`), and the
    /// catalogue title it is.
    func communitySubject(_ parts: [String]) -> (id: Int, item: DemoItem)? {
        if parts.count >= 2, parts[0] == "movies" || (parts[0] == "shows" && parts.count < 6), let id = Int(parts[1]), let item = items[parts[1]] {
            return (id, item)
        }
        if parts.count >= 6, parts[0] == "shows", parts[2] == "seasons", parts[4] == "episodes",
           let key = traktEpisodeKey(show: parts[1], season: Int(parts[3]) ?? 0, number: Int(parts[5]) ?? 0),
           let item = items[key], let id = Int(key) {
            return (id, item)
        }
        return nil
    }

    private func commentCount(for id: Int, item: DemoItem) -> Int {
        var random = DemoRandom(UInt64(id), 41)
        return item.kind == .episode ? random.int(3...7) : random.int(14...24)
    }

    private static func commentID(subject: Int, index: Int) -> Int { 1_000_000 + subject * 40 + index }

    private static func replyID(parent: Int, index: Int) -> Int { 50_000_000 + (parent - 1_000_000) * 8 + index }

    /// A generated comment of `subject`, with `index` choosing its author, words, age and counts.
    private func generatedComment(subject id: Int, item: DemoItem, index: Int) -> DemoJSON? {
        let commentID = Self.commentID(subject: id, index: index)
        guard !traktCommunity.deleted.contains(commentID) else { return nil }
        var random = DemoRandom(UInt64(id), UInt64(index), 7)
        let member = Self.communityMembers[(id + index * 5) % Self.communityMembers.count]
        let title = item.kind == .episode ? (item.show.flatMap { items[$0]?.title } ?? item.title) : item.title
        let isReview = index == 1 && item.kind != .episode
        let isSpoiler = index == 4 || (index == 9 && item.kind != .episode)
        let text: String
        if isReview {
            text = Self.review
        } else if isSpoiler {
            text = Self.spoilerShouts[(id + index) % Self.spoilerShouts.count]
        } else {
            text = Self.shouts[(id * 3 + index * 7) % Self.shouts.count]
        }
        let likes = max(0, 220 / (index + 1) - random.int(0...12)) + (traktCommunity.likes[commentID] == nil ? 0 : 1)
        let created = Date(timeIntervalSince1970: TimeInterval(now)).addingTimeInterval(-Double(index * 9 + random.int(1...8)) * 86_400 - Double(random.int(0...80_000)))
        let audience = item.fields.double("audienceRating") ?? item.show.flatMap { items[$0]?.fields.double("audienceRating") } ?? 7.5
        let rating = max(1, min(10, Int(audience.rounded()) + random.int(-3...2)))
        return comment(
            id: commentID, parent: 0, text: text.replacingOccurrences(of: "{title}", with: title), spoiler: isSpoiler, review: isReview,
            replies: replyCount(for: commentID, seed: index), likes: likes, created: created, rating: rating, plays: random.int(1...4), user: member.json
        )
    }

    private func replyCount(for commentID: Int, seed: Int) -> Int {
        let generated = seed < 6 ? (6 - seed) % 4 : 0
        let removed = (0..<generated).filter { traktCommunity.deleted.contains(Self.replyID(parent: commentID, index: $0)) }.count
        return generated - removed + traktCommunity.posted.values.filter { $0.int("parent_id") == commentID }.count
    }

    private func comment(id: Int, parent: Int, text: String, spoiler: Bool, review: Bool, replies: Int, likes: Int, created: Date, rating: Int?, plays: Int, user: DemoJSON) -> DemoJSON {
        var json: DemoJSON = [
            "id": id, "parent_id": parent, "created_at": iso(created), "updated_at": iso(created), "comment": text, "spoiler": spoiler,
            "review": review, "replies": replies, "likes": likes, "language": "en",
            "user_stats": ["play_count": plays, "completed_count": plays] as DemoJSON, "user": user,
        ]
        if let rating {
            json["user_rating"] = rating
            json["user_stats"] = ["rating": rating, "play_count": plays, "completed_count": plays] as DemoJSON
        }
        if let edit = traktCommunity.edits[id] {
            json["comment"] = edit.text
            json["spoiler"] = edit.spoiler
            json["updated_at"] = iso(edit.at)
            json["review"] = edit.text.split(whereSeparator: \.isWhitespace).count >= 200
        }
        return json
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Every comment of a subject: the viewer's own first among equals, then the generated ones.
    private func allComments(subject id: Int, item: DemoItem) -> [DemoJSON] {
        let own = traktCommunity.posted.filter { traktCommunity.postedSubject[$0.key] == "\(id)" && $0.value.int("parent_id") == 0 }
            .map { refreshed($0.value) }
        let generated = (0..<commentCount(for: id, item: item)).compactMap { generatedComment(subject: id, item: item, index: $0) }
        return (own + generated).filter { !traktCommunity.blocks.contains(username(of: $0)) }
    }

    private func refreshed(_ comment: DemoJSON) -> DemoJSON {
        guard let id = comment.int("id") else { return comment }
        var json = comment
        json["replies"] = traktCommunity.posted.values.filter { $0.int("parent_id") == id }.count
        if let edit = traktCommunity.edits[id] {
            json["comment"] = edit.text
            json["spoiler"] = edit.spoiler
            json["updated_at"] = iso(edit.at)
            json["review"] = Self.wordCount(edit.text) >= 200
        }
        return json
    }

    private func username(of comment: DemoJSON) -> String {
        (comment["user"] as? DemoJSON)?.string("username") ?? ""
    }

    func traktComments(_ parts: [String], sort: String, page: Int, limit: Int) -> DemoResponse {
        guard let subject = communitySubject(parts) else { return .notFound() }
        var comments = allComments(subject: subject.id, item: subject.item)
        func date(_ json: DemoJSON) -> String { json.string("created_at") ?? "" }
        switch sort {
        case "newest": comments.sort { date($0) > date($1) }
        case "oldest": comments.sort { date($0) < date($1) }
        case "replies": comments.sort { ($0.int("replies") ?? 0) > ($1.int("replies") ?? 0) }
        case "highest": comments.sort { ($0.int("user_rating") ?? 0) > ($1.int("user_rating") ?? 0) }
        case "lowest": comments.sort { ($0.int("user_rating") ?? 11) < ($1.int("user_rating") ?? 11) }
        case "plays": comments.sort { ((($0["user_stats"] as? DemoJSON)?.int("play_count")) ?? 0) > ((($1["user_stats"] as? DemoJSON)?.int("play_count")) ?? 0) }
        default: comments.sort { ($0.int("likes") ?? 0) > ($1.int("likes") ?? 0) }
        }
        return paged(comments, page: page, limit: limit)
    }

    private func paged(_ all: [DemoJSON], page: Int, limit: Int) -> DemoResponse {
        let size = max(1, limit)
        let pages = max(1, Int((Double(all.count) / Double(size)).rounded(.up)))
        let start = min(all.count, (max(page, 1) - 1) * size)
        let slice = Array(all[start..<min(all.count, start + size)])
        var response = DemoResponse.json(slice)
        response.headers["X-Pagination-Page"] = String(page)
        response.headers["X-Pagination-Limit"] = String(size)
        response.headers["X-Pagination-Page-Count"] = String(pages)
        response.headers["X-Pagination-Item-Count"] = String(all.count)
        return response
    }

    /// The generated or posted comment with `id`.
    private func findComment(_ id: Int) -> DemoJSON? {
        if traktCommunity.deleted.contains(id) { return nil }
        if let posted = traktCommunity.posted[id] { return refreshed(posted) }
        if id >= 50_000_000 {
            let parent = (id - 50_000_000) / 8 + 1_000_000
            return generatedReplies(to: parent).first { $0.int("id") == id }
        }
        guard id >= 1_000_000 else { return nil }
        let subject = (id - 1_000_000) / 40
        let index = (id - 1_000_000) % 40
        guard let item = items[String(subject)] else { return nil }
        return generatedComment(subject: subject, item: item, index: index)
    }

    private func generatedReplies(to parent: Int) -> [DemoJSON] {
        guard parent >= 1_000_000, parent < 50_000_000 else { return [] }
        let index = (parent - 1_000_000) % 40
        let count = index < 6 ? (6 - index) % 4 : 0
        return (0..<count).compactMap { reply in
            let id = Self.replyID(parent: parent, index: reply)
            guard !traktCommunity.deleted.contains(id) else { return nil }
            var random = DemoRandom(UInt64(parent), UInt64(reply), 13)
            let member = Self.communityMembers[(parent + reply * 3 + 2) % Self.communityMembers.count]
            let parentCreated = findComment(parent).flatMap { TraktDate.parse($0.string("created_at")) } ?? Date(timeIntervalSince1970: TimeInterval(now - 86_400 * 3))
            let latest = Date(timeIntervalSince1970: TimeInterval(now))
            let created = min(latest, parentCreated.addingTimeInterval(Double(reply + 1) * Double(random.int(2...20)) * 3_600))
            return comment(
                id: id, parent: parent, text: Self.replies[(parent + reply) % Self.replies.count], spoiler: false, review: false, replies: 0,
                likes: random.int(0...24) + (traktCommunity.likes[id] == nil ? 0 : 1), created: created, rating: nil, plays: random.int(1...2), user: member.json
            )
        }
    }

    func traktComment(_ id: Int) -> DemoResponse {
        guard let comment = findComment(id) else { return .notFound() }
        return .json(comment)
    }

    func traktReplies(_ id: Int, page: Int, limit: Int) -> DemoResponse {
        let own = traktCommunity.posted.values.filter { $0.int("parent_id") == id }.map(refreshed)
        let all = (generatedReplies(to: id) + own)
            .filter { !traktCommunity.blocks.contains(username(of: $0)) }
            .sorted { ($0.string("created_at") ?? "") < ($1.string("created_at") ?? "") }
        return paged(all, page: page, limit: limit)
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }

    /// Posts the viewer's comment on the subject the body names, refusing one under five words as Trakt does.
    func traktPostComment(_ body: Data) -> DemoResponse {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? DemoJSON, let text = json.string("comment") else { return .empty(400) }
        guard Self.wordCount(text) >= 5 else { return .json(["comment": ["must be at least 5 words"]] as DemoJSON, status: 422) }
        let key = ["movie", "show", "episode", "season"].first { json[$0] != nil }
        guard let key, let subject = ((json[key] as? DemoJSON)?["ids"] as? DemoJSON)?.int("trakt") else { return .empty(400) }
        traktCommunity.nextID += 1
        let id = traktCommunity.nextID
        let posted = comment(
            id: id, parent: 0, text: text, spoiler: (json["spoiler"] as? Bool) ?? false, review: Self.wordCount(text) >= 200, replies: 0,
            likes: 0, created: Date(), rating: nil, plays: 1, user: Self.demoViewer
        )
        traktCommunity.posted[id] = posted
        traktCommunity.postedSubject[id] = String(subject)
        return .json(posted, status: 201)
    }

    func traktPostReply(to parent: Int, _ body: Data) -> DemoResponse {
        guard findComment(parent) != nil else { return .notFound() }
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? DemoJSON, let text = json.string("comment") else { return .empty(400) }
        guard Self.wordCount(text) >= 5 else { return .json(["comment": ["must be at least 5 words"]] as DemoJSON, status: 422) }
        traktCommunity.nextID += 1
        let id = traktCommunity.nextID
        let posted = comment(
            id: id, parent: parent, text: text, spoiler: (json["spoiler"] as? Bool) ?? false, review: false, replies: 0,
            likes: 0, created: Date(), rating: nil, plays: 1, user: Self.demoViewer
        )
        traktCommunity.posted[id] = posted
        return .json(posted, status: 201)
    }

    func traktEditComment(_ id: Int, _ body: Data) -> DemoResponse {
        guard traktCommunity.posted[id] != nil else { return .empty(401) }
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? DemoJSON, let text = json.string("comment") else { return .empty(400) }
        guard Self.wordCount(text) >= 5 else { return .json(["comment": ["must be at least 5 words"]] as DemoJSON, status: 422) }
        traktCommunity.edits[id] = (text, (json["spoiler"] as? Bool) ?? false, Date().addingTimeInterval(120))
        return findComment(id).map { .json($0) } ?? .notFound()
    }

    func traktDeleteComment(_ id: Int) -> DemoResponse {
        guard traktCommunity.posted[id] != nil else { return .empty(401) }
        traktCommunity.posted[id] = nil
        traktCommunity.postedSubject[id] = nil
        traktCommunity.deleted.insert(id)
        return .empty(204)
    }

    func traktLike(_ id: Int, on: Bool) -> DemoResponse {
        guard findComment(id) != nil else { return .notFound() }
        if on {
            guard traktCommunity.likes[id] == nil else { return .empty(409) }
            traktCommunity.likes[id] = Date()
            if var posted = traktCommunity.posted[id] { posted["likes"] = (posted.int("likes") ?? 0) + 1; traktCommunity.posted[id] = posted }
        } else {
            guard traktCommunity.likes.removeValue(forKey: id) != nil else { return .empty(204) }
            if var posted = traktCommunity.posted[id] { posted["likes"] = max(0, (posted.int("likes") ?? 0) - 1); traktCommunity.posted[id] = posted }
        }
        return .empty(204)
    }

    private func generatedReactions(_ id: Int) -> [(reaction: String, member: DemoMember)] {
        guard traktCommunity.posted[id] == nil else { return [] }
        var random = DemoRandom(UInt64(id), 29)
        let kinds = ["like", "love", "laugh", "shocked", "bravo", "dislike", "spoiler"]
        let count = random.int(0...9)
        return (0..<count).map { index in
            let weights = [30, 22, 14, 8, 12, 5, 3]
            let kind = kinds[random.weightedIndex(weights)]
            return (kind, Self.communityMembers[(id + index * 7) % Self.communityMembers.count])
        }
    }

    func traktReactionSummary(_ id: Int) -> DemoResponse {
        guard findComment(id) != nil else { return .notFound() }
        var counts: [String: Int] = [:]
        var users = Set<String>()
        for entry in generatedReactions(id) {
            counts[entry.reaction, default: 0] += 1
            users.insert(entry.member.username)
        }
        for reaction in (traktCommunity.reactions[id] ?? [:]).keys { counts[reaction, default: 0] += 1 }
        if !(traktCommunity.reactions[id] ?? [:]).isEmpty { users.insert("demo") }
        return .json(["reaction_count": counts.values.reduce(0, +), "user_count": users.count, "distribution": counts] as DemoJSON)
    }

    func traktReactions(_ id: Int) -> DemoResponse {
        guard findComment(id) != nil else { return .notFound() }
        let base = Date(timeIntervalSince1970: TimeInterval(now))
        var entries: [DemoJSON] = generatedReactions(id).enumerated().map { index, entry in
            ["reacted_at": iso(base.addingTimeInterval(-Double(index + 1) * 5_400)), "reaction": ["type": entry.reaction] as DemoJSON, "user": entry.member.json]
        }
        for (reaction, at) in traktCommunity.reactions[id] ?? [:] {
            entries.insert(["reacted_at": iso(at), "reaction": ["type": reaction] as DemoJSON, "user": Self.demoViewer], at: 0)
        }
        return paged(entries, page: 1, limit: 100)
    }

    func traktReact(_ id: Int, _ reaction: String, on: Bool) -> DemoResponse {
        guard findComment(id) != nil else { return .notFound() }
        if on {
            guard traktCommunity.reactions[id]?[reaction] == nil else { return .empty(409) }
            traktCommunity.reactions[id, default: [:]][reaction] = Date()
        } else {
            traktCommunity.reactions[id]?[reaction] = nil
        }
        return .empty(204)
    }

    func traktSentiments(_ parts: [String]) -> DemoResponse {
        guard let subject = communitySubject(parts), subject.item.kind != .episode else { return .notFound() }
        var random = DemoRandom(UInt64(subject.id), 3)
        let ids = (0..<commentCount(for: subject.id, item: subject.item)).map { Self.commentID(subject: subject.id, index: $0) }
        func aspects(_ pool: [String], count: Int) -> [DemoJSON] {
            var chosen: [String] = []
            while chosen.count < count {
                let next = pool[random.int(0...(pool.count - 1))]
                if !chosen.contains(next) { chosen.append(next) }
            }
            return chosen.map { aspect in
                ["sentiment": aspect, "comment_ids": (0..<random.int(2...4)).map { _ in ids[random.int(0...(ids.count - 1))] }] as DemoJSON
            }
        }
        return .json([
            "good": aspects(Self.goodAspects, count: random.int(3...5)),
            "bad": aspects(Self.badAspects, count: random.int(2...3)),
            "analyzed_at": iso(Date(timeIntervalSince1970: TimeInterval(now - 86_400 * 3))),
            "comment_count": ids.count,
        ] as DemoJSON)
    }

    func traktStats(_ parts: [String]) -> DemoResponse {
        guard let subject = communitySubject(parts) else { return .notFound() }
        var random = DemoRandom(UInt64(subject.id), 17)
        let scale = subject.item.kind == .episode ? 0.18 : 1
        let watchers = Int(Double(random.int(4_000...60_000)) * scale)
        let comments = allComments(subject: subject.id, item: subject.item).count
        return .json([
            "watchers": watchers, "plays": Int(Double(watchers) * (1.2 + random.unit())), "collectors": watchers / 3,
            "comments": comments, "lists": Int(Double(watchers) * 0.21), "votes": watchers / 2,
            "favorited": watchers / 40, "recommended": watchers / 60,
        ] as DemoJSON)
    }

    func traktWatching(_ parts: [String]) -> DemoResponse {
        guard let subject = communitySubject(parts) else { return .notFound() }
        var random = DemoRandom(UInt64(subject.id), 23)
        let wanted = subject.item.kind == .episode ? random.int(0...2) : random.int(2...7)
        let members = Self.communityMembers.filter { !$0.isPrivate && !traktCommunity.blocks.contains($0.username) }
        guard !members.isEmpty else { return .json([] as [Any]) }
        let start = random.int(0...(members.count - 1))
        return .json((0..<min(wanted, members.count)).map { members[(start + $0) % members.count].json })
    }

    private func member(_ handle: String) -> DemoMember? {
        Self.communityMembers.first { $0.username == handle }
    }

    func traktProfile(_ handle: String) -> DemoResponse {
        if handle == "me" || handle == "demo" { return .json(Self.demoViewer) }
        guard let member = member(handle) else { return .notFound() }
        return .json(member.json)
    }

    func traktUserWatching(_ handle: String) -> DemoResponse {
        guard let member = member(handle), !member.isPrivate else { return .empty(204) }
        let index = Self.communityMembers.firstIndex { $0.username == handle } ?? 0
        guard index % 3 != 2, !movieKeys.isEmpty else { return .empty(204) }
        let movie = items[movieKeys[(index * 5) % movieKeys.count]]
        guard let movie else { return .empty(204) }
        return .json([
            "expires_at": iso(Date().addingTimeInterval(3_600)), "started_at": iso(Date().addingTimeInterval(-1_800)),
            "action": "scrobble", "type": "movie",
            "movie": ["title": movie.title, "year": movie.fields.int("year") ?? 0, "ids": traktIDs(movie)] as DemoJSON,
        ] as DemoJSON)
    }

    func traktUserComments(_ handle: String, page: Int, limit: Int) -> DemoResponse {
        guard let member = member(handle) else { return .json([] as [Any]) }
        guard !member.isPrivate else { return .empty(401) }
        var entries: [DemoJSON] = []
        for key in Array(movieKeys.prefix(16)) + Array(showKeys.prefix(8)) {
            guard let item = items[key], let id = Int(key) else { continue }
            for comment in allComments(subject: id, item: item) where username(of: comment) == handle {
                let kind = item.kind == .show ? "show" : "movie"
                entries.append(["type": kind, "comment": comment, kind: ["title": item.title, "year": item.fields.int("year") ?? 0, "ids": traktIDs(item)] as DemoJSON])
            }
        }
        entries.sort { (($0["comment"] as? DemoJSON)?.string("created_at") ?? "") > (($1["comment"] as? DemoJSON)?.string("created_at") ?? "") }
        return paged(entries, page: page, limit: limit)
    }

    func traktFollow(_ handle: String, on: Bool) -> DemoResponse {
        guard let member = member(handle) else { return .notFound() }
        if on {
            guard traktCommunity.follows[handle] == nil else { return .empty(409) }
            traktCommunity.follows[handle] = Date()
            var result: DemoJSON = ["user": member.json]
            result["approved_at"] = member.isPrivate ? NSNull() as Any : iso(Date()) as Any
            return .json(result, status: 201)
        }
        traktCommunity.follows[handle] = nil
        return .empty(204)
    }

    func traktBlock(_ handle: String, on: Bool) -> DemoResponse {
        guard member(handle) != nil else { return .notFound() }
        if on {
            guard !traktCommunity.blocks.contains(handle) else { return .empty(409) }
            traktCommunity.blocks.insert(handle)
            traktCommunity.follows[handle] = nil
            return .empty(201)
        }
        traktCommunity.blocks.remove(handle)
        return .empty(204)
    }

    /// Who the viewer follows: a private member stays a request, waiting for an approval the demo never gives.
    func traktFollowing() -> DemoResponse {
        .json(traktCommunity.follows.compactMap { handle, at in
            member(handle).flatMap { $0.isPrivate ? nil : ["followed_at": iso(at), "user": $0.json] as DemoJSON }
        })
    }

    func traktBlocked() -> DemoResponse {
        .json(traktCommunity.blocks.compactMap { handle in
            member(handle).map { ["blocked_at": iso(Date(timeIntervalSince1970: TimeInterval(now))), "user": $0.json] as DemoJSON }
        })
    }

    func traktLikedComments() -> DemoResponse {
        .json(traktCommunity.likes.map { id, at in ["liked_at": iso(at), "type": "comment", "comment": ["id": id] as DemoJSON] as DemoJSON })
    }

    func traktReactedComments() -> DemoResponse {
        var entries: [DemoJSON] = []
        for (id, reactions) in traktCommunity.reactions {
            for (reaction, at) in reactions {
                entries.append(["reacted_at": iso(at), "reaction": ["type": reaction] as DemoJSON, "type": "comment", "comment": ["id": id] as DemoJSON])
            }
        }
        return .json(entries)
    }

    /// Trakt's own spread of votes for a title rated `audience` out of ten: a bell around the score, steady per title.
    static func traktDistribution(audience: Double, votes: Int, seed: Int) -> DemoJSON {
        var random = DemoRandom(UInt64(seed), 31)
        var weights: [Double] = (1...10).map { score in
            let distance = Double(score) - audience
            return exp(-(distance * distance) / 3.2) + random.unit() * 0.04
        }
        let total = weights.reduce(0, +)
        weights = weights.map { $0 / total }
        var distribution: DemoJSON = [:]
        for (index, weight) in weights.enumerated() { distribution[String(index + 1)] = Int(Double(votes) * weight) }
        return distribution
    }
}

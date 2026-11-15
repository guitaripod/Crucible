import Foundation

extension DemoRouter {
    /// Whether a request is for the stand-in Trakt, which every Trakt request announces with its API key header.
    static func isTrakt(_ request: DemoRequest) -> Bool {
        request.headers["trakt-api-key"] != nil
    }

    func traktResponse(_ parts: [String], _ request: DemoRequest) async -> DemoResponse {
        switch (request.method, parts) {
        case ("POST", ["oauth", "device", "code"]):
            return .json([
                "device_code": "demo-device", "user_code": "CRUC1BLE", "verification_url": "https://auth.trakt.tv/activate",
                "expires_in": 600, "interval": 1,
            ] as DemoJSON)
        case ("POST", ["oauth", "device", "token"]):
            return await library.traktDevicePoll()
        case ("POST", ["oauth", "token"]):
            return .json([
                "access_token": "demo-trakt", "refresh_token": "demo-trakt-refresh", "token_type": "bearer",
                "expires_in": 7 * 86_400, "scope": "public", "created_at": Int(Date().timeIntervalSince1970),
            ] as DemoJSON)
        case ("POST", ["oauth", "revoke"]):
            return .empty()
        case ("GET", ["users", "settings"]):
            return .json([
                "user": ["username": "demo", "name": "Demo Viewer", "vip": false, "private": false, "images": ["avatar": ["full": ""]]] as DemoJSON,
                "limits": ["watchlist": ["item_count": 250]] as DemoJSON,
            ] as DemoJSON)
        case ("GET", ["users", "settings", "plex"]):
            return .json(["connection": ["connected": false]] as DemoJSON)
        case ("PUT", ["users", "settings", "plex"]):
            return .empty(201)
        case ("GET", let path) where path.count == 3 && path[0] == "search":
            return await library.traktSearch(idType: path[1], id: path[2], kind: request.first("type") ?? "movie")
        case ("GET", let path) where path.count == 6 && path[0] == "shows" && path[2] == "seasons" && path[4] == "episodes":
            return await library.traktEpisode(show: path[1], season: Int(path[3]) ?? 0, number: Int(path[5]) ?? 0)
        case ("GET", let path) where path.count == 3 && (path[0] == "movies" || path[0] == "shows") && path[2] == "ratings":
            return await library.traktRatings(path[1])
        case ("GET", let path) where path.count == 7 && path[0] == "shows" && path[6] == "ratings":
            guard let episode = await library.traktEpisodeKey(show: path[1], season: Int(path[3]) ?? 0, number: Int(path[5]) ?? 0) else { return .notFound() }
            return await library.traktRatings(episode)
        case ("POST", let path) where path.first == "scrobble" && path.count == 2:
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? DemoJSON
            let progress = body?.double("progress") ?? 0
            let action = path[1] == "stop" && progress >= 80 ? "scrobble" : path[1]
            return .json(["id": 1, "action": action, "progress": progress] as DemoJSON, status: 201)
        case ("GET", ["sync", "history"]):
            return request.first("page").flatMap(Int.init).map { $0 > 1 } == true ? .json([] as [Any]) : await library.traktHistory()
        case ("POST", ["sync", "history"]), ("POST", ["sync", "ratings"]):
            return .json(["added": ["movies": 1, "episodes": 0] as DemoJSON, "not_found": [:] as DemoJSON] as DemoJSON, status: 201)
        case ("POST", ["sync", "history", "remove"]), ("POST", ["sync", "ratings", "remove"]):
            return .json(["deleted": ["movies": 1] as DemoJSON] as DemoJSON)
        case ("POST", ["checkin"]):
            return .json(["id": 1, "watched_at": ISO8601DateFormatter().string(from: Date())] as DemoJSON, status: 201)
        case ("DELETE", ["checkin"]):
            return .empty(204)
        default:
            return await communityResponse(parts, request)
        }
    }

    /// The stand-in Trakt's community: comments and their replies, likes and reactions, what people say, who is watching, and
    /// members' profiles, follows and blocks.
    private func communityResponse(_ parts: [String], _ request: DemoRequest) async -> DemoResponse {
        let page = request.int("page") ?? 1
        let limit = request.int("limit") ?? 10
        switch (request.method, parts) {
        case ("POST", ["comments"]):
            return await library.traktPostComment(request.body)
        case ("GET", ["users", "me", "following"]):
            return await library.traktFollowing()
        case ("GET", ["users", "blocked"]):
            return await library.traktBlocked()
        case ("GET", ["users", "likes", "comments"]):
            return await library.traktLikedComments()
        case ("GET", ["users", "reactions", "comments"]):
            return await library.traktReactedComments()
        default:
            break
        }
        if parts.first == "comments", parts.count >= 2, let id = Int(parts[1]) {
            switch (request.method, Array(parts.dropFirst(2))) {
            case ("GET", []): return await library.traktComment(id)
            case ("PUT", []): return await library.traktEditComment(id, request.body)
            case ("DELETE", []): return await library.traktDeleteComment(id)
            case ("GET", ["replies"]): return await library.traktReplies(id, page: page, limit: limit)
            case ("POST", ["replies"]): return await library.traktPostReply(to: id, request.body)
            case ("POST", ["like"]): return await library.traktLike(id, on: true)
            case ("DELETE", ["like"]): return await library.traktLike(id, on: false)
            case ("GET", ["reactions", "summary"]): return await library.traktReactionSummary(id)
            case ("GET", ["reactions"]): return await library.traktReactions(id)
            case ("POST", let rest) where rest.count == 2 && rest[0] == "reactions": return await library.traktReact(id, rest[1], on: true)
            case ("DELETE", let rest) where rest.count == 2 && rest[0] == "reactions": return await library.traktReact(id, rest[1], on: false)
            case ("POST", ["report"]): return .empty(201)
            default: return .notFound()
            }
        }
        if parts.first == "users", parts.count >= 2 {
            let handle = parts[1]
            switch (request.method, Array(parts.dropFirst(2))) {
            case ("GET", []): return await library.traktProfile(handle)
            case ("GET", ["watching"]): return await library.traktUserWatching(handle)
            case ("GET", let rest) where rest.count == 3 && rest[0] == "comments": return await library.traktUserComments(handle, page: page, limit: limit)
            case ("POST", ["follow"]): return await library.traktFollow(handle, on: true)
            case ("DELETE", ["follow"]): return await library.traktFollow(handle, on: false)
            case ("POST", ["block"]): return await library.traktBlock(handle, on: true)
            case ("DELETE", ["block"]): return await library.traktBlock(handle, on: false)
            case ("POST", ["report"]): return .empty(201)
            default: return .notFound()
            }
        }
        guard request.method == "GET", parts.first == "movies" || parts.first == "shows", let last = parts.last else { return .notFound() }
        if parts.count >= 2, parts[parts.count - 2] == "comments" {
            return await library.traktComments(Array(parts.dropLast(2)), sort: last, page: page, limit: limit)
        }
        switch last {
        case "sentiments": return await library.traktSentiments(Array(parts.dropLast()))
        case "stats": return await library.traktStats(Array(parts.dropLast()))
        case "watching": return await library.traktWatching(Array(parts.dropLast()))
        default: return .notFound()
        }
    }
}

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
            return .notFound()
        }
    }
}

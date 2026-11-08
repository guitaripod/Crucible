import Foundation

extension DemoRouter {
    /// The stand-in Seerr, which the demo serves under `/seerr` of the library's own address, as a Seerr behind a reverse
    /// proxy would be.
    func seerrResponse(_ parts: [String], _ request: DemoRequest) async -> DemoResponse {
        if parts.first == "imageproxy", parts.count > 5 {
            return await imageResponse(path: "/" + parts.dropFirst(5).joined(separator: "/"))
        }
        guard parts.count >= 3, parts[0] == "api", parts[1] == "v1" else { return .notFound() }
        let route = Array(parts.dropFirst(2))
        switch (request.method, route) {
        case ("GET", ["status"]):
            return .json(["version": "3.5.1", "commitTag": "demo"] as DemoJSON)
        case ("GET", ["settings", "public"]):
            return .json([
                "initialized": true, "applicationTitle": "\(serverName) Requests", "mediaServerType": 1, "mediaServerLogin": true, "partialRequestsEnabled": true,
            ] as DemoJSON)
        case ("POST", ["auth", "plex"]):
            return await library.seerrSignIn()
        case ("GET", ["auth", "me"]):
            return await library.seerrMe()
        case ("POST", ["auth", "logout"]):
            return .json(["status": "ok"] as DemoJSON)
        case ("GET", let path) where path.count == 2 && (path[0] == "movie" || path[0] == "tv"):
            return await library.seerrDetails(kind: path[0], tmdbID: Int(path[1]) ?? 0)
        case ("GET", ["request"]):
            return await library.seerrRequestList(filter: request.first("filter") ?? "all", requestedBy: request.int("requestedBy"))
        case ("POST", ["request"]):
            return await library.seerrCreateRequest(request.body)
        case ("DELETE", let path) where path.count == 2 && path[0] == "request":
            return await library.seerrDeleteRequest(Int(path[1]) ?? 0)
        case ("POST", let path) where path.count == 3 && path[0] == "request" && (path[2] == "approve" || path[2] == "decline"):
            return await library.seerrModerate(Int(path[1]) ?? 0, approve: path[2] == "approve")
        case ("GET", let path) where path.count == 3 && path[0] == "user" && path[2] == "quota":
            return .json(["movie": ["restricted": false] as DemoJSON, "tv": ["restricted": false] as DemoJSON] as DemoJSON)
        default:
            return .notFound()
        }
    }
}

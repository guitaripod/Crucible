import Foundation

/// One request the demo's stand-in Seerr keeps.
struct DemoSeerrRequest: Sendable {
    let id: Int
    let tmdbID: Int
    let kind: String
    var status: Int
    let seasons: [Int]
    let userID: Int
    let createdAt: Date
    /// How far its download is, from 0 to 1, while one runs.
    var downloaded: Double?
}

/// The demo's stand-in for Seerr: every catalogue movie and show is known to it under a TMDB id made from its rating key,
/// each show has one season more than the server holds, and a few titles exist only here, so requesting, its states and
/// approving all work without a Seerr.
extension DemoLibrary {
    private struct RemoteTitle {
        let tmdbID: Int
        let kind: String
        let title: String
        let year: Int
        let seasons: Int
        let posterOf: String
        let discoverKey: String?
    }

    private static let remoteTitles: [RemoteTitle] = [
        RemoteTitle(tmdbID: 980_001, kind: "movie", title: "Night Train to Nowhere", year: 2024, seasons: 0, posterOf: "1010", discoverKey: "demo-night-train"),
        RemoteTitle(tmdbID: 980_002, kind: "tv", title: "Glass Orchard", year: 2023, seasons: 3, posterOf: "2005", discoverKey: "demo-glass-orchard"),
        RemoteTitle(tmdbID: 980_003, kind: "movie", title: "Lowland Choir", year: 2025, seasons: 0, posterOf: "1018", discoverKey: nil),
        RemoteTitle(tmdbID: 980_004, kind: "tv", title: "The Long Signal", year: 2022, seasons: 2, posterOf: "2007", discoverKey: nil),
    ]

    static let seerrOwnerID = 1
    static let seerrSamID = 2

    static func initialSeerrRequests(now: Date) -> [DemoSeerrRequest] {
        [
            DemoSeerrRequest(id: 11, tmdbID: 980_003, kind: "movie", status: 1, seasons: [], userID: seerrSamID, createdAt: now.addingTimeInterval(-3 * 3_600)),
            DemoSeerrRequest(id: 12, tmdbID: demoTMDB("1003"), kind: "movie", status: 5, seasons: [], userID: seerrOwnerID, createdAt: now.addingTimeInterval(-9 * 86_400)),
            DemoSeerrRequest(id: 13, tmdbID: 980_004, kind: "tv", status: 2, seasons: [1, 2], userID: seerrOwnerID, createdAt: now.addingTimeInterval(-26 * 3_600), downloaded: 0.62),
        ]
    }

    /// The TMDB id the demo gives a catalogue title.
    static func demoTMDB(_ key: String) -> Int { 900_000 + (Int(key) ?? 0) }

    /// The catalogue title with `tmdbID`: one that carries the id itself, or the one the demo made it for.
    func seerrItem(tmdbID: Int) -> DemoItem? {
        let guid = "tmdb://\(tmdbID)"
        if let own = items.values.first(where: { ($0.fields["Guid"] as? [DemoJSON])?.contains { $0.string("id") == guid } == true }) { return own }
        return items[String(tmdbID - 900_000)]
    }

    private var seerrUserID: Int { viewer.isAdmin ? Self.seerrOwnerID : Self.seerrSamID }

    private func seerrUser(_ id: Int) -> DemoJSON {
        id == Self.seerrOwnerID
            ? ["id": id, "displayName": "Demo Viewer", "plexUsername": "demo", "permissions": 2, "requestCount": 2]
            : ["id": id, "displayName": "Sam", "plexUsername": "sam", "permissions": 32, "requestCount": 1]
    }

    func seerrMe() -> DemoResponse {
        .json(seerrUser(seerrUserID))
    }

    func seerrSignIn() -> DemoResponse {
        var response = DemoResponse.json(seerrUser(seerrUserID))
        response.headers["Set-Cookie"] = "connect.sid=demo-seerr-\(seerrUserID); Path=/; HttpOnly"
        return response
    }

    /// The catalogue entry plex.tv keeps for a watchlist title the server does not have, with its TMDB id.
    func catalogEntry(_ discoverKey: String) -> DemoResponse? {
        guard let remote = Self.remoteTitles.first(where: { $0.discoverKey == discoverKey }) else { return nil }
        let metadata: DemoJSON = [
            "ratingKey": discoverKey, "guid": "plex://\(remote.kind == "tv" ? "show" : "movie")/\(discoverKey)",
            "type": remote.kind == "tv" ? "show" : "movie", "title": remote.title, "year": remote.year,
            "Guid": [["id": "tmdb://\(remote.tmdbID)"] as DemoJSON],
        ]
        return .container(["size": 1, "Metadata": [metadata]])
    }

    /// A title as Seerr describes it, with what the stand-in knows of it, or nil for an id it does not know.
    func seerrDetails(kind: String, tmdbID: Int) -> DemoResponse {
        let requests = seerrRequests.filter { $0.tmdbID == tmdbID }
        if let remote = Self.remoteTitles.first(where: { $0.tmdbID == tmdbID && $0.kind == kind }) {
            var details: DemoJSON = [
                "id": tmdbID, "overview": "A title this server does not have yet.",
                "posterPath": items[remote.posterOf]?.fields.string("thumb") ?? "",
            ]
            details[kind == "tv" ? "name" : "title"] = remote.title
            details[kind == "tv" ? "firstAirDate" : "releaseDate"] = "\(remote.year)-03-14"
            if kind == "tv" { details["seasons"] = Self.seasons(remote.seasons) }
            if !requests.isEmpty { details["mediaInfo"] = mediaInfo(tmdbID: tmdbID, kind: kind, requests: requests, ratingKey: nil, onServer: []) }
            return .json(details)
        }
        guard let item = seerrItem(tmdbID: tmdbID), (kind == "tv" ? item.kind == .show : item.kind == .movie) else { return .notFound() }
        let key = item.ratingKey
        var details: DemoJSON = [
            "id": tmdbID, "overview": item.fields.string("summary") ?? "", "posterPath": item.fields.string("thumb") ?? "",
        ]
        details[kind == "tv" ? "name" : "title"] = item.title
        details[kind == "tv" ? "firstAirDate" : "releaseDate"] = "\(item.fields.int("year") ?? 2020)-01-01"
        let held = kind == "tv" ? Array(1...max(1, item.fields.int("childCount") ?? 1)) : []
        if kind == "tv" { details["seasons"] = Self.seasons(held.count + 1) }
        details["mediaInfo"] = mediaInfo(tmdbID: tmdbID, kind: kind, requests: requests, ratingKey: key, onServer: held)
        return .json(details)
    }

    private static func seasons(_ count: Int) -> [DemoJSON] {
        guard count > 0 else { return [] }
        return (1...count).map { ["seasonNumber": $0, "name": "Season \($0)", "episodeCount": 8] as DemoJSON }
    }

    private func mediaInfo(tmdbID: Int, kind: String, requests: [DemoSeerrRequest], ratingKey: String?, onServer: [Int]) -> DemoJSON {
        let live = requests.filter { $0.status != 3 }
        var status = 1
        if ratingKey != nil { status = kind == "tv" ? 4 : 5 }
        if let request = live.max(by: { $0.id < $1.id }) {
            switch request.status {
            case 1: status = ratingKey == nil ? 2 : status
            case 2: status = ratingKey == nil ? 3 : status
            case 5: status = 5
            default: break
            }
        }
        var seasons: [DemoJSON] = onServer.map { ["seasonNumber": $0, "status": 5] as DemoJSON }
        for request in live where request.status == 2 {
            seasons += request.seasons.filter { !onServer.contains($0) }.map { ["seasonNumber": $0, "status": 3] as DemoJSON }
        }
        var info: DemoJSON = [
            "id": tmdbID, "tmdbId": tmdbID, "mediaType": kind, "status": status, "seasons": seasons,
            "requests": requests.map(requestJSON),
        ]
        if let ratingKey { info["ratingKey"] = ratingKey }
        if let downloading = live.first(where: { $0.downloaded != nil }), let done = downloading.downloaded {
            let eta = ISO8601DateFormatter().string(from: Date().addingTimeInterval((1 - done) * 150 * 60))
            info["downloadStatus"] = [["size": 4_000_000_000.0, "sizeLeft": 4_000_000_000.0 * (1 - done), "status": "downloading", "estimatedCompletionTime": eta, "title": "demo"] as DemoJSON]
        }
        return info
    }

    private func requestJSON(_ request: DemoSeerrRequest) -> DemoJSON {
        [
            "id": request.id, "status": request.status, "type": request.kind, "is4k": false,
            "createdAt": ISO8601DateFormatter().string(from: request.createdAt),
            "updatedAt": ISO8601DateFormatter().string(from: request.createdAt),
            "requestedBy": seerrUser(request.userID),
            "seasons": request.seasons.map { ["seasonNumber": $0, "status": request.status] as DemoJSON },
        ]
    }

    private func requestWithMedia(_ request: DemoSeerrRequest) -> DemoJSON {
        var json = requestJSON(request)
        let item = seerrItem(tmdbID: request.tmdbID)
        let ratingKey = item?.ratingKey
        let held = request.kind == "tv" && item != nil ? Array(1...max(1, item?.fields.int("childCount") ?? 1)) : []
        json["media"] = mediaInfo(tmdbID: request.tmdbID, kind: request.kind, requests: [request], ratingKey: ratingKey, onServer: held)
        return json
    }

    func seerrRequestList(filter: String, requestedBy: Int?) -> DemoResponse {
        var list = seerrRequests.sorted { $0.id > $1.id }
        if let requestedBy { list = list.filter { $0.userID == requestedBy } }
        if !viewer.isAdmin { list = list.filter { $0.userID == seerrUserID } }
        if filter == "pending" { list = list.filter { $0.status == 1 } }
        return .json(["pageInfo": ["pages": 1, "page": 1, "results": list.count] as DemoJSON, "results": list.map(requestWithMedia)] as DemoJSON)
    }

    /// Creates a request; the owner's are approved at once and start downloading, as an administrator's are.
    func seerrCreateRequest(_ body: Data) -> DemoResponse {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? DemoJSON,
              let kind = object.string("mediaType"), let tmdbID = object["mediaId"] as? Int else { return .json(["message": "Bad request"], status: 400) }
        if seerrRequests.contains(where: { $0.tmdbID == tmdbID && $0.kind == kind && $0.status != 3 && kind == "movie" }) {
            return .json(["message": "Request for this media already exists."], status: 409)
        }
        var seasons = object["seasons"] as? [Int] ?? []
        if kind == "tv", seasons.isEmpty {
            let remote = Self.remoteTitles.first { $0.tmdbID == tmdbID }
            let held = seerrItem(tmdbID: tmdbID)?.fields.int("childCount") ?? 0
            let total = remote?.seasons ?? held + 1
            let asked = Set(seerrRequests.filter { $0.tmdbID == tmdbID && $0.status != 3 }.flatMap(\.seasons))
            seasons = (1...max(1, total)).filter { $0 > held && !asked.contains($0) }
        }
        let request = DemoSeerrRequest(
            id: nextSeerrRequestID, tmdbID: tmdbID, kind: kind, status: viewer.isAdmin ? 2 : 1, seasons: seasons,
            userID: seerrUserID, createdAt: Date(), downloaded: viewer.isAdmin ? 0.35 : nil
        )
        nextSeerrRequestID += 1
        seerrRequests.append(request)
        return .json(requestWithMedia(request), status: 201)
    }

    func seerrDeleteRequest(_ id: Int) -> DemoResponse {
        guard let index = seerrRequests.firstIndex(where: { $0.id == id }) else { return .notFound() }
        guard viewer.isAdmin || (seerrRequests[index].userID == seerrUserID && seerrRequests[index].status == 1) else {
            return .json(["message": "You do not have permission"], status: 403)
        }
        seerrRequests.remove(at: index)
        return .empty(204)
    }

    func seerrModerate(_ id: Int, approve: Bool) -> DemoResponse {
        guard viewer.isAdmin else { return .json(["message": "You do not have permission"], status: 403) }
        guard let index = seerrRequests.firstIndex(where: { $0.id == id }) else { return .notFound() }
        guard seerrRequests[index].status == 1 else { return .json(["message": "Only pending requests can be approved or declined"], status: 409) }
        seerrRequests[index].status = approve ? 2 : 3
        if approve { seerrRequests[index].downloaded = 0.08 }
        return .json(requestWithMedia(seerrRequests[index]))
    }
}

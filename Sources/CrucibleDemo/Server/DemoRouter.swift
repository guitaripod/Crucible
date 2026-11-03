import Foundation

/// Maps every request the app makes to the library: the Plex Media Server routes, the plex.tv stand-in, the artwork and the media.
struct DemoRouter: Sendable {
    let library: DemoLibrary
    let plexTV: DemoPlexTV
    let assets: DemoAssets
    let serverName: String

    private static let imageCacheControl = "public, max-age=3600"

    func handle(_ request: DemoRequest) async -> DemoResponse {
        let parts = request.path.split(separator: "/").map(String.init)
        switch parts.first {
        case nil, "identity":
            return await library.identityResponse(serverName: serverName)
        case "api":
            return await plexTVResponse(parts, request)
        case ":":
            return await stateResponse(parts, request)
        case "library":
            return await libraryResponse(parts, request)
        case "playlists":
            return await playlistsResponse(parts, request)
        case "actions":
            return await watchlistAction(parts, request)
        case "hubs":
            return await hubsResponse(parts, request)
        case "status":
            if request.method == "DELETE", parts.count == 4, parts[1] == "sessions", parts[2] == "history" {
                return await library.deleteHistoryRow(parts[3])
            }
            switch parts {
            case ["status", "sessions", "history", "all"]: return await library.historyResponse(request)
            case ["status", "sessions"]: return await library.sessionsResponse()
            case ["status", "sessions", "terminate"]: return await library.terminateSession(request.first("sessionId"))
            default: return .notFound()
            }
        case "activities":
            if request.method == "DELETE", parts.count == 2 { return await library.cancelActivity(parts[1]) }
            return await library.activitiesResponse()
        case "updater":
            return parts.count == 2 && parts[1] == "status" ? DemoLibrary.updaterResponse() : .empty()
        case "statistics":
            return parts == ["statistics", "resources"] ? DemoLibrary.resourcesResponse() : .notFound()
        case "photo":
            return await photoResponse(request)
        case "actors":
            return await imageResponse(path: request.path)
        case "video":
            return transcodeResponse(parts, request)
        default:
            return .notFound()
        }
    }

    private func plexTVResponse(_ parts: [String], _ request: DemoRequest) async -> DemoResponse {
        guard parts.count >= 3, parts[1] == "v2" else { return .notFound() }
        switch (request.method, parts[2], parts.count) {
        case ("POST", "pins", 3):
            let fields = request.formFields
            return await plexTV.createPin(
                strong: fields["strong"]?.lowercased() == "true",
                product: fields["X-Plex-Product"] ?? "Crucible",
                clientIdentifier: fields["X-Plex-Client-Identifier"] ?? request.headers["x-plex-client-identifier"] ?? ""
            )
        case (_, "pins", 4):
            guard let id = Int(parts[3]) else { return .notFound() }
            return await plexTV.pollPin(id)
        case (_, "resources", 3):
            return await plexTV.resources(baseURL: "http://\(request.headers["host"] ?? "127.0.0.1")")
        case (_, "user", 3):
            return await plexTV.user()
        default:
            return .notFound()
        }
    }

    private func stateResponse(_ parts: [String], _ request: DemoRequest) async -> DemoResponse {
        guard parts.count == 2 else { return .notFound() }
        switch parts[1] {
        case "scrobble":
            await library.scrobble(request.first("key") ?? "")
        case "unscrobble":
            await library.unscrobble(request.first("key") ?? "")
        case "rate":
            await library.rate(request.first("key") ?? "", rating: request.int("rating") ?? 0)
        case "timeline":
            await library.timeline(
                request.first("ratingKey") ?? "",
                timeMs: request.int("time") ?? 0,
                durationMs: request.int("duration") ?? 0,
                state: request.first("state") ?? ""
            )
        case "progress":
            let key = (request.first("key") ?? "").split(separator: "/").last.map(String.init) ?? ""
            await library.progress(key, timeMs: request.int("time") ?? 0)
        default:
            return .notFound()
        }
        return .empty()
    }

    private func libraryResponse(_ parts: [String], _ request: DemoRequest) async -> DemoResponse {
        if parts == ["library", "sections", "watchlist", "all"] {
            return await library.watchlistResponse()
        }
        switch (parts.count > 1 ? parts[1] : "", parts.count) {
        case ("sections", 4) where ["refresh", "analyze", "emptyTrash"].contains(parts[3]):
            return parts[3] == "refresh" ? await library.noteScan(sectionID: parts[2]) : .empty()
        case ("sections", 4) where parts[3] == "all" && request.method == "PUT":
            return await library.editFields(request)
        case ("sections", 2):
            return await library.sectionsResponse()
        case ("sections", 3...5):
            let what = parts.count > 3 ? parts[3] : nil
            let bucket = parts.count > 4 ? parts[4] : nil
            return await library.sectionResponse(parts[2], what: what, bucket: bucket, request: request)
        case ("metadata", 3...5):
            return await metadataResponse(parts, request)
        case ("collections", 4) where parts[3] == "children":
            return await library.collectionChildrenResponse(parts[2], request: request)
        case ("onDeck", 2):
            return await library.onDeckResponse()
        case ("recentlyAdded", 2):
            return await library.recentlyAddedResponse(request)
        case ("parts", 3):
            return .empty()
        case ("parts", 5):
            return partResponse(parts[4], request)
        case ("streams", 3):
            let id = Int(parts[2]) ?? 0
            return .text(DemoSubtitles.srt(forStream: id))
        default:
            return .notFound()
        }
    }

    private func watchlistAction(_ parts: [String], _ request: DemoRequest) async -> DemoResponse {
        guard parts.count == 2, let key = request.first("ratingKey") else { return .notFound() }
        switch parts[1] {
        case "addToWatchlist": return await library.changeWatchlist(discoverKey: key, adding: true)
        case "removeFromWatchlist": return await library.changeWatchlist(discoverKey: key, adding: false)
        case "removeFromContinueWatching": return await library.removeFromContinueWatching(key)
        default: return .notFound()
        }
    }

    private func playlistsResponse(_ parts: [String], _ request: DemoRequest) async -> DemoResponse {
        switch (request.method, parts.count) {
        case ("GET", 1):
            return await library.playlistsResponse()
        case ("POST", 1):
            return await library.createPlaylist(title: request.first("title") ?? "", uri: request.first("uri") ?? "")
        case ("DELETE", 2):
            return await library.deletePlaylist(parts[1])
        case ("GET", 3) where parts[2] == "items":
            return await library.playlistItemsResponse(parts[1], request: request)
        case ("PUT", 3) where parts[2] == "items":
            return await library.addToPlaylist(parts[1], uri: request.first("uri") ?? "")
        case ("DELETE", 4) where parts[2] == "items":
            return await library.removeFromPlaylist(parts[1], itemID: Int(parts[3]) ?? 0)
        case ("PUT", 5) where parts[2] == "items" && parts[4] == "move":
            return await library.movePlaylistItem(parts[1], itemID: Int(parts[3]) ?? 0, after: request.int("after"))
        default:
            return .notFound()
        }
    }

    private func metadataResponse(_ parts: [String], _ request: DemoRequest) async -> DemoResponse {
        if parts.count >= 4, parts[3] == "thumb" || parts[3] == "art" {
            return await imageResponse(path: request.path)
        }
        if parts.count == 4, parts[3] == "subtitles" {
            switch request.method {
            case "GET":
                return await library.subtitleSearchResponse(parts[2], language: request.first("language") ?? "en")
            case "PUT":
                return await library.downloadSubtitle(
                    parts[2], language: request.first("language") ?? "en", name: request.first("language") ?? "en",
                    hearingImpaired: request.flag("hearingImpaired")
                )
            default:
                return .notFound()
            }
        }
        if parts.count == 3, request.method == "DELETE" {
            return .json(["errors": [["code": 1, "message": "Media deletion is not allowed on this server"]]], status: 403)
        }
        if parts.count == 4 {
            switch parts[3] {
            case "refresh", "analyze", "unmatch", "match":
                return .empty()
            case "matches":
                return await library.matchesResponse(parts[2], title: request.first("title"), year: request.int("year"))
            case "posters", "arts":
                return await library.artworkResponse(parts[2], kind: parts[3])
            case "poster", "art":
                return await library.selectArtwork(parts[2], kind: parts[3], url: request.first("url"))
            default:
                break
            }
        }
        switch parts.count {
        case 3: return await library.metadataResponse(parts[2], sub: nil)
        case 4: return await library.metadataResponse(parts[2], sub: parts[3])
        default: return .notFound()
        }
    }

    private func hubsResponse(_ parts: [String], _ request: DemoRequest) async -> DemoResponse {
        switch (parts.count > 1 ? parts[1] : "", parts.count) {
        case ("", 1):
            return await library.hubsResponse(count: request.int("count") ?? 20)
        case ("sections", 3):
            return await library.sectionHubsResponse(parts[2])
        case ("search", 2):
            return await library.searchResponse(request.first("query") ?? "")
        default:
            return .notFound()
        }
    }

    private func photoResponse(_ request: DemoRequest) async -> DemoResponse {
        let url = request.first("url") ?? ""
        let path = URL(string: url)?.path ?? url
        return await imageResponse(path: path.isEmpty ? url : path)
    }

    private func imageResponse(path: String) async -> DemoResponse {
        guard let name = await library.imageFileName(forPath: path) else { return .notFound() }
        var response = DemoFiles.respond(assets.image(name), contentType: "image/jpeg", request: nil)
        response.headers["Cache-Control"] = Self.imageCacheControl
        return response
    }

    private func partResponse(_ file: String, _ request: DemoRequest) -> DemoResponse {
        guard file.hasPrefix("file.") else { return .notFound() }
        return DemoFiles.respond(assets.clip, contentType: "video/mp4", request: request)
    }

    /// The universal transcoder: a master playlist on start, then the media playlist and segments of the session. The offset is not
    /// honoured; every title is the same short clip.
    private func transcodeResponse(_ parts: [String], _ request: DemoRequest) -> DemoResponse {
        guard parts.count >= 5, parts[1] == ":", parts[2] == "transcode", parts[3] == "universal" else { return .notFound() }
        switch parts[4] {
        case "start.m3u8", "start":
            let session = request.first("session") ?? "demo"
            return .text(assets.masterPlaylist(session: session), contentType: DemoAssets.contentType(forFile: "x.m3u8"))
        case "decision":
            return .container(["size": 1, "generalDecisionCode": 1000, "generalDecisionText": "Direct play OK.",
                               "directPlayDecisionCode": 1000, "transcodeDecisionCode": 1000])
        case "ping", "stop":
            return .empty()
        case "session":
            guard let name = parts.last, parts.count >= 7 else { return .notFound() }
            return streamFile(name, request)
        default:
            return streamFile(parts[4], request)
        }
    }

    private func streamFile(_ name: String, _ request: DemoRequest) -> DemoResponse {
        guard !name.contains("/"), !name.hasPrefix(".") else { return .notFound() }
        return DemoFiles.respond(assets.stream(name), contentType: DemoAssets.contentType(forFile: name), request: request)
    }
}

enum DemoFiles {
    /// Serves a file whole, or the slice a `Range` header asks for with 206 and `Content-Range`. A missing file is a 404.
    static func respond(_ url: URL, contentType: String, request: DemoRequest?) -> DemoResponse {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .notFound() }
        var headers = ["Accept-Ranges": "bytes"]
        guard let header = request?.headers["range"], header.hasPrefix("bytes="), !header.contains(",") else {
            return DemoResponse(contentType: contentType, headers: headers, body: data)
        }
        guard let range = parseRange(header, total: data.count) else {
            return DemoResponse(status: 416, headers: ["Content-Range": "bytes */\(data.count)"])
        }
        headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)"
        return DemoResponse(status: 206, contentType: contentType, headers: headers, body: data.subdata(in: range))
    }

    /// The byte range of `bytes=a-b`, `bytes=a-` or `bytes=-n`; nil when it is not one range or lies outside the file.
    static func parseRange(_ header: String, total: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let spec = header.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard spec.count == 2 else { return nil }
        let first = Int(spec[0].trimmingCharacters(in: .whitespaces))
        let last = Int(spec[1].trimmingCharacters(in: .whitespaces))
        switch (first, last) {
        case (let start?, let end?):
            guard start <= end, start < total else { return nil }
            return start..<(min(end, total - 1) + 1)
        case (let start?, nil):
            return start < total ? start..<total : nil
        case (nil, let suffix?):
            guard suffix > 0, total > 0 else { return nil }
            return max(0, total - suffix)..<total
        default:
            return nil
        }
    }
}

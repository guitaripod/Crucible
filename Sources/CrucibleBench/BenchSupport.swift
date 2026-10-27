import Foundation
import CrucibleCore

/// One fake Plex server per benchmark scenario, answering `URLSession` requests for a made-up host so the
/// real loaders and resolvers run against canned responses and every request is recorded in order.
final class BenchServer: @unchecked Sendable {
    fileprivate struct Reply {
        var status = 200
        var items: [PlexMetadata] = []
        var failsAtTransport = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: BenchServer] = [:]
    nonisolated(unsafe) private static var registered = false

    let host = "bench-\(UUID().uuidString.lowercased()).test"
    private let state = NSLock()
    private var replies: [String: Reply] = [:]
    private var log: [String] = []

    init() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if !Self.registered {
            URLProtocol.registerClass(BenchURLProtocol.self)
            Self.registered = true
        }
        Self.servers[host] = self
    }

    var client: APIClient {
        APIClient(baseURL: URL(string: "http://\(host)")!, token: "bench")
    }

    var requestedPaths: [String] {
        state.lock()
        defer { state.unlock() }
        return log
    }

    func reply(_ path: String, items: [PlexMetadata]) {
        state.lock()
        replies[path] = Reply(items: items)
        state.unlock()
    }

    func fail(_ path: String) {
        state.lock()
        replies[path] = Reply(failsAtTransport: true)
        state.unlock()
    }

    fileprivate func answer(_ request: URLRequest) -> Reply {
        let path = request.url?.path ?? ""
        state.lock()
        log.append(path)
        let reply = replies[path] ?? Reply(status: 404)
        state.unlock()
        return reply
    }

    fileprivate static func server(for request: URLRequest) -> BenchServer? {
        lock.lock()
        defer { lock.unlock() }
        return request.url?.host.flatMap { servers[$0] }
    }
}

final class BenchURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        BenchServer.server(for: request) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let server = BenchServer.server(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let reply = server.answer(request)
        if reply.failsAtTransport {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let metadata = reply.items.map(Fixtures.json)
        let body: [String: Any] = metadata.isEmpty
            ? ["MediaContainer": ["size": 0]]
            : ["MediaContainer": ["size": metadata.count, "Metadata": metadata]]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let response = HTTPURLResponse(
            url: url,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Plex metadata for the benchmark's one show: six episodes over two seasons, built the way the server
/// sends them so the real decoders and resolvers run unmodified.
enum Fixtures {
    static let showKey = "100"
    static let seasonKeys = [1: "200", 2: "400"]
    static let episodeCounts = [1: 3, 2: 3]

    static func show(viewed: Int = 0, total: Int = 6) -> PlexMetadata {
        decode([
            "ratingKey": showKey,
            "type": "show",
            "title": "The Show",
            "leafCount": total,
            "viewedLeafCount": viewed,
            "childCount": 2,
        ])
    }

    static func season(_ number: Int, watched: Int? = nil, total: Int? = nil) -> PlexMetadata {
        decode([
            "ratingKey": seasonKeys[number]!,
            "type": "season",
            "title": "Season \(number)",
            "index": number,
            "parentRatingKey": showKey,
            "parentTitle": "The Show",
            "leafCount": total ?? episodeCounts[number]!,
            "viewedLeafCount": watched ?? 0,
        ])
    }

    static func episodeKey(season: Int, index: Int) -> String {
        "\(season)\(String(format: "%02d", index))"
    }

    static func episode(
        season: Int,
        index: Int,
        watched: Bool = false,
        offsetSecs: Double? = nil,
        durationSecs: Double = 2_400,
        lastViewedAt: Int? = nil
    ) -> PlexMetadata {
        var fields: [String: Any] = [
            "ratingKey": episodeKey(season: season, index: index),
            "type": "episode",
            "title": "Episode \(index)",
            "index": index,
            "parentIndex": season,
            "parentRatingKey": seasonKeys[season]!,
            "parentTitle": "Season \(season)",
            "grandparentRatingKey": showKey,
            "grandparentTitle": "The Show",
            "duration": Int(durationSecs * 1000),
        ]
        if watched { fields["viewCount"] = 1 }
        if let offsetSecs { fields["viewOffset"] = Int(offsetSecs * 1000) }
        if let lastViewedAt { fields["lastViewedAt"] = lastViewedAt }
        return decode(fields)
    }

    static func seasonEpisodes(_ number: Int, watchedThrough: Int = 0) -> [PlexMetadata] {
        (1...episodeCounts[number]!).map {
            episode(season: number, index: $0, watched: $0 <= watchedThrough)
        }
    }

    static func allEpisodes(season1: Int = 0, season2: Int = 0) -> [PlexMetadata] {
        seasonEpisodes(1, watchedThrough: season1) + seasonEpisodes(2, watchedThrough: season2)
    }

    static func json(_ item: PlexMetadata) -> [String: Any] {
        var fields: [String: Any] = [
            "ratingKey": item.id,
            "type": item.mediaType,
            "title": item.title,
        ]
        if let index = item.index { fields["index"] = index }
        if let parentIndex = item.parentIndex { fields["parentIndex"] = parentIndex }
        if let parentKey = item.parentRatingKey { fields["parentRatingKey"] = parentKey }
        if let showKey = item.grandparentRatingKey { fields["grandparentRatingKey"] = showKey }
        if let showTitle = item.grandparentTitle { fields["grandparentTitle"] = showTitle }
        if let duration = item.duration { fields["duration"] = duration }
        if let viewOffset = item.viewOffset { fields["viewOffset"] = viewOffset }
        if let viewCount = item.viewCount { fields["viewCount"] = viewCount }
        if let lastViewedAt = item.lastViewedAt { fields["lastViewedAt"] = lastViewedAt }
        if let leafCount = item.leafCount { fields["leafCount"] = leafCount }
        if let viewed = item.viewedLeafCount { fields["viewedLeafCount"] = viewed }
        if let childCount = item.childCount { fields["childCount"] = childCount }
        if let thumb = item.thumb { fields["thumb"] = thumb }
        return fields
    }

    private static func decode(_ fields: [String: Any]) -> PlexMetadata {
        let data = try! JSONSerialization.data(withJSONObject: fields)
        return try! JSONDecoder().decode(PlexMetadata.self, from: data)
    }
}

/// A show whose seasons and episodes the benchmark's server answers for, including the routes a player
/// needs to leave one season for the next: the show's seasons, the show's leaves and each season's
/// episodes.
enum BenchShow {
    static func serve(
        on server: BenchServer,
        watchedThrough: Int = 0,
        seasons: [Int] = [1, 2],
        episodes: [PlexMetadata]? = nil
    ) {
        server.reply("/library/metadata/\(Fixtures.showKey)", items: [Fixtures.show(viewed: watchedThrough)])
        server.reply("/library/metadata/\(Fixtures.showKey)/children", items: seasons.map { Fixtures.season($0) })
        server.reply("/library/metadata/\(Fixtures.showKey)/allLeaves", items: episodes ?? Fixtures.allEpisodes())
        for season in seasons {
            let key = Fixtures.seasonKeys[season]!
            server.reply("/library/metadata/\(key)", items: [Fixtures.season(season)])
            server.reply("/library/metadata/\(key)/children", items: Fixtures.seasonEpisodes(season))
        }
    }

    static func resolver(after episode: PlexMetadata) -> UpNextResolver {
        UpNextResolver(
            ratingKey: episode.id,
            isEpisode: episode.mediaType == "episode",
            seasonRatingKey: episode.parentRatingKey,
            markers: []
        )
    }
}

/// The one place the benchmark asks "did this episode finish?", the way the player and the screens do.
/// It has to keep calling whatever rule the app itself uses, so the expectation never has to change:
/// today that is the percentage alone (`WatchedRule`), which knows nothing about credits markers.
enum FinishedProbe {
    static func isFinished(positionSecs: Double, durationSecs: Double, creditsStartSecs: Double?) -> Bool {
        WatchedRule.isWatched(positionMs: Int(positionSecs * 1000), durationMs: Int(durationSecs * 1000))
    }
}

import Foundation
@testable import CrucibleCore

/// Answers `URLSession.shared` requests for one fake host, so loaders run against canned Plex responses and every request is recorded in order.
final class DetailStubServer: @unchecked Sendable {
    struct Reply {
        var status = 200
        var body: [String: Any] = [:]
        var failsAtTransport = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: DetailStubServer] = [:]
    nonisolated(unsafe) private static var registered = false

    let host = "detail-\(UUID().uuidString.lowercased()).test"
    private let state = NSLock()
    private var replies: [String: Reply] = [:]
    private var log: [String] = []
    private var urlLog: [String] = []

    init() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if !Self.registered {
            URLProtocol.registerClass(StubProtocol.self)
            Self.registered = true
        }
        Self.servers[host] = self
    }

    deinit {
        Self.lock.lock()
        Self.servers[host] = nil
        Self.lock.unlock()
    }

    var client: APIClient {
        APIClient(baseURL: URL(string: "http://\(host)")!, token: "token")
    }

    var requests: [String] {
        state.lock()
        defer { state.unlock() }
        return log
    }

    var requestedURLs: [String] {
        state.lock()
        defer { state.unlock() }
        return urlLog
    }

    func reply(path: String, status: Int = 200, items: [PlexMetadata] = []) {
        let metadata = items.map(DetailFixtures.json)
        let body: [String: Any] = metadata.isEmpty ? ["MediaContainer": ["size": 0]] : ["MediaContainer": ["size": metadata.count, "Metadata": metadata]]
        state.lock()
        replies[path] = Reply(status: status, body: body)
        state.unlock()
    }

    func failTransport(path: String) {
        state.lock()
        replies[path] = Reply(failsAtTransport: true)
        state.unlock()
    }

    func note(_ event: String) {
        state.lock()
        log.append(event)
        state.unlock()
    }

    fileprivate func answer(_ request: URLRequest) -> Reply {
        let path = request.url?.path ?? ""
        state.lock()
        log.append(path)
        urlLog.append(request.url?.absoluteString ?? path)
        let reply = replies[path]
        state.unlock()
        return reply ?? Reply(status: 404)
    }

    fileprivate static func server(for request: URLRequest) -> DetailStubServer? {
        lock.lock()
        defer { lock.unlock() }
        return request.url?.host.flatMap { servers[$0] }
    }
}

final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        DetailStubServer.server(for: request) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let server = DetailStubServer.server(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let reply = server.answer(request)
        if reply.failsAtTransport {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let data = (try? JSONSerialization.data(withJSONObject: reply.body)) ?? Data()
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

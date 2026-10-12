import Foundation

struct DemoRequest: Sendable {
    let method: String
    let path: String
    let query: [String: [String]]
    let headers: [String: String]
    let body: Data

    func first(_ name: String) -> String? {
        query[name]?.first
    }

    func int(_ name: String) -> Int? {
        first(name).flatMap { Int($0) }
    }

    func flag(_ name: String) -> Bool {
        first(name) == "1"
    }

    var isHead: Bool { method == "HEAD" }

    /// Form fields from the body merged over the query, which is how the PIN request carries its parameters.
    var formFields: [String: String] {
        var fields = [String: String]()
        for (name, values) in DemoRequestParser.parseQuery(String(decoding: body, as: UTF8.self)) {
            fields[name] = values.first
        }
        for (name, values) in query { fields[name] = values.first }
        return fields
    }
}

struct DemoResponse: Sendable {
    var status: Int
    var contentType: String?
    var headers: [String: String]
    var body: Data

    init(status: Int = 200, contentType: String? = nil, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.contentType = contentType
        self.headers = headers
        self.body = body
    }

    static func empty(_ status: Int = 200) -> DemoResponse {
        DemoResponse(status: status)
    }

    static func json(_ object: Any, status: Int = 200) -> DemoResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        return DemoResponse(status: status, contentType: "application/json", body: body)
    }

    static func text(_ text: String, contentType: String = "text/plain; charset=utf-8") -> DemoResponse {
        DemoResponse(contentType: contentType, body: Data(text.utf8))
    }

    static func container(_ fields: [String: Any], status: Int = 200) -> DemoResponse {
        json(["MediaContainer": fields], status: status)
    }

    static func notFound() -> DemoResponse {
        container(["size": 0, "error": "not found"], status: 404)
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 416: return "Range Not Satisfiable"
        case 431: return "Request Header Fields Too Large"
        default: return "Error"
        }
    }

    /// The status line and headers for a body of `length` bytes.
    func head(length: Int, keepAlive: Bool) -> Data {
        var lines = ["HTTP/1.1 \(status) \(Self.reasonPhrase(status))", "Server: Plex Media Server"]
        if let contentType { lines.append("Content-Type: \(contentType)") }
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { lines.append("\(name): \(value)") }
        lines.append("Content-Length: \(length)")
        lines.append("Connection: \(keepAlive ? "keep-alive" : "close")")
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }
}

enum DemoRequestParser {
    static let headerTerminator = Data("\r\n\r\n".utf8)
    static let maxHeaderBytes = 32 * 1024
    static let maxBodyBytes = 1024 * 1024

    struct Head {
        let method: String
        let path: String
        let query: [String: [String]]
        let headers: [String: String]
        let contentLength: Int
        let keepAlive: Bool
    }

    enum Outcome {
        case incomplete
        case malformed
        case request(DemoRequest, keepAlive: Bool, consumed: Int)
    }

    /// Reads one request off the front of `buffer`: `.incomplete` until the head and the whole body have arrived.
    static func parse(_ buffer: Data) -> Outcome {
        guard let end = buffer.range(of: headerTerminator) else {
            return buffer.count > maxHeaderBytes ? .malformed : .incomplete
        }
        guard let head = parseHead(buffer[buffer.startIndex..<end.lowerBound]) else { return .malformed }
        guard head.contentLength <= maxBodyBytes else { return .malformed }
        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= head.contentLength else { return .incomplete }
        let body = buffer[bodyStart..<(bodyStart + head.contentLength)]
        let request = DemoRequest(method: head.method, path: head.path, query: head.query, headers: head.headers, body: Data(body))
        return .request(request, keepAlive: head.keepAlive, consumed: bodyStart - buffer.startIndex + head.contentLength)
    }

    static func parseHead(_ bytes: Data) -> Head? {
        let text = String(decoding: bytes, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3 else { return nil }
        let version = String(requestLine[2])
        var headers = [String: String]()
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let (path, query) = splitTarget(String(requestLine[1]))
        let connection = headers["connection"]?.lowercased()
        let keepAlive = version == "HTTP/1.1" ? connection != "close" : connection == "keep-alive"
        return Head(
            method: String(requestLine[0]).uppercased(),
            path: path,
            query: query,
            headers: headers,
            contentLength: Int(headers["content-length"] ?? "") ?? 0,
            keepAlive: keepAlive
        )
    }

    static func splitTarget(_ target: String) -> (String, [String: [String]]) {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(parts[0])
        let path = rawPath.removingPercentEncoding ?? rawPath
        let query = parts.count > 1 ? parseQuery(String(parts[1])) : [:]
        return (path, query)
    }

    static func parseQuery(_ raw: String) -> [String: [String]] {
        var query = [String: [String]]()
        for pair in raw.split(separator: "&", omittingEmptySubsequences: true) {
            let halves = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(halves[0]).removingPercentEncoding ?? String(halves[0])
            let value = halves.count > 1 ? (String(halves[1]).removingPercentEncoding ?? String(halves[1])) : ""
            query[name, default: []].append(value)
        }
        return query
    }
}

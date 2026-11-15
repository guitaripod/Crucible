import CLinuxServices
import CrucibleCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Crucible Server's pinned HTTPS on Linux (`FingerprintPinnedTransport`), through curl with OpenSSL: the server's
/// certificate fingerprint is checked inside the handshake, before the request or the Plex token in it leaves this computer,
/// since swift-corelibs-foundation cannot show a server's certificate.
struct CurlPinnedTransport: FingerprintPinnedTransport {
    /// Carries the request's check into curl's certificate callback.
    private final class Check {
        let verify: @Sendable (String) -> Bool

        init(_ verify: @escaping @Sendable (String) -> Bool) {
            self.verify = verify
        }
    }

    func send(_ request: URLRequest, timeout: TimeInterval, verify: @escaping @Sendable (String) -> Bool) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let method = request.httpMethod ?? "GET"
        let headers = (request.allHTTPHeaderFields ?? [:]).map { "\($0.key): \($0.value)" }
        let body = request.httpBody ?? Data()
        return try await Task.detached(priority: .userInitiated) {
            try Self.perform(method: method, url: url, headers: headers, body: body, timeout: timeout, verify: verify)
        }.value
    }

    private static func perform(method: String, url: URL, headers: [String], body: Data, timeout: TimeInterval,
                                verify: @escaping @Sendable (String) -> Bool) throws -> (Data, URLResponse) {
        let check = Unmanaged.passRetained(Check(verify))
        defer { check.release() }
        var response = crucible_pinned_response()
        let callback: crucible_pinned_verify = { context, fingerprint in
            guard let context, let fingerprint else { return false }
            return Unmanaged<Check>.fromOpaque(context).takeUnretainedValue().verify(String(cString: fingerprint))
        }
        let result = withCStrings(headers) { lines in
            body.withUnsafeBytes { bytes in
                crucible_pinned_send(method, url.absoluteString, lines.baseAddress, lines.count, bytes.bindMemory(to: UInt8.self).baseAddress, body.count,
                                     timeout, callback, check.toOpaque(), &response)
            }
        }
        guard result == 0 else { throw URLError(result == 60 || result == 35 ? .secureConnectionFailed : .cannotConnectToHost) }
        defer { crucible_pinned_free(&response) }
        let data = response.body.map { Data(bytes: $0, count: response.body_length) } ?? Data()
        let fields = response.headers.map { headerFields(String(cString: $0)) } ?? [:]
        guard let answer = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: fields) else {
            throw URLError(.badServerResponse)
        }
        return (data, answer)
    }

    /// The last response's "Name: value" header lines, past any interim response before it.
    static func headerFields(_ text: String) -> [String: String] {
        let blocks = text.components(separatedBy: "\r\n\r\n").filter { !$0.isEmpty }
        var fields: [String: String] = [:]
        for line in (blocks.last ?? "").components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("HTTP/") else { continue }
            fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

    /// Hands `strings` to C as an array of NUL-terminated pointers that live for the call.
    private static func withCStrings<Result>(_ strings: [String], _ body: (UnsafeBufferPointer<UnsafePointer<CChar>?>) -> Result) -> Result {
        let copies = strings.map { strdup($0) }
        defer { copies.forEach { free($0) } }
        return copies.map { UnsafePointer($0) }.withUnsafeBufferPointer(body)
    }
}

import Foundation

enum ConnectionKind: Sendable, Hashable {
    case local
    case tailscale
    case remote
    case relay

    var title: String {
        switch self {
        case .local: return "Local"
        case .tailscale: return "Tailscale"
        case .remote: return "Remote"
        case .relay: return "Plex Relay"
        }
    }
}

/// Classifies Plex routes from their URL alone. Deliberately conservative: a route is only called a
/// relay when it is a `plex.direct` name for a public address on a non-default port.
enum ConnectionRoute {
    static let defaultPort = 32400

    static func kind(of url: URL) -> ConnectionKind {
        guard let host = url.host?.lowercased() else { return .remote }
        if let octets = directAddress(from: host) {
            let kind = kind(ofIPv4: octets)
            if isPlexDirect(host), kind == .remote, let port = url.port, port != defaultPort {
                return .relay
            }
            return kind
        }
        return kind(ofName: host)
    }

    static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
    }

    static func isPlexDirect(_ host: String) -> Bool {
        host.hasSuffix(".plex.direct")
    }

    /// Octets of a literal IPv4 host, or of the dashed address a `plex.direct` name embeds.
    private static func directAddress(from host: String) -> [Int]? {
        if let octets = ipv4(host) { return octets }
        guard isPlexDirect(host), let first = host.split(separator: ".").first else { return nil }
        return ipv4(first.replacingOccurrences(of: "-", with: "."))
    }

    private static func ipv4(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }

    private static func kind(ofIPv4 octets: [Int]) -> ConnectionKind {
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (169, 254):
            return .local
        case (172, 16...31):
            return .local
        case (100, 64...127):
            return .tailscale
        default:
            return .remote
        }
    }

    private static func kind(ofName host: String) -> ConnectionKind {
        if host.contains(":") {
            let isLocalIPv6 = host == "::1" || host.hasPrefix("fe80") || host.hasPrefix("fd") || host.hasPrefix("fc")
            return isLocalIPv6 ? .local : .remote
        }
        if host.hasSuffix(".ts.net") { return .tailscale }
        if host.hasSuffix(".local") || host == "localhost" || !host.contains(".") { return .local }
        return .remote
    }

    /// Parses `http(s)://host[:port]` or a bare host/IP into URLs to try, https first. An explicit
    /// scheme is honoured as the only attempt; a bare host defaults to port 32400.
    static func candidates(from input: String) -> [URL]? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }

        var schemes = ["https", "http"]
        var remainder = trimmed
        if let range = trimmed.range(of: "://") {
            let scheme = trimmed[..<range.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
            schemes = [scheme]
            remainder = String(trimmed[range.upperBound...])
        }
        while remainder.hasSuffix("/") { remainder.removeLast() }
        guard !remainder.isEmpty, !remainder.contains("/"), !remainder.contains("?"), !remainder.contains("#") else { return nil }

        let host: String
        var port = defaultPort
        if let colon = remainder.lastIndex(of: ":"), !remainder.hasPrefix("[") {
            host = String(remainder[..<colon])
            guard let parsed = Int(remainder[remainder.index(after: colon)...]), (1...65535).contains(parsed) else { return nil }
            port = parsed
        } else {
            host = remainder
        }
        guard isValidHost(host) else { return nil }

        let urls = schemes.compactMap { scheme -> URL? in
            var components = URLComponents()
            components.scheme = scheme
            components.host = host
            components.port = port
            return components.url
        }
        return urls.isEmpty ? nil : urls
    }

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return ipv4(host) != nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return !host.hasPrefix(".") && !host.hasPrefix("-") && !host.hasSuffix(".") && !host.contains("..")
    }
}

struct ConnectionProbe: Sendable {
    let latencyMs: Int
    let version: String?
    let machineIdentifier: String?
}

enum ConnectionProber {
    /// A short-timeout `GET /identity` against one route. Uses a plain `URLSession` request so a
    /// dead address never triggers `APIClient`'s failover and repin.
    static func probe(baseURL: URL, token: String, timeout: TimeInterval = 4) async -> ConnectionProbe? {
        var request = URLRequest(url: baseURL.appendingPathComponent("identity"))
        request.timeoutInterval = timeout
        for (key, value) in PlexHeaders.allHeaders(token: token) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let elapsed = start.duration(to: clock.now)
            let milliseconds = Int((Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15).rounded())
            let container = (try? JSONDecoder().decode(PlexIdentity.self, from: data))?.MediaContainer
            return ConnectionProbe(
                latencyMs: max(milliseconds, 1),
                version: container?.version,
                machineIdentifier: container?.machineIdentifier
            )
        } catch {
            return nil
        }
    }
}

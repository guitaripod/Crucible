import Foundation

/// One advertised route to a server, with its measured probe state.
struct ServerRoute: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case local, tailscale, remote, relay

        var title: String {
            switch self {
            case .local: return "Local"
            case .tailscale: return "Tailscale"
            case .remote: return "Remote"
            case .relay: return "Plex Relay"
            }
        }
    }

    enum State: Hashable, Sendable {
        case probing
        case reachable(milliseconds: Int)
        case unreachable
    }

    let uri: String
    let address: String
    let kind: Kind
    var state: State = .probing

    var milliseconds: Int? {
        if case .reachable(let ms) = state { return ms }
        return nil
    }

    init(connection: PlexResourceConnection) {
        uri = connection.uri
        let host = connection.address ?? URL(string: connection.uri)?.host ?? connection.uri
        address = host
        if connection.relay == true {
            kind = .relay
        } else if Self.isTailscale(host) {
            kind = .tailscale
        } else if connection.local == true {
            kind = .local
        } else {
            kind = .remote
        }
    }

    /// Tailscale hands out CGNAT addresses (100.64.0.0/10) and MagicDNS names under `ts.net`.
    private static func isTailscale(_ host: String) -> Bool {
        if host.hasSuffix(".ts.net") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }
}

/// A server from the plex.tv resource list plus the live probe state of each of its routes.
struct ServerChoice: Hashable, Sendable {
    let id: String
    let name: String
    let isOwned: Bool
    let isOnline: Bool
    let lastSeen: Date?
    var routes: [ServerRoute]

    init(resource: PlexResource) {
        id = resource.clientIdentifier
        name = resource.name
        isOwned = resource.owned ?? false
        isOnline = resource.presence ?? true
        lastSeen = resource.lastSeenAt.flatMap(Self.parseDate)
        routes = ServerChoice.ranked(resource.connections).map(ServerRoute.init(connection:))
    }

    var isProbing: Bool {
        routes.contains { $0.state == .probing }
    }

    /// The highest-priority route that answered, following the ranked order of `routes`.
    var bestRoute: ServerRoute? {
        routes.first { $0.milliseconds != nil }
    }

    var fastestMilliseconds: Int? {
        routes.compactMap(\.milliseconds).min()
    }

    var detailText: String {
        guard isOnline else {
            guard let lastSeen else { return "Offline" }
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .full
            return "Offline · last seen \(relative.localizedString(for: lastSeen, relativeTo: Date()))"
        }
        let owner = isOwned ? "Owned by you" : "Shared with you"
        return "\(owner) · \(routes.count) \(routes.count == 1 ? "connection" : "connections")"
    }

    mutating func record(routeAt index: Int, milliseconds: Int?) {
        guard routes.indices.contains(index) else { return }
        routes[index].state = milliseconds.map { .reachable(milliseconds: $0) } ?? .unreachable
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    /// Orders connections best-first: local before remote, direct before relay, HTTPS before HTTP.
    /// Docker-bridge addresses (RFC 1918 ranges a phone can never route) are demoted below the
    /// server's LAN address so a same-network client pins a route it can actually reach.
    static func ranked(_ connections: [PlexResourceConnection]) -> [PlexResourceConnection] {
        func score(_ connection: PlexResourceConnection) -> Int {
            var score = 0
            if connection.relay == true { score += 100 }
            if connection.local != true { score += 10 }
            if connection.protocol != "https" { score += 1 }
            if let address = connection.address, unroutablePrefixes.contains(where: { address.hasPrefix($0) }) {
                score += 5
            }
            return score
        }
        return connections.sorted { score($0) < score($1) }
    }

    private static let unroutablePrefixes = ["172.17.", "172.18.", "172.19.", "172.20.", "172.21.", "172.22.", "172.23.", "172.24.", "172.25.", "172.26.", "172.27.", "172.28.", "172.29.", "172.30.", "172.31."]
}

enum ServerRouteProbe {
    /// Round-trip time of a single reachability probe, or nil when the route does not answer.
    /// Reuses `APIClient.probe`, the same check the launch resolver relies on.
    static func measure(_ url: URL, token: String) async -> Int? {
        let clock = ContinuousClock()
        let start = clock.now
        guard await APIClient.probe(baseURL: url, token: token) else { return nil }
        let elapsed = start.duration(to: clock.now)
        let milliseconds = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        return max(1, Int(milliseconds))
    }
}

/// A user-typed server address, validated and expanded into the URLs worth probing.
struct ServerAddress: Hashable, Sendable {
    static let defaultPort = 32400

    let host: String
    let port: Int
    let scheme: String?

    /// HTTPS first, then plain HTTP, unless the user spelled out a scheme.
    var candidateURLs: [URL] {
        let schemes = scheme.map { [$0] } ?? ["https", "http"]
        return schemes.compactMap { URL(string: "\($0)://\(host):\(port)") }
    }

    static func parse(_ raw: String) -> ServerAddress? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var scheme: String?
        if let range = text.range(of: "://") {
            let candidate = text[..<range.lowerBound].lowercased()
            guard candidate == "http" || candidate == "https" else { return nil }
            scheme = candidate
            text = String(text[range.upperBound...])
        }
        if let slash = text.firstIndex(of: "/") {
            text = String(text[..<slash])
        }

        var host = text
        var port = defaultPort
        let colons = text.filter { $0 == ":" }.count
        if colons == 1, let colon = text.firstIndex(of: ":") {
            host = String(text[..<colon])
            guard let parsed = Int(text[text.index(after: colon)...]), (1...65535).contains(parsed) else { return nil }
            port = parsed
        } else if colons > 1 {
            return nil
        }

        guard isValidHost(host) else { return nil }
        return ServerAddress(host: host, port: port, scheme: scheme)
    }

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            let octets = host.split(separator: ".", omittingEmptySubsequences: false)
            return octets.count == 4 && octets.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63
                && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

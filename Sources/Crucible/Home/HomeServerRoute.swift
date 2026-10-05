import Foundation

/// How the app currently reaches the server, derived from the pinned connection URL's host.
enum HomeServerRoute: Equatable {
    case local
    case remote
    case relay

    var title: String {
        switch self {
        case .local: return "Local"
        case .remote: return "Remote"
        case .relay: return "Relay"
        }
    }

    var symbol: String {
        switch self {
        case .local: return "house"
        case .remote: return "globe"
        case .relay: return "arrow.triangle.branch"
        }
    }

    /// Private/LAN and Tailscale (100.64/10) addresses are local. A `plex.direct` host on a public
    /// address is Plex's relay when it uses the relay port 8443, otherwise a direct remote route.
    static func classify(_ url: URL) -> HomeServerRoute {
        guard let host = url.host?.lowercased() else { return .remote }
        if host == "localhost" || host.hasSuffix(".local") { return .local }
        if host.hasSuffix(".plex.direct") {
            let label = host.split(separator: ".").first.map(String.init) ?? ""
            let address = label.replacingOccurrences(of: "-", with: ".")
            if let octets = ipv4Octets(address), isPrivate(octets) { return .local }
            return url.port == 8443 ? .relay : .remote
        }
        if let octets = ipv4Octets(host) {
            return isPrivate(octets) ? .local : .remote
        }
        if host.contains(":") {
            return host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fd") || host.hasPrefix("fc") ? .local : .remote
        }
        return .remote
    }

    private static func ipv4Octets(_ string: String) -> [Int]? {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }

    private static func isPrivate(_ o: [Int]) -> Bool {
        switch (o[0], o[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        default: return false
        }
    }
}

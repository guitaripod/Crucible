import Foundation

enum YouRouteKind: String, Sendable {
    case local = "Local"
    case tailscale = "Tailscale"
    case remote = "Remote"

    static func classify(_ url: URL) -> YouRouteKind {
        guard let host = url.host?.lowercased() else { return .remote }
        if host.hasSuffix(".ts.net") { return .tailscale }
        if host.hasSuffix(".plex.direct"), let address = embeddedAddress(inPlexDirectHost: host) {
            return classify(address: address) ?? .remote
        }
        if let kind = classify(address: host) { return kind }
        if host.hasSuffix(".local") || !host.contains(".") { return .local }
        return .remote
    }

    /// Plex Direct hostnames encode the server address as dashed octets in the leftmost label.
    private static func embeddedAddress(inPlexDirectHost host: String) -> String? {
        guard let label = host.split(separator: ".").first else { return nil }
        let dotted = label.replacingOccurrences(of: "-", with: ".")
        return dotted.split(separator: ".").count == 4 ? dotted : nil
    }

    private static func classify(address: String) -> YouRouteKind? {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168), (169, 254), (127, _): return .local
        case (172, 16...31): return .local
        case (100, 64...127): return .tailscale
        default: return .remote
        }
    }
}

enum YouConnectionState: Equatable, Sendable {
    case connecting
    case reachable(route: YouRouteKind, latencyMs: Int)
    case unreachable
}

/// Session-scoped route and latency probe behind the You hub. One `/identity` round trip per base
/// URL; a failed probe is retried the next time the hub appears.
@MainActor
final class YouConnectionStatus {
    static let shared = YouConnectionStatus()

    private(set) var state: YouConnectionState = .connecting
    var onChange: ((YouConnectionState) -> Void)?

    private var probedURL: URL?
    private var task: Task<Void, Never>?

    private init() {}

    func refresh(api: APIClient) {
        guard task == nil else { return }
        task = Task { [weak self] in
            let url = await api.baseURL
            guard let self else { return }
            if url == probedURL, case .reachable = state {
                task = nil
                return
            }
            if url != probedURL { update(.connecting) }
            let clock = ContinuousClock()
            let start = clock.now
            let ok = await api.identityCheck()
            let elapsed = start.duration(to: clock.now)
            probedURL = url
            let milliseconds = Int((Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15).rounded())
            update(ok ? .reachable(route: YouRouteKind.classify(url), latencyMs: max(1, milliseconds)) : .unreachable)
            task = nil
        }
    }

    private func update(_ newState: YouConnectionState) {
        guard newState != state else { return }
        state = newState
        onChange?(newState)
    }
}

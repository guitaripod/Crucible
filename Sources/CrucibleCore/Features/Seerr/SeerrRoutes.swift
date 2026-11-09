import Foundation

/// The addresses a connected Seerr is tried at, best first for the network this device is on.
///
/// A Seerr that runs on the Plex computer follows the server: it is tried at its own port on every home and tailnet address
/// the server answers at, led by the host of the route Crucible uses for Plex right now. That route was picked by probing
/// the network (`ServerRouteMonitor`), so Seerr is reached over the home network at home and over Tailscale away from it
/// without anyone choosing. Addresses the viewer gave themselves, such as a public HTTPS name, come along too.
package enum SeerrRoutes {
    /// The most addresses kept from earlier connections and moves.
    package static let rememberedLimit = 4

    /// - Parameters:
    ///   - address: where Seerr last answered.
    ///   - remembered: other addresses Seerr answered at before.
    ///   - serverRoutes: every route Crucible knows to the Plex server.
    ///   - serverInUse: the route Crucible uses for Plex now.
    package static func ordered(address: URL, remembered: [URL], serverRoutes: [URL], serverInUse: URL?) -> [URL] {
        let serverHosts = hosts(of: [serverInUse].compactMap { $0 } + serverRoutes)
        var all = [address]
        if let host = address.host?.lowercased(), serverHosts.contains(host) {
            all += serverHosts.compactMap { replacingHost(of: address, with: $0) }
        }
        all += remembered
        var seen = Set<String>()
        let unique = all.filter { seen.insert($0.absoluteString.lowercased()).inserted }
        let inUseHost = serverInUse.flatMap(SeerrDiscovery.reachableHost(of:))
        let inUseKind = serverInUse.map(ConnectionRoute.kind(of:))
        return unique.enumerated().sorted { lhs, rhs in
            let left = rank(lhs.element, inUseHost: inUseHost, inUseKind: inUseKind)
            let right = rank(rhs.element, inUseHost: inUseHost, inUseKind: inUseKind)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    /// Whether the Seerr at `address` runs on the Plex computer, so its addresses follow the server's.
    package static func followsServer(_ address: URL, serverRoutes: [URL]) -> Bool {
        guard let host = address.host?.lowercased() else { return false }
        return hosts(of: serverRoutes).contains(host)
    }

    /// `remembered` with `address` added at the front, without repeats, at most `rememberedLimit` long.
    package static func remembering(_ address: URL, in remembered: [URL]) -> [URL] {
        Array(([address] + remembered.filter { $0 != address }).prefix(rememberedLimit))
    }

    /// The home and tailnet hosts of `routes`, in their order; container bridges and public addresses are left out.
    static func hosts(of routes: [URL]) -> [String] {
        var seen = Set<String>()
        return routes.filter { !ConnectionRoute.isContainerBridge($0) }
            .compactMap(SeerrDiscovery.reachableHost(of:))
            .filter { seen.insert($0).inserted }
    }

    /// The host of the Plex route in use first, then routes of its kind, then the home network before the tailnet and both
    /// before anything public.
    private static func rank(_ url: URL, inUseHost: String?, inUseKind: ConnectionKind?) -> Int {
        let host = url.host?.lowercased()
        if let inUseHost, host == inUseHost { return 0 }
        let kind = ConnectionRoute.kind(of: url)
        if let inUseKind, kind == inUseKind { return 1 }
        switch kind {
        case .local: return 2
        case .tailscale: return 3
        case .remote, .relay: return 4
        }
    }

    private static func replacingHost(of address: URL, with host: String) -> URL? {
        guard var components = URLComponents(url: address, resolvingAgainstBaseURL: false) else { return nil }
        components.host = host
        return components.url
    }
}

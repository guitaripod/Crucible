import Foundation

extension ServerRoute {
    /// "Local · 4 ms" once the route answered, the kind alone before.
    package var badgeText: String {
        guard let milliseconds else { return kind.title }
        return "\(kind.title) · \(milliseconds) ms"
    }
}

extension ServerChoice {
    /// The line under the server name: how it is shared, or why it cannot be used.
    package var statusLine: String {
        reachability == .unreachable ? "This server is unreachable. Select to test again." : detailText
    }

    /// The trailing value of a server row: the best route with its latency, or the state.
    package var routeValue: String {
        switch reachability {
        case .offline: return "Offline"
        case .probing: return "Testing…"
        case .reachable: return bestRoute?.badgeText ?? "Reachable"
        case .unreachable: return "Unreachable"
        }
    }

    /// True once the best route can no longer change: the first route that is not known to be dead
    /// has answered, or every route is dead. Slower, lower-ranked routes may still be in flight.
    package var isSettled: Bool {
        guard let candidate = routes.first(where: { $0.state != .unreachable }) else { return true }
        return candidate.milliseconds != nil
    }

    /// Forgets every probe result so the routes are measured again.
    package mutating func resetProbes() {
        for index in routes.indices {
            routes[index].state = .probing
        }
    }
}

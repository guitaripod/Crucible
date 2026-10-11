import Foundation

/// The state of the Choose Server step: which server is selected, what the route probes found,
/// and what the Connect button should say. The first online server starts selected; once every
/// probe has settled the fastest one is selected unless the person already chose.
///
/// ```swift
/// var picker = ServerPickerState(choices: servers)
/// for await measurement in discovery.measureRoutes(picker.probeTargets) {
///     picker.record(server: measurement.serverID, route: measurement.routeIndex, milliseconds: measurement.milliseconds)
/// }
/// picker.finishProbing()
/// if let target = picker.autoContinue { connect(target.choice, target.route) }
/// ```
package struct ServerPickerState: Sendable {
    package enum ConnectAction: Equatable, Sendable {
        case chooseServer
        case testing(serverName: String)
        case noRoute(serverName: String)
        case ready(serverName: String)
        case connecting

        package var title: String {
            switch self {
            case .chooseServer: return "Choose a Server"
            case .testing: return "Testing connections…"
            case .noRoute(let name): return "No route to \(name)"
            case .ready(let name): return "Connect to \(name)"
            case .connecting: return "Connecting…"
            }
        }

        package var showsActivity: Bool {
            switch self {
            case .testing, .connecting: return true
            case .chooseServer, .noRoute, .ready: return false
            }
        }

        package var isEnabled: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    package private(set) var choices: [ServerChoice]
    package private(set) var selectedID: String?
    private var userChoseServer = false

    package init(choices: [ServerChoice]) {
        self.choices = choices
        selectedID = choices.first(where: \.isOnline)?.id
    }

    package var selectedChoice: ServerChoice? {
        choices.first { $0.id == selectedID }
    }

    package func choice(withID id: String) -> ServerChoice? {
        choices.first { $0.id == id }
    }

    /// Only servers plex.tv reports online can be selected.
    package func isSelectable(_ id: String) -> Bool {
        choice(withID: id)?.isOnline == true
    }

    /// The person picked a server. Returns false when it was already selected.
    @discardableResult
    package mutating func choose(_ id: String) -> Bool {
        guard id != selectedID else { return false }
        userChoseServer = true
        selectedID = id
        return true
    }

    /// Every route of every online server whose address parses, ready for `measureRoutes`.
    package var probeTargets: [RouteProbeTarget] {
        choices.filter(\.isOnline).flatMap { choice in
            choice.routes.enumerated().compactMap { index, route in
                URL(string: route.uri).map { RouteProbeTarget(serverID: choice.id, routeIndex: index, url: $0) }
            }
        }
    }

    /// Routes of online servers whose address cannot be parsed, so they can never be probed and
    /// are recorded as unreachable up front.
    package var unprobeableRoutes: [(serverID: String, routeIndex: Int)] {
        choices.filter(\.isOnline).flatMap { choice in
            choice.routes.enumerated().compactMap { index, route in
                URL(string: route.uri) == nil ? (choice.id, index) : nil
            }
        }
    }

    /// Stores a probe result. Returns false for a server that is not in the list.
    @discardableResult
    package mutating func record(server: String, route: Int, milliseconds: Int?) -> Bool {
        guard let position = choices.firstIndex(where: { $0.id == server }) else { return false }
        choices[position].record(routeAt: route, milliseconds: milliseconds)
        return true
    }

    /// Selects the lowest-latency server once every probe has settled, unless the person already
    /// chose. Returns true when the selection moved.
    @discardableResult
    package mutating func finishProbing() -> Bool {
        guard !userChoseServer else { return false }
        let fastest = choices
            .filter(\.isOnline)
            .compactMap { choice in choice.fastestMilliseconds.map { (choice.id, $0) } }
            .min { $0.1 < $1.1 }
        guard let fastest, fastest.0 != selectedID else { return false }
        selectedID = fastest.0
        return true
    }

    /// Marks every route of an online server as untested again and returns the probes to run for it.
    package mutating func restartProbing(of id: String) -> [RouteProbeTarget] {
        guard let position = choices.firstIndex(where: { $0.id == id }), choices[position].isOnline else { return [] }
        choices[position].resetProbes()
        return probeTargets.filter { $0.serverID == id }
    }

    package func connectAction(isConnecting: Bool) -> ConnectAction {
        if isConnecting { return .connecting }
        guard let choice = selectedChoice else { return .chooseServer }
        if choice.bestRoute != nil { return .ready(serverName: choice.name) }
        if choice.isProbing { return .testing(serverName: choice.name) }
        return .noRoute(serverName: choice.name)
    }

    /// The server to continue with automatically: exactly one online server answered and every
    /// online server's best route is settled. Nil while that is open or when there is a real
    /// choice to make.
    package var autoContinue: (choice: ServerChoice, route: ServerRoute)? {
        let online = choices.filter(\.isOnline)
        guard online.allSatisfy(\.isSettled) else { return nil }
        let reachable = online.filter { $0.bestRoute != nil }
        guard reachable.count == 1, let choice = reachable.first, let route = choice.bestRoute else { return nil }
        return (choice, route)
    }
}

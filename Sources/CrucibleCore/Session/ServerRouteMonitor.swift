import Foundation
import MidgarCore
import Network

/// How good a route to the server is for this device right now; a smaller tier is better.
package enum RouteTier: Int, Comparable, Sendable {
    case local
    case tailscale
    case remote
    case relay

    package init(_ kind: ConnectionKind) {
        switch kind {
        case .local: self = .local
        case .tailscale: self = .tailscale
        case .remote: self = .remote
        case .relay: self = .relay
        }
    }

    package static func < (lhs: RouteTier, rhs: RouteTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Which route the app should use, decided from one round of probes of every known route.
package enum RoutePlan {
    package enum Reason: Equatable, Sendable {
        /// A route of a better tier answers: home after being away, or a direct route instead of the relay.
        case better
        /// The route in use stopped answering and another does.
        case lost
        /// The viewer picked the route.
        case chosen
    }

    package enum Decision: Equatable, Sendable {
        case stay
        case move(to: URL, because: Reason)
        case unreachable
    }

    /// The route in use stays while it answers, unless a route of a better tier answers too: with Prefer Local Connection on, any
    /// better tier (home over Tailscale over remote), and always a direct route over the bandwidth-limited relay. A route the viewer
    /// picked stays while it answers. When the route in use is gone, the best route that answers takes over.
    ///
    /// - Parameter routes: every known route, best-first, as the viewer's connection preferences order them.
    package static func decide(
        current: URL,
        routes: [URL],
        answering: Set<URL>,
        kind: (URL) -> ConnectionKind,
        preferLocal: Bool,
        chosen: URL? = nil
    ) -> Decision {
        let best = routes.first { answering.contains($0) }
        guard answering.contains(current) else {
            return best.map { .move(to: $0, because: .lost) } ?? .unreachable
        }
        guard current != chosen, let best, best != current else { return .stay }
        let from = RouteTier(kind(current))
        let to = RouteTier(kind(best))
        guard to < from, preferLocal || from == .relay else { return .stay }
        return .move(to: best, because: .better)
    }

    /// `routes` best-first by tier, keeping their own order within a tier (which already puts HTTPS first and unroutable container
    /// addresses last). Relays are left out unless allowed, or unless nothing else is known.
    package static func ordered(_ routes: [URL], kind: (URL) -> ConnectionKind, allowRelay: Bool) -> [URL] {
        let tiered = routes.uniqued(by: \.self).enumerated()
            .sorted { (RouteTier(kind($0.element)), $0.offset) < (RouteTier(kind($1.element)), $1.offset) }
            .map(\.element)
        guard !allowRelay else { return tiered }
        let direct = tiered.filter { kind($0) != .relay }
        return direct.isEmpty ? tiered : direct
    }
}

/// Keeps the app on the best route to its server as the device moves between networks: home Wi-Fi, Tailscale, cellular and back.
/// It looks again when the network changes, when the app returns to the front and once after launch, probes every route the server
/// advertises plus the ones found on the tailnet, and moves the whole app (every API client, artwork and downloads) to a better
/// route that answers, or to any route that answers when the one in use is gone, before a screen has to wait on a dead address.
@MainActor
package final class ServerRouteMonitor {
    package static let shared = ServerRouteMonitor()

    /// The outside world, replaceable so the monitor can run against canned answers.
    package struct Environment: Sendable {
        package var connection: @Sendable () -> PlexConnection?
        /// Whether `url` answers as the server `machineIdentifier`, within `timeout`.
        package var probe: @Sendable (_ url: URL, _ token: String, _ machineIdentifier: String, _ timeout: TimeInterval) async -> Bool
        /// The routes plex.tv advertises for the server, best-first, and which of them are relays; nil when plex.tv cannot be asked.
        package var advertised: @Sendable (PlexConnection) async -> (routes: [URL], relays: Set<URL>)?
        /// Routes to the server on the tailnet; empty when this device is not on one.
        package var tailnet: @Sendable (PlexConnection) async -> [URL]
        /// Prefer Local Connection and Allow Relay, as the viewer set them.
        package var preferences: @Sendable () -> (preferLocal: Bool, allowRelay: Bool)
        package var isDemo: @MainActor @Sendable () -> Bool
        package var save: @MainActor @Sendable (_ pinned: URL?, _ routes: [URL]) -> Void
        package var now: @Sendable () -> Date

        package static let live = Environment(
            connection: { ServerBootstrap.connection() },
            probe: { url, token, machineIdentifier, timeout in
                await ConnectionProber.probe(baseURL: url, token: token, timeout: timeout)?.machineIdentifier == machineIdentifier
            },
            advertised: { connection in
                guard let resources: [PlexResource] = try? await APIClient.plexTVRequest(.resources, token: connection.plexTVToken),
                      let server = resources.first(where: { $0.clientIdentifier == connection.machineIdentifier }) else { return nil }
                let ranked = ServerChoice.ranked(server.connections)
                return (
                    ranked.compactMap { URL(string: $0.uri) },
                    Set(ranked.filter { $0.relay == true }.compactMap { URL(string: $0.uri) })
                )
            },
            tailnet: { connection in await ServerConnectionResolver.tailnetRoutes(for: connection) },
            preferences: { (Preferences.preferLocalConnection, Preferences.allowRelayConnection) },
            isDemo: { DemoMode.shared.isActive },
            save: { pinned, routes in
                if let pinned { ServerBootstrap.repin(uri: pinned) }
                ServerBootstrap.updateCandidates(routes)
            },
            now: Date.init
        )
    }

    package struct Move: Equatable, Sendable {
        package let route: URL
        package let reason: RoutePlan.Reason
        package let at: Date
    }

    package typealias Observer = @MainActor (Move) -> Void

    /// A probe gives up after this long: a route that takes longer is no better than the one in use.
    package static let probeTimeout: TimeInterval = 3
    /// The network settles for this long after a change before the routes are tried, since an interface comes up in steps.
    package static let settleDelay: Duration = .milliseconds(1500)
    /// plex.tv's list of routes and the tailnet search are waited on for this long, so a slow plex.tv never holds a look up.
    package static let lookupTimeout: TimeInterval = 4
    /// Coming back to the front looks again when the last look is older than this, or the network changed meanwhile.
    package static let foregroundInterval: TimeInterval = 60

    package private(set) var lastMove: Move?

    private let environment: Environment
    private var observers: [UUID: Observer] = [:]
    private var check: Task<RoutePlan.Decision, Never>?
    private var checkGeneration = 0
    private var generation = 0
    private var pendingCheck: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var pathSignature: String?
    private var isActive = true
    private var changedWhileAway = false
    private var lastCheck: Date?
    private var chosen: URL?

    package init(environment: Environment = .live) {
        self.environment = environment
    }

    /// Starts watching the network. Calling it again changes nothing.
    package func start() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let signature = Self.signature(of: path)
            Task { @MainActor in self?.networkChanged(signature) }
        }
        monitor.start(queue: DispatchQueue(label: "com.guitaripod.crucible.routes", qos: .utility))
        pathMonitor = monitor
    }

    /// The main screen is up after a launch: a moment later the routes are tried, so a session pinned to a remote route at home
    /// moves to the home one.
    package func mainAppReady() {
        schedule(after: .seconds(2), reason: "launch")
    }

    package func appBecameActive() {
        isActive = true
        let stale = lastCheck.map { environment.now().timeIntervalSince($0) >= Self.foregroundInterval } ?? true
        guard changedWhileAway || stale else { return }
        changedWhileAway = false
        schedule(after: .milliseconds(300), reason: "foreground")
    }

    package func appResignedActive() {
        isActive = false
        pendingCheck?.cancel()
        pendingCheck = nil
    }

    /// Prefer Local Connection or Allow Relay changed: the routes are weighed again under the new preferences. A route the viewer
    /// picked still holds while it answers.
    package func preferencesChanged() {
        guard pathMonitor != nil else { return }
        schedule(after: .milliseconds(300), reason: "preferences")
    }

    /// The network this device uses changed. The initial report when watching starts is not a change.
    package func networkChanged(_ signature: String) {
        guard signature != pathSignature else { return }
        let isFirst = pathSignature == nil
        pathSignature = signature
        guard !isFirst else { return }
        chosen = nil
        generation += 1
        guard isActive else {
            changedWhileAway = true
            return
        }
        schedule(after: Self.settleDelay, reason: "network changed")
    }

    /// Tries every route now and moves to a better one, or away from a dead one. A call made while a look is running shares its
    /// answer, unless the network changed since that look began: then it waits for it and looks again.
    @discardableResult
    package func checkNow(reason: String) async -> RoutePlan.Decision {
        while let running = check {
            if checkGeneration == generation { return await running.value }
            _ = await running.value
        }
        let task = Task { await self.evaluate(reason: reason) }
        check = task
        checkGeneration = generation
        let decision = await task.value
        if check == task { check = nil }
        return decision
    }

    /// Uses `url` until the network changes, when it answers as the server. Returns whether it did.
    package func use(_ url: URL) async -> Bool {
        guard let connection = environment.connection() else { return false }
        guard url != connection.serverURI else {
            chosen = url
            return true
        }
        guard await environment.probe(url, connection.authToken, connection.machineIdentifier, Self.probeTimeout),
              Self.isSameSession(environment.connection(), connection) else { return false }
        chosen = url
        move(to: url, because: .chosen, from: connection, routes: connection.candidateURIs)
        return true
    }

    @discardableResult
    package func observe(_ observer: @escaping Observer) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    package func stopObserving(_ token: UUID) {
        observers[token] = nil
    }

    private func schedule(after delay: Duration, reason: String) {
        pendingCheck?.cancel()
        pendingCheck = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, isActive else { return }
            await checkNow(reason: reason)
        }
    }

    private func evaluate(reason: String) async -> RoutePlan.Decision {
        guard !environment.isDemo(), let connection = environment.connection() else { return .stay }
        lastCheck = environment.now()
        let environment = environment
        async let advertised = Self.within(Self.lookupTimeout) { await environment.advertised(connection) }
        async let tailnet = Self.within(Self.lookupTimeout) { await environment.tailnet(connection) } ?? []
        let found = await advertised
        let relays = found?.relays ?? []
        let kind: (URL) -> ConnectionKind = { relays.contains($0) ? .relay : ConnectionRoute.kind(of: $0) }
        let known = [connection.serverURI] + (found?.routes ?? []) + connection.candidateURIs + (await tailnet)
        let preferences = environment.preferences()
        let routes = RoutePlan.ordered(known, kind: kind, allowRelay: preferences.allowRelay)
        let answering = await Self.answering(routes, connection: connection, environment: environment)
        guard Self.isSameSession(environment.connection(), connection) else { return .stay }
        let decision = RoutePlan.decide(
            current: connection.serverURI,
            routes: routes,
            answering: answering,
            kind: kind,
            preferLocal: preferences.preferLocal,
            chosen: chosen
        )
        MidgarLog.info("Route check (\(reason)): \(answering.count) of \(routes.count) routes answer, \(decision)", category: .networking)
        let kept = Self.kept(routes, advertised: found?.routes, tailnet: await tailnet, answering: answering, current: connection.serverURI)
        switch decision {
        case .move(let url, let because):
            move(to: url, because: because, from: connection, routes: kept)
        case .stay, .unreachable:
            environment.save(nil, kept)
        }
        return decision
    }

    /// The routes worth remembering: what plex.tv advertises and the tailnet shows now, the route in use, the address the viewer
    /// typed, and any other remembered route that answered. When plex.tv could not be asked, everything remembered is kept, so an
    /// address that went stale is dropped only once plex.tv no longer lists it and it no longer answers.
    private static func kept(_ routes: [URL], advertised: [URL]?, tailnet: [URL], answering: Set<URL>, current: URL) -> [URL] {
        guard let advertised else { return routes }
        let typed = RememberedServerAddress.text.flatMap(ServerAddress.parse)?.candidateURLs ?? []
        let keep = Set(advertised + tailnet + typed + [current]).union(answering)
        return routes.filter(keep.contains)
    }

    /// `work`'s answer, or nil when it takes longer than `seconds`.
    private static func within<Value: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async -> Value?) async -> Value? {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Whether `now` is still the session `started` was taken from: the same server, pinned to the same route.
    private static func isSameSession(_ now: PlexConnection?, _ started: PlexConnection) -> Bool {
        now?.machineIdentifier == started.machineIdentifier && now?.serverURI == started.serverURI
    }

    private func move(to url: URL, because reason: RoutePlan.Reason, from connection: PlexConnection, routes: [URL]) {
        environment.save(url, routes)
        APIClient.move(to: url, replacing: Set(routes + connection.candidateURIs + [connection.serverURI]))
        let move = Move(route: url, reason: reason, at: environment.now())
        lastMove = move
        MidgarLog.notice("Route moved to \(ConnectionRoute.kind(of: url).title) (\(reason)): \(url.absoluteString)", category: .networking)
        YouConnectionStatus.shared.routeChanged()
        for observer in observers.values { observer(move) }
    }

    private static func answering(_ routes: [URL], connection: PlexConnection, environment: Environment) async -> Set<URL> {
        await withTaskGroup(of: (URL, Bool).self) { group in
            for url in routes {
                group.addTask { (url, await environment.probe(url, connection.authToken, connection.machineIdentifier, probeTimeout)) }
            }
            var answering = Set<URL>()
            for await (url, answers) in group where answers { answering.insert(url) }
            return answering
        }
    }

    /// What identifies the network in use: its status, its interfaces (Wi-Fi, cellular, the Tailscale tunnel) and its gateways.
    private nonisolated static func signature(of path: NWPath) -> String {
        let interfaces = path.availableInterfaces.map { "\($0.type)-\($0.name)" }.joined(separator: ",")
        let gateways = path.gateways.map { "\($0)" }.joined(separator: ",")
        return "\(path.status)|\(interfaces)|\(gateways)"
    }
}

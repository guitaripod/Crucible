import Foundation

/// State behind the Server & Connection screen: the pinned server, every known route with a live
/// latency probe, and the numbers the rows print. The screen renders `card` and `routeRows`, calls
/// `runTest()` for a fresh round of probes, and redraws whenever `onChange` fires.
@MainActor
package final class ServerConnectionModel {
    package enum ProbeState: Equatable, Sendable {
        case probing
        case reachable(milliseconds: Int)
        case unreachable
    }

    package struct Card: Equatable, Sendable {
        package let name: String
        package let subtitle: String
        package let status: String
        package let tone: ConnectionTone
    }

    package struct RouteRow: Equatable, Sendable {
        package let url: URL
        package let kindTitle: String
        package let isInUse: Bool
        package let detail: String
        package let detailIsMonospaced: Bool
        package let latencyText: String
        package let showsWarning: Bool
        package let isDimmed: Bool
    }

    /// The outside world, replaceable so the model can run against canned answers.
    package struct Environment: Sendable {
        package var connection: @Sendable () -> PlexConnection?
        package var probe: @Sendable (_ url: URL, _ token: String) async -> ConnectionProbe?
        /// The signed-in account's plex.tv record for the connected server, if plex.tv is reachable.
        package var serverResource: @Sendable (_ token: String) async -> PlexResource?

        package static let live = Environment(
            connection: { ServerBootstrap.connection() },
            probe: { url, token in await ConnectionProber.probe(baseURL: url, token: token) },
            serverResource: { token in
                guard let machineIdentifier = ServerBootstrap.connection()?.machineIdentifier else { return nil }
                let resources: [PlexResource]? = try? await APIClient.plexTVRequest(.resources, token: token)
                return resources?.first { $0.clientIdentifier == machineIdentifier && $0.provides.contains("server") }
            }
        )
    }

    private static let fallbackURL = URL(string: "http://localhost:32400")!

    package private(set) var routes: [URL]
    package private(set) var isTesting = false
    package var onChange: (() -> Void)?
    package var onFinish: (() -> Void)?

    private let environment: Environment
    private var probes: [URL: ProbeState] = [:]
    private var relayRoutes: Set<URL> = []
    private var version: String?
    private var isOwned: Bool?
    private var probeTask: Task<Void, Never>?

    package init(environment: Environment = .live) {
        self.environment = environment
        let active = environment.connection()?.serverURI ?? Self.fallbackURL
        var known = environment.connection()?.candidateURIs ?? []
        if !known.contains(active) {
            known.insert(active, at: 0)
        }
        routes = known
    }

    deinit { probeTask?.cancel() }

    /// The route the app is pinned to; failover repins update the persisted connection.
    package var activeRouteURL: URL {
        environment.connection()?.serverURI ?? Self.fallbackURL
    }

    package var authToken: String? {
        environment.connection()?.authToken
    }

    package func probeState(for url: URL) -> ProbeState? {
        probes[url]
    }

    package func startIfNeeded() {
        if probeTask == nil && probes.isEmpty {
            runTest()
        }
    }

    package func stop() {
        probeTask?.cancel()
        probeTask = nil
    }

    package var card: Card {
        var subtitle = "Plex Media Server"
        if let version { subtitle += " \(version)" }
        if let isOwned { subtitle += isOwned ? " · Owned by you" : " · Shared with you" }

        let activeURL = activeRouteURL
        let status: String
        let tone: ConnectionTone
        switch probes[activeURL] {
        case .reachable(let milliseconds):
            let scheme = ConnectionRoute.isHTTPS(activeURL) ? "HTTPS" : "HTTP"
            status = "Connected · \(kind(of: activeURL).title) · \(scheme) · \(milliseconds) ms"
            tone = .ok
        case .unreachable:
            status = "Unreachable · \(kind(of: activeURL).title)"
            tone = .failure
        case .probing, nil:
            status = "Checking connection…"
            tone = .neutral
        }
        return Card(name: environment.connection()?.serverName ?? "Plex Server", subtitle: subtitle, status: status, tone: tone)
    }

    package var routeRows: [RouteRow] {
        routes.map(routeRow(for:))
    }

    package func routeRow(for url: URL) -> RouteRow {
        let routeKind = kind(of: url)
        let isRelay = routeKind == .relay
        let state = probes[url]

        let latency: String
        switch state {
        case .reachable(let milliseconds): latency = "\(milliseconds) ms"
        case .unreachable: latency = "Unreachable"
        case .probing, nil: latency = "…"
        }

        return RouteRow(
            url: url,
            kindTitle: routeKind.title,
            isInUse: url == activeRouteURL,
            detail: isRelay ? "Bandwidth limited, may force transcoding" : url.absoluteString,
            detailIsMonospaced: !isRelay,
            latencyText: latency,
            showsWarning: isRelay,
            isDimmed: isRelay || state == .unreachable
        )
    }

    /// Probes every route at once and looks up the server on plex.tv. Replaces a run in flight.
    package func runTest() {
        probeTask?.cancel()
        let urls = routes
        let token = authToken ?? ""
        let environment = environment
        for url in urls { probes[url] = .probing }
        isTesting = true
        onChange?()

        probeTask = Task { [weak self] in
            async let resource = environment.serverResource(token)
            await withTaskGroup(of: (URL, ConnectionProbe?).self) { group in
                for url in urls {
                    group.addTask { (url, await environment.probe(url, token)) }
                }
                for await (url, probe) in group {
                    guard !Task.isCancelled else { return }
                    self?.record(probe, for: url)
                }
            }
            let found = await resource
            guard !Task.isCancelled, let self else { return }
            apply(found)
            finish()
        }
    }

    private func kind(of url: URL) -> ConnectionKind {
        relayRoutes.contains(url) ? .relay : ConnectionRoute.kind(of: url)
    }

    private func record(_ probe: ConnectionProbe?, for url: URL) {
        if let probe {
            probes[url] = .reachable(milliseconds: probe.latencyMs)
            if let found = probe.version, version == nil || url == activeRouteURL { version = found }
        } else {
            probes[url] = .unreachable
        }
        onChange?()
    }

    private func apply(_ resource: PlexResource?) {
        guard let resource else { return }
        isOwned = resource.owned
        relayRoutes = Set(resource.connections.filter { $0.relay == true }.compactMap { URL(string: $0.uri) })
    }

    private func finish() {
        probeTask = nil
        isTesting = false
        onChange?()
        onFinish?()
        AppLogger.info("Connection test finished: \(probes.count) routes", .networking)
    }
}

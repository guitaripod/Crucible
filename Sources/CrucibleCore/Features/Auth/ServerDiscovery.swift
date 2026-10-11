import Foundation

/// The network and storage calls server discovery makes, injectable so the rules around them are
/// testable. `live` is the real thing.
package struct ServerDiscoveryEnvironment: Sendable {
    package var resources: @Sendable (_ token: String) async throws -> [PlexResource]
    package var probe: @Sendable (_ url: URL, _ token: String) async -> Bool
    package var firstReachable: @Sendable (_ urls: [URL], _ token: String) async -> URL?
    package var machineIdentifier: @Sendable (_ url: URL, _ token: String) async -> String?
    package var measure: @Sendable (_ url: URL, _ token: String) async -> Int?
    package var save: @Sendable (_ uri: URL, _ name: String, _ machineIdentifier: String, _ candidates: [URL]) -> PlexConnection?

    package init(
        resources: @escaping @Sendable (String) async throws -> [PlexResource],
        probe: @escaping @Sendable (URL, String) async -> Bool,
        firstReachable: @escaping @Sendable ([URL], String) async -> URL?,
        machineIdentifier: @escaping @Sendable (URL, String) async -> String?,
        measure: @escaping @Sendable (URL, String) async -> Int?,
        save: @escaping @Sendable (URL, String, String, [URL]) -> PlexConnection?
    ) {
        self.resources = resources
        self.probe = probe
        self.firstReachable = firstReachable
        self.machineIdentifier = machineIdentifier
        self.measure = measure
        self.save = save
    }

    package static let live = ServerDiscoveryEnvironment(
        resources: { token in try await APIClient.plexTVRequest(.resources, token: token) },
        probe: { url, token in await APIClient.probe(baseURL: url, token: token) },
        firstReachable: { urls, token in await ServerConnectionResolver.firstReachable(urls, token: token) },
        machineIdentifier: { url, token in
            guard let request = try? PlexEndpoint.identity.urlRequest(baseURL: url, token: token),
                  let (data, _) = try? await URLSession.shared.data(for: request),
                  let identity = try? JSONDecoder().decode(PlexIdentity.self, from: data)
            else { return nil }
            return identity.MediaContainer.machineIdentifier
        },
        measure: { url, token in await ServerRouteProbe.measure(url, token: token) },
        save: { uri, name, machineIdentifier, candidates in
            ServerBootstrap.saveServer(uri: uri, name: name, machineIdentifier: machineIdentifier, candidates: candidates)
            return ServerBootstrap.connection()
        }
    )
}

/// What the signed-in account offers.
package enum ServerListing: Sendable {
    case none
    case single(ServerChoice)
    case several([ServerChoice])
}

/// What a connect step reports while it works.
package enum ConnectProgress: Equatable, Sendable {
    case findingRoute(serverName: String)
    case connectingToAddress(host: String)
    case connectingToRoute(URL)
    case connected(serverName: String)

    package var message: String {
        switch self {
        case .findingRoute(let name): return "Finding the best route to \(name)…"
        case .connectingToAddress(let host): return "Connecting to \(host)…"
        case .connectingToRoute(let url): return "Connecting to \(url.absoluteString)..."
        case .connected(let name): return "Connected to \(name)"
        }
    }

    package var isSuccess: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// How a connect step ended. `connected` means the server is saved and the connection is ready to
/// hand to the app; `needsAddress` means the account's own routes did not work and the person
/// should type the server's address instead.
package enum ServerConnectOutcome: Sendable {
    case connected(PlexConnection)
    case failed(String)
    case needsAddress(message: String?)
    case cancelled
}

package struct RouteProbeTarget: Sendable {
    package let serverID: String
    package let routeIndex: Int
    package let url: URL
}

package struct RouteMeasurement: Sendable {
    package let serverID: String
    package let routeIndex: Int
    package let milliseconds: Int?
}

/// Everything between "signed in to plex.tv" and "a saved server connection": listing the
/// account's servers, probing their routes, connecting to one (the only one, a chosen one, or one
/// typed by address) and saving it through `ServerBootstrap`.
///
/// ```swift
/// let discovery = ServerDiscovery(token: token)
/// switch try await discovery.listing() {
/// case .none: showNoServers()
/// case .single(let server): handle(await discovery.connect(toOnly: server) { show($0.message) })
/// case .several(let servers): showPicker(ServerPickerState(choices: servers))
/// }
/// ```
package struct ServerDiscovery: Sendable {
    private let token: String
    private let environment: ServerDiscoveryEnvironment

    package init(token: String, environment: ServerDiscoveryEnvironment = .live) {
        self.token = token
        self.environment = environment
    }

    package func listing() async throws -> ServerListing {
        let resources = try await environment.resources(token)
        let servers = resources.filter { $0.provides.contains("server") }.map(ServerChoice.init(resource:))
        switch servers.count {
        case 0: return .none
        case 1: return .single(servers[0])
        default: return .several(servers)
        }
    }

    /// Single-server accounts skip the picker: probe every route, pin the best one, and ask for an
    /// address when nothing answers.
    package func connect(toOnly server: ServerChoice, progress: @MainActor @Sendable (ConnectProgress) -> Void) async -> ServerConnectOutcome {
        let advertised = server.routes.compactMap { URL(string: $0.uri) }
        guard !advertised.isEmpty else { return .needsAddress(message: nil) }

        await progress(.findingRoute(serverName: server.name))
        let best = await environment.firstReachable(advertised, token)
        guard !Task.isCancelled else { return .cancelled }
        guard let best else {
            return .needsAddress(message: "Could not reach \(server.name). Enter its address instead.")
        }
        return await finish(url: best, name: server.name, machineIdentifier: server.id, candidates: advertised, progress: progress)
    }

    /// Connects to the route the person picked on a server card.
    package func connect(to choice: ServerChoice, route: ServerRoute, progress: @MainActor @Sendable (ConnectProgress) -> Void) async -> ServerConnectOutcome {
        guard let url = URL(string: route.uri) else { return .failed("Invalid server address") }
        let advertised = choice.routes.compactMap { URL(string: $0.uri) }.filter { $0 != url }
        return await finish(url: url, name: choice.name, machineIdentifier: choice.id, candidates: advertised, progress: progress)
    }

    /// Connects to a typed address, https first. When the address belongs to a server the person
    /// already chose (`known`), that server's name, id and routes are kept; otherwise they are
    /// looked up from the server and plex.tv, falling back to the host.
    package func connect(toAddress address: ServerAddress, known: ServerChoice?, progress: @MainActor @Sendable (ConnectProgress) -> Void) async -> ServerConnectOutcome {
        await progress(.connectingToAddress(host: address.host))
        guard let url = await environment.firstReachable(address.candidateURLs, token) else {
            return .failed("Couldn't reach \(address.host). Check the address and that the server is online.")
        }
        let machineIdentifier: String
        let name: String
        if let known {
            machineIdentifier = known.id
            name = known.name
        } else {
            let identified = await environment.machineIdentifier(url, token)
            machineIdentifier = identified ?? address.host
            let resolvedName = await serverName(machineIdentifier: machineIdentifier)
            name = resolvedName ?? address.host
        }
        let advertised = (known?.routes.compactMap { URL(string: $0.uri) } ?? []).filter { $0 != url }
        return await finish(url: url, name: name, machineIdentifier: machineIdentifier, candidates: advertised, progress: progress)
    }

    /// Measures every route in parallel and reports each result as it lands. The stream ends once
    /// all probes settled; cancelling the consumer cancels the probes.
    package func measureRoutes(_ targets: [RouteProbeTarget]) -> AsyncStream<RouteMeasurement> {
        let environment = environment
        let token = token
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: RouteMeasurement.self) { group in
                    for target in targets {
                        group.addTask {
                            RouteMeasurement(serverID: target.serverID, routeIndex: target.routeIndex, milliseconds: await environment.measure(target.url, token))
                        }
                    }
                    for await measurement in group {
                        continuation.yield(measurement)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func serverName(machineIdentifier: String) async -> String? {
        let resources = try? await environment.resources(token)
        return resources?.first { $0.clientIdentifier == machineIdentifier }?.name
    }

    /// Re-checks the route, persists the server and returns the connection for the app.
    private func finish(
        url: URL,
        name: String,
        machineIdentifier: String,
        candidates: [URL],
        progress: @MainActor @Sendable (ConnectProgress) -> Void
    ) async -> ServerConnectOutcome {
        await progress(.connectingToRoute(url))
        guard await environment.probe(url, token) else {
            return .failed("Could not reach server at \(url.absoluteString)")
        }
        let connection = environment.save(url, name, machineIdentifier, candidates.filter { $0 != url })
        await progress(.connected(serverName: name))
        guard let connection else { return .failed("Failed to save connection") }
        return .connected(connection)
    }
}

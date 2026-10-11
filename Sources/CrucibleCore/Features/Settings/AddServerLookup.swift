import Foundation

/// A Plex server that answered at a typed address, with the other routes plex.tv knows for it.
package struct FoundServer: Sendable {
    package let url: URL
    package let name: String
    package let machineIdentifier: String
    package let candidates: [URL]
}

/// Add Server by Address: turns what the user typed into URLs, finds the server answering on one
/// of them and pins it as the active route.
package enum AddServerLookup {
    package struct Environment: Sendable {
        package var probe: @Sendable (_ url: URL, _ token: String) async -> ConnectionProbe?
        package var resources: @Sendable (_ token: String) async -> [PlexResource]
        package var existingConnection: @Sendable () -> PlexConnection?

        package static let live = Environment(
            probe: { url, token in await ConnectionProber.probe(baseURL: url, token: token, timeout: 5) },
            resources: { token in (try? await APIClient.plexTVRequest(.resources, token: token)) ?? [] },
            existingConnection: { ServerBootstrap.connection() }
        )
    }

    package static let invalidAddressMessage = "Enter an address like 192.168.1.20 or https://plex.example.com:32400."

    package static func notFoundMessage(for input: String) -> String {
        "Couldn't find a Plex server at \(input.trimmingCharacters(in: .whitespacesAndNewlines)). Check the address and that the server is online."
    }

    /// The URLs worth probing for `input`, https first, or nil when it is not an address.
    package static func candidates(from input: String) -> [URL]? {
        ConnectionRoute.candidates(from: input)
    }

    /// Tries each URL in order and returns the first that answers `/identity` with a machine id,
    /// enriched with the server's name and other advertised routes from plex.tv when it is known there.
    package static func find(among urls: [URL], token: String, environment: Environment = .live) async -> FoundServer? {
        for url in urls {
            guard !Task.isCancelled else { return nil }
            guard let probe = await environment.probe(url, token),
                  let machineIdentifier = probe.machineIdentifier
            else { continue }
            let resources = await environment.resources(token)
            let match = resources.first { $0.clientIdentifier == machineIdentifier && $0.provides.contains("server") }
            let existing = environment.existingConnection()
            var candidates = match?.connections.compactMap { URL(string: $0.uri) } ?? []
            if let existing, existing.machineIdentifier == machineIdentifier {
                candidates.append(contentsOf: existing.candidateURIs)
            }
            let others = candidates.filter { $0 != url }
            var seen = Set<URL>()
            let unique = others.filter { seen.insert($0).inserted }
            return FoundServer(
                url: url,
                name: match?.name ?? existing.flatMap { $0.machineIdentifier == machineIdentifier ? $0.serverName : nil } ?? url.host ?? "Plex Server",
                machineIdentifier: machineIdentifier,
                candidates: unique
            )
        }
        return nil
    }

    package static func save(_ server: FoundServer) {
        ServerBootstrap.saveServer(uri: server.url, name: server.name, machineIdentifier: server.machineIdentifier, candidates: server.candidates)
        AppLogger.notice("Added server \(server.name) at \(server.url.absoluteString)", .networking)
    }
}

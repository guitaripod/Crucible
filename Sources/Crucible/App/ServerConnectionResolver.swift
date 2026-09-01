import Foundation
import os

enum ServerConnectionResolver {
    enum Outcome: Sendable {
        case connection(PlexConnection)
        case needsSetup
    }

    static func validate(
        connection: PlexConnection,
        progress: @escaping @Sendable (String) -> Void
    ) async -> Outcome {
        let log = Logger(subsystem: "com.guitaripod.crucible", category: "bootstrap")
        if await APIClient.probe(baseURL: connection.serverURI, token: connection.authToken) {
            log.notice("Pinned route \(connection.serverURI.absoluteString, privacy: .public) healthy")
            return .connection(connection)
        }

        progress("Reconnecting to \(connection.serverName)…")
        log.error("Pinned route \(connection.serverURI.absoluteString, privacy: .public) unreachable; re-discovering")

        let candidates = await APIClient.discoverCandidates(token: connection.authToken, pinned: connection.serverURI)
        for candidate in candidates {
            if await APIClient.probe(baseURL: candidate, token: connection.authToken) {
                log.notice("Re-pinned to \(candidate.absoluteString, privacy: .public)")
                ServerBootstrap.repin(uri: candidate)
                var healed = connection
                healed = PlexConnection(
                    serverURI: candidate,
                    serverName: connection.serverName,
                    machineIdentifier: connection.machineIdentifier,
                    authToken: connection.authToken,
                    clientIdentifier: connection.clientIdentifier,
                    candidateURIs: [candidate] + candidates.filter { $0 != candidate }
                )
                return .connection(healed)
            }
        }

        log.error("No reachable route to \(connection.serverName, privacy: .public); falling back to setup")
        return .needsSetup
    }
}
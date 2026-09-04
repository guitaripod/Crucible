import Foundation
import os

enum ServerConnectionResolver {
    enum Outcome: Sendable {
        case connection(PlexConnection)
        case needsSetup
    }

    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "bootstrap")

    static func validate(
        connection: PlexConnection,
        progress: @escaping @Sendable (String) -> Void
    ) async -> Outcome {
        if await APIClient.probe(baseURL: connection.serverURI, token: connection.authToken) {
            log.notice("Pinned route \(connection.serverURI.absoluteString, privacy: .public) healthy")
            return .connection(connection)
        }

        progress("Looking for \(connection.serverName)…")
        log.error("Pinned route \(connection.serverURI.absoluteString, privacy: .public) unreachable; re-discovering")
        AppLogger.error("Pinned route \(connection.serverURI.absoluteString) unreachable; re-discovering", .networking)

        let candidates = await APIClient.discoverCandidates(token: connection.authToken, pinned: connection.serverURI)
        guard let healthy = await firstReachable(candidates, token: connection.authToken) else {
            log.error("No reachable route to \(connection.serverName, privacy: .public); falling back to setup")
            AppLogger.error("No reachable route to \(connection.serverName) among \(candidates.count) candidates", .networking)
            return .needsSetup
        }

        log.notice("Re-pinned to \(healthy.absoluteString, privacy: .public)")
        AppLogger.notice("Re-pinned to \(healthy.absoluteString)", .networking)
        ServerBootstrap.repin(uri: healthy)
        return .connection(PlexConnection(
            serverURI: healthy,
            serverName: connection.serverName,
            machineIdentifier: connection.machineIdentifier,
            authToken: connection.authToken,
            clientIdentifier: connection.clientIdentifier,
            candidateURIs: [healthy] + candidates.filter { $0 != healthy }
        ))
    }

    /// Probes every candidate concurrently and returns the highest-priority one that answers,
    /// without waiting for lower-priority probes to time out once a better route is known good.
    static func firstReachable(_ candidates: [URL], token: String) async -> URL? {
        guard !candidates.isEmpty else { return nil }
        return await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask { (index, await APIClient.probe(baseURL: candidate, token: token)) }
            }
            var results: [Int: Bool] = [:]
            for await (index, reachable) in group {
                results[index] = reachable
                for (position, candidate) in candidates.enumerated() {
                    guard let known = results[position] else { break }
                    if known {
                        group.cancelAll()
                        return candidate
                    }
                }
            }
            return nil
        }
    }
}

import Foundation

/// Everything the main UI needs to be fully usable the instant it appears: a validated route,
/// the API client bound to it, and the Home and Library payloads already fetched.
struct LaunchPayload: Sendable {
    let connection: PlexConnection
    let api: APIClient
    let hubs: PlexMediaContainer
    let sections: PlexMediaContainer
}

enum LaunchFailure: Error, Sendable {
    case unreachable
    case fetch(any Error)

    var message: String {
        switch self {
        case .unreachable:
            return "None of the server's known addresses answered. Check that it's online and reachable from this network."
        case .fetch(let error):
            return ConnectionError.message(for: error)
        }
    }
}

/// The launch pipeline: validate (and if needed heal) the saved route, then fetch Home hubs and
/// library sections in parallel. Nothing reaches the screen until every stage has succeeded.
enum AppLaunchSession {
    static func run(
        connection saved: PlexConnection,
        progress: @escaping @Sendable (String) -> Void
    ) async -> Result<LaunchPayload, LaunchFailure> {
        progress("Connecting to \(saved.serverName)…")
        let connection: PlexConnection
        switch await ServerConnectionResolver.validate(connection: saved, progress: progress) {
        case .connection(let validated):
            connection = validated
        case .needsSetup:
            return .failure(.unreachable)
        }

        progress("Loading your library…")
        let api = APIClient(baseURL: connection.serverURI, token: connection.authToken)
        do {
            async let hubs = api.requestContainer(.hubs())
            async let sections = api.requestContainer(.sections)
            let payload = try await LaunchPayload(connection: connection, api: api, hubs: hubs, sections: sections)
            AppLogger.notice("Launch ready: \(payload.sections.Directory?.count ?? 0) sections, \(payload.hubs.Hub?.count ?? 0) hubs via \(connection.serverURI.absoluteString)", .lifecycle)
            return .success(payload)
        } catch {
            AppLogger.error("Launch fetch failed: \(String(describing: error))", .networking)
            return .failure(.fetch(error))
        }
    }
}

import Foundation
import MidgarCore

/// Everything the main UI needs to be fully usable the instant it appears: a validated route,
/// the API client bound to it, and the Home and Library payloads already fetched.
package struct LaunchPayload: Sendable {
    package let connection: PlexConnection
    package let api: APIClient
    package let hubs: PlexMediaContainer
    package let sections: PlexMediaContainer
}

package enum LaunchFailure: Error, Sendable {
    case unreachable
    case signInExpired
    case fetch(any Error)

    package var message: String {
        switch self {
        case .unreachable:
            return "None of the server's known addresses answered. Check that it's online and reachable from this network."
        case .signInExpired:
            return ConnectionError.message(for: APIError.unauthorized)
        case .fetch(let error):
            return ConnectionError.message(for: error)
        }
    }

    /// A fetch that failed because Plex no longer accepts the saved token is an expired sign-in,
    /// not a server problem.
    static func fetchFailure(_ error: any Error) -> LaunchFailure {
        if case APIError.unauthorized = error { return .signInExpired }
        return .fetch(error)
    }
}

/// The launch pipeline: validate (and if needed heal) the saved route, tell the server where the last
/// run left the viewer, then fetch Home hubs and library sections in parallel. Nothing reaches the screen until every stage has succeeded.
package enum AppLaunchSession {
    package static func run(
        connection saved: PlexConnection,
        progress: @escaping @Sendable (String) -> Void
    ) async -> Result<LaunchPayload, LaunchFailure> {
        await run(
            connection: saved,
            progress: progress,
            validate: { await ServerConnectionResolver.validate(connection: $0, progress: progress) },
            tokenRejected: { await PlexTokenCheck.isRejected(token: $0) }
        )
    }

    static func run(
        connection saved: PlexConnection,
        progress: @escaping @Sendable (String) -> Void,
        validate: (PlexConnection) async -> ServerConnectionResolver.Outcome,
        tokenRejected: (String) async -> Bool
    ) async -> Result<LaunchPayload, LaunchFailure> {
        progress("Connecting to \(saved.serverName)…")
        let connection: PlexConnection
        switch await validate(saved) {
        case .connection(let validated):
            connection = validated
        case .needsSetup:
            return .failure(await tokenRejected(saved.authToken) ? .signInExpired : .unreachable)
        }

        progress("Loading your library…")
        let api = APIClient(baseURL: connection.serverURI, token: connection.authToken)
        await PlaybackResumeSync.flush(api: api, server: connection.machineIdentifier)
        do {
            async let hubs = api.requestContainer(.hubs())
            async let sections = api.requestContainer(.sections)
            let payload = try await LaunchPayload(connection: connection, api: api, hubs: hubs, sections: sections)
            await MainActor.run { LibraryVisibility.record(directories: payload.sections.Directory ?? []) }
            MidgarLog.notice("Launch ready: \(payload.sections.Directory?.count ?? 0) sections, \(payload.hubs.Hub?.count ?? 0) hubs via \(connection.serverURI.absoluteString)", category: .lifecycle)
            return .success(payload)
        } catch {
            MidgarLog.error("Launch fetch failed: \(String(describing: error))", category: .networking)
            return .failure(.fetchFailure(error))
        }
    }
}

import Foundation
import MidgarCore

/// What is playing on the server right now, for the viewer who owns it or shares it.
package enum ServerActivity {
    /// The titles being watched at this moment, in the order the server lists them.
    package static func sessions(api: APIClient) async throws -> [PlexMetadata] {
        try await api.requestContainer(.serverSessions).Metadata ?? []
    }

    /// "Maren · Playing, Transcoding · Living Room Apple TV": who, how the stream stands and how the server serves it, then on what.
    /// The device comes last because a caption that does not fit loses its end first.
    package static func subtitle(_ session: PlexMetadata) -> String? {
        var parts: [String] = []
        if let user = session.sessionUser?.title, !user.isEmpty { parts.append(user) }
        let status = [stateText(session.sessionPlayer?.state), isTranscoding(session) ? String(localized: "Transcoding", comment: "The server is converting the stream it plays to someone") : nil]
            .compactMap { $0 }
        if !status.isEmpty { parts.append(status.joined(separator: ", ")) }
        if let device = session.sessionPlayer?.title ?? session.sessionPlayer?.product, !device.isEmpty { parts.append(device) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    package static func isTranscoding(_ session: PlexMetadata) -> Bool {
        [session.transcodeSession?.videoDecision, session.transcodeSession?.audioDecision].contains("transcode")
    }

    private static func stateText(_ state: String?) -> String? {
        switch state {
        case "playing": return String(localized: "Playing", comment: "State of a stream on the server")
        case "paused": return String(localized: "Paused", comment: "State of a stream on the server")
        case "buffering": return String(localized: "Buffering", comment: "State of a stream on the server")
        default: return nil
        }
    }

    /// The id the server stops a stream by, when the viewer owns the server and the row carries one.
    @MainActor
    package static func stoppableSessionID(_ session: PlexMetadata) -> String? {
        guard ServerOwnership.isOwner(), let id = session.playbackSession?.id, !id.isEmpty else { return nil }
        return id
    }

    package static let title = String(localized: "Server Activity", comment: "Name of the screen that lists what is playing on the server")
    package static let emptyTitle = String(localized: "Nothing Playing", comment: "Title of the Server Activity screen when nobody is watching")
    package static let emptyText = String(localized: "When anyone watches something on your server, it appears here.", comment: "Message of the Server Activity screen when nobody is watching")
}

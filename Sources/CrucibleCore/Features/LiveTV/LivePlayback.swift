import Foundation
import MidgarCore

/// How a channel plays: the address the player opens, the headers it sends and what format waits there.
package struct LivePlaybackPlan: Sendable, Equatable {
    package enum Format: Sendable, Equatable {
        /// An HLS playlist, which AVPlayer and mpv both open as is.
        case hls
        /// A bare MPEG transport stream: mpv opens it, AVPlayer needs it cut into HLS first (`TransportStreamSegmenter`).
        case transportStream
    }

    package let url: URL
    package let headers: [String: String]
    package let format: Format
    /// The server's conversion session behind a tuner's channel, stopped when the viewer leaves it.
    package let transcodeSession: String?

    package init(url: URL, headers: [String: String], format: Format, transcodeSession: String? = nil) {
        self.url = url
        self.headers = headers
        self.format = format
        self.transcodeSession = transcodeSession
    }
}

package enum LivePlayback {
    package enum Failure: Error, LocalizedError, Equatable {
        case noServer
        case tunerRefused
        case tunerBusy

        package var errorDescription: String? {
            switch self {
            case .noServer: return String(localized: "This channel plays through your Plex server, which isn’t connected.", comment: "Error when a tuner channel is chosen without a server")
            case .tunerRefused: return String(localized: "Your Plex server couldn’t tune this channel.", comment: "Error when the Plex server failed to tune a live TV channel")
            case .tunerBusy: return String(localized: "Every tuner is busy recording or playing. Stop something else and try again.", comment: "Error when no tuner is free")
            }
        }
    }

    /// The plan for `channel`. A tuner's channel is tuned on the server first, which can take a few seconds.
    package static func plan(for channel: LiveChannel, token: String, api: APIClient?) async throws -> LivePlaybackPlan {
        switch channel.stream {
        case .address(let url, let userAgent, let referrer):
            return LivePlaybackPlan(url: url, headers: LiveStreamRequest.headers(userAgent: userAgent, referrer: referrer), format: format(of: url))
        case .plexFree(let partKey):
            guard let url = PlexFreeChannelSource.streamURL(partKey: partKey, token: token) else { throw APIError.invalidURL }
            return LivePlaybackPlan(url: url, headers: PlexHeaders.allHeaders(token: HomeProfiles.activePlexTVToken ?? token), format: .hls)
        case .plexDVR(let dvrKey, let identifier):
            guard let api else { throw Failure.noServer }
            return try await tune(dvrKey: dvrKey, channel: identifier, api: api)
        }
    }

    /// Whether an address names an HLS playlist; anything else from a playlist is taken for a transport stream, which is
    /// what IPTV services send when the address has no extension.
    package static func format(of url: URL) -> LivePlaybackPlan.Format {
        let path = url.path.lowercased()
        if path.hasSuffix(".m3u8") || path.hasSuffix(".m3u") { return .hls }
        let query = url.query?.lowercased() ?? ""
        if query.contains("m3u8") || query.contains("output=hls") || query.contains("type=hls") { return .hls }
        return .transportStream
    }

    private static func tune(dvrKey: String, channel: String, api: APIClient) async throws -> LivePlaybackPlan {
        let body: PlexLiveContainer<TuneBody>
        do {
            body = try await api.request(.tuneChannel(dvrKey: dvrKey, channel: channel))
        } catch APIError.serverUnavailable {
            throw Failure.tunerBusy
        } catch APIError.httpError(let status, _) where status == 409 {
            throw Failure.tunerBusy
        }
        guard let metadata = body.MediaContainer.Metadata?.first else { throw Failure.tunerRefused }
        let session = metadata.Media?.first?.uuid
        guard let key = metadata.key ?? session.map({ "/livetv/sessions/\($0)" }) else { throw Failure.tunerRefused }
        let transcodeSession = UUID().uuidString
        guard let url = transcodeURL(base: await api.baseURL, token: api.token, path: key, session: transcodeSession) else { throw APIError.invalidURL }
        MidgarLog.notice("Tuned channel \(channel) on DVR \(dvrKey)", category: .liveTV)
        return LivePlaybackPlan(url: url, headers: PlexHeaders.allHeaders(token: api.token), format: .hls, transcodeSession: transcodeSession)
    }

    /// The server's universal transcoder on a live session, copying the picture and sound when the player takes them.
    static func transcodeURL(base: URL, token: String, path: String, session: String) -> URL? {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/video/:/transcode/universal/start.m3u8"
        components?.queryItems = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "directStreamAudio", value: "1"),
            URLQueryItem(name: "fastSeek", value: "1"),
            URLQueryItem(name: "location", value: "lan"),
            URLQueryItem(name: "session", value: session),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: session),
            URLQueryItem(name: "X-Plex-Token", value: token),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexHeaders.clientIdentifier),
            URLQueryItem(name: "X-Plex-Product", value: "Crucible"),
            URLQueryItem(name: "X-Plex-Platform", value: AppPlatform.plexName),
        ]
        return components?.url
    }

    /// Ends the server's conversion of a tuner's channel, which frees the tuner.
    package static func stop(_ plan: LivePlaybackPlan, api: APIClient?) async {
        guard let session = plan.transcodeSession, let api else { return }
        try? await api.requestVoid(.stopTranscode(session: session))
    }

    struct TuneBody: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            struct MediaEntry: Decodable, Sendable {
                let uuid: String?
            }

            let key: String?
            let Media: [MediaEntry]?
        }

        let Metadata: [Item]?
    }
}

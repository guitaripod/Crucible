import Foundation

struct ResolvedStream: Sendable {
    let url: URL
    let isDirectPlay: Bool
    let startedFromOffset: Bool
    let subtitles: [Subtitle]
    let audioTracks: [AudioTrack]
    let spritesVttURL: URL?
    let spritesImageURL: URL?
}

enum StreamResolverError: Error, LocalizedError {
    case preparationFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .preparationFailed(let msg): return "Stream preparation failed: \(msg)"
        case .timeout: return "Stream preparation timed out"
        }
    }
}

enum StreamResolver {
    static func resolve(
        api: APIClient,
        mediaId: String,
        audioTrackId: String?,
        subtitleId: String?,
        startSecs: Double?
    ) async throws -> ResolvedStream {
        let info: StreamInfo = try await api.request(.streamInfo(id: mediaId))
        let baseURL = api.baseURL

        let textSubtitles = info.subtitles.filter { !$0.isBitmap }
        let useDirectPlay = info.canDirectPlay && textSubtitles.isEmpty

        let streamURL: URL
        let isDirect: Bool
        var didStartFromOffset = false

        if useDirectPlay {
            streamURL = baseURL.appendingPathComponent("/api/stream/\(mediaId)/direct")
            isDirect = true
        } else {
            let useStartSecs = info.needsTranscode ? startSecs : nil
            didStartFromOffset = useStartSecs != nil
            let body = HlsPrepareRequest(audioTrackId: audioTrackId, startSecs: useStartSecs)
            try await api.requestVoid(.hlsPrepare(id: mediaId, body: body))

            var isReady = false
            for _ in 0 ..< 240 {
                try await Task.sleep(for: .milliseconds(500))
                try Task.checkCancellation()

                do {
                    let status: HlsStatusResponse = try await api.request(.hlsStatus(id: mediaId))
                    switch status.status {
                    case "ready":
                        isReady = true
                    case "error":
                        throw StreamResolverError.preparationFailed(status.error ?? "Unknown error")
                    default:
                        continue
                    }
                    break
                } catch let resolved as StreamResolverError {
                    throw resolved
                } catch {
                    continue
                }
            }

            guard isReady else {
                throw StreamResolverError.timeout
            }

            streamURL = baseURL.appendingPathComponent("/api/stream/\(mediaId)/hls/master.m3u8")
            isDirect = false
        }

        let spritesVtt = URL(string: info.spritesVtt, relativeTo: baseURL)
        let spritesImg = baseURL.appendingPathComponent("/api/stream/\(mediaId)/sprites/sprites.jpg")

        return ResolvedStream(
            url: streamURL,
            isDirectPlay: isDirect,
            startedFromOffset: didStartFromOffset,
            subtitles: info.subtitles,
            audioTracks: info.audioTracks,
            spritesVttURL: spritesVtt,
            spritesImageURL: spritesImg
        )
    }
}
